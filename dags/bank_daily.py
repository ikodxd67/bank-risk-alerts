"""Ежедневная загрузка банка за день ds: источник → dds → витрины → StarRocks, с проверками.

Вся логика — в PL/SQL-пакетах Oracle. DAG только ждёт источник, вызывает пакеты по
порядку, проверяет результат, выгружает день в StarRocks и пишет в Telegram, если что-то упало.
"""
from contextlib import closing
from datetime import date, datetime, timedelta
from html import escape
from pathlib import Path

from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator
from airflow.providers.common.sql.sensors.sql import SqlSensor
from airflow.providers.mysql.hooks.mysql import MySqlHook
from airflow.providers.oracle.hooks.oracle import OracleHook
from airflow.providers.telegram.hooks.telegram import TelegramHook
from airflow.sdk import CronDataIntervalTimetable, dag, task

CONN = "oracle_dwh"
D = "DATE '{{ ds }}'"   # день загрузки: начало интервала данных

# Каждая колонка — одна проверка: 1 = прошла. Имя колонки попадает в текст ошибки.
DQ_DDS = f"""
SELECT
  CASE WHEN (SELECT COUNT(*) FROM src.transactions WHERE trx_ts >= {D} AND trx_ts < {D} + 1)
          = (SELECT COUNT(*) FROM fct_transactions WHERE trx_date = {D}) THEN 1 ELSE 0 END AS trx_count_matches_source,
  CASE WHEN (SELECT NVL(SUM(amount), 0) FROM src.transactions WHERE trx_ts >= {D} AND trx_ts < {D} + 1)
          = (SELECT NVL(SUM(amount), 0) FROM fct_transactions WHERE trx_date = {D}) THEN 1 ELSE 0 END AS trx_amount_matches_source,
  CASE WHEN (SELECT COUNT(*) - COUNT(DISTINCT trx_id) FROM fct_transactions WHERE trx_date = {D}) = 0
       THEN 1 ELSE 0 END AS no_duplicate_trx,
  CASE WHEN (SELECT COUNT(*) FROM src.loan_payments WHERE paid_on = {D})
          = (SELECT COUNT(*) FROM fct_loan_payment WHERE paid_on = {D}) THEN 1 ELSE 0 END AS payments_match_source
FROM dual"""

DQ_MARTS = f"""
SELECT
  CASE WHEN (SELECT NVL(SUM(trx_cnt), 0) FROM mart_daily_turnover WHERE report_date = {D})
          = (SELECT COUNT(*) FROM fct_transactions WHERE trx_date = {D}) THEN 1 ELSE 0 END AS turnover_matches_fact,
  CASE WHEN (SELECT COUNT(*) FROM mart_trx_features WHERE trx_date = {D})
          = (SELECT COUNT(*) FROM fct_transactions WHERE trx_date = {D}) THEN 1 ELSE 0 END AS features_for_every_trx,
  -- ноль срабатываний за день при ~30 в норме — правила выключены или сломаны признаки
  CASE WHEN (SELECT COUNT(*) FROM fraud_alert WHERE alert_date = {D}) > 0 THEN 1 ELSE 0 END AS fraud_rules_fired,
  CASE WHEN (SELECT COUNT(*) FROM mart_loan_dpd WHERE snapshot_date = {D}) > 0 THEN 1 ELSE 0 END AS dpd_snapshot_built
FROM dual"""


# Тот же файл, что запускает scripts/starrocks.sh export; здесь обе границы — день запуска.
EXPORT_SQL = (Path("/opt/airflow/sql/starrocks/export.sql").read_text(encoding="utf-8")
              .replace("{{ d1 }}", "{{ ds }}").replace("{{ d2 }}", "{{ ds }}"))

# Выполняется в StarRocks: он видит и свои таблицы, и Oracle через каталог.
S = "'{{ ds }}'"
DQ_STARROCKS = f"""
SELECT
  IF((SELECT IFNULL(SUM(trx_cnt), 0) FROM bank.trx_hourly WHERE trx_date = {S})
   = (SELECT COUNT(*) FROM oracle_dwh.DWH.FCT_TRANSACTIONS WHERE TRX_DATE >= {S} AND TRX_DATE <= {S}), 1, 0) AS starrocks_trx_match_oracle,
  IF((SELECT IFNULL(SUM(approved_amount), 0) FROM bank.turnover_daily WHERE report_date = {S})
   = (SELECT IFNULL(SUM(approved_amount), 0) FROM bank.trx_hourly WHERE trx_date = {S}), 1, 0) AS starrocks_turnover_match_hourly,
  IF((SELECT COUNT(*) FROM bank.fraud_alert WHERE alert_date = {S})
   = (SELECT COUNT(*) FROM oracle_dwh.DWH.FRAUD_ALERT WHERE ALERT_DATE >= {S} AND ALERT_DATE <= {S}), 1, 0) AS starrocks_alerts_match_oracle,
  IF((SELECT COUNT(*) FROM bank.loan_dpd WHERE snapshot_date = {S})
   = (SELECT COUNT(*) FROM oracle_dwh.DWH.MART_LOAN_DPD WHERE SNAPSHOT_DATE >= {S} AND SNAPSHOT_DATE <= {S}), 1, 0) AS starrocks_dpd_match_oracle"""


def notify_failure(context) -> None:
    ti = context["task_instance"]
    text = (f"❌ {ti.dag_id} за {context['ds']}: упала задача {ti.task_id} "
            f"(попытка {ti.try_number})\n{context.get('exception')}")
    TelegramHook().send_message({"text": escape(text[:3500])})   # parse_mode у хука — HTML
    print("сообщение о падении отправлено в Telegram")


def run_checks(sql: str, starrocks: bool = False) -> None:
    """Падает со списком не прошедших проверок."""
    hook = MySqlHook(mysql_conn_id="starrocks") if starrocks else OracleHook(oracle_conn_id=CONN)
    with closing(hook.get_conn()) as conn:
        cur = conn.cursor()
        cur.execute(sql)
        row = cur.fetchone()
        names = [d[0].lower() for d in cur.description]
    failed = [name for name, ok in zip(names, row) if ok != 1]
    if failed:
        raise ValueError("не прошли проверки: " + ", ".join(failed))
    print("проверки прошли:", ", ".join(names))


def call(proc: str, ds: str) -> None:
    OracleHook(oracle_conn_id=CONN).callproc(proc, parameters=[date.fromisoformat(ds)])


@dag(
    # CronDataIntervalTimetable явно: в Airflow 3 строка cron по умолчанию даёт
    # CronTriggerTimetable, и ds там — момент запуска, а не загружаемый день.
    # Интервал — сутки с полуночи UTC; запуск в конце интервала (05:00 Алматы) за прошедший день.
    schedule=CronDataIntervalTimetable("0 0 * * *", timezone="UTC"),
    start_date=datetime(2026, 11, 1),
    # catchup=True: пропущенный день (Airflow лежал, DAG был на паузе) догоняется сам,
    # по порядку. Измерения грузятся только вперёд — дыра в днях хуже, чем опоздание.
    catchup=True,
    max_active_runs=1,          # дни строго по очереди
    default_args={
        "retries": 1,
        "retry_delay": timedelta(minutes=1),
        "on_failure_callback": notify_failure,
    },
    tags=["bank", "oracle", "starrocks"],
)
def bank_daily():
    # Источник пишет день одной транзакцией, поэтому «есть строки» = «день пришёл целиком».
    wait_source = SqlSensor(
        task_id="wait_source",
        conn_id=CONN,
        sql=f"SELECT COUNT(*) FROM src.transactions WHERE trx_ts >= {D} AND trx_ts < {D} + 1",
        mode="reschedule",      # между проверками не держит слот исполнителя
        poke_interval=600,
        timeout=6 * 3600,
    )

    @task(depends_on_past=True)   # не грузить день, пока не загружен предыдущий
    def load_dds(ds=None):
        call("pkg_dds.run_day", ds)

    @task
    def check(sql: str, starrocks: bool = False):
        # SQL приходит аргументом: Airflow подставляет {{ ds }} только в аргументы задачи
        run_checks(sql, starrocks)

    @task
    def build_marts(ds=None):
        call("pkg_marts.run_day", ds)

    export_starrocks = SQLExecuteQueryOperator(
        task_id="export_starrocks",
        conn_id="starrocks",
        sql=EXPORT_SQL,
        split_statements=True,
    )

    (wait_source >> load_dds() >> check.override(task_id="check_dds")(DQ_DDS)
     >> build_marts() >> check.override(task_id="check_marts")(DQ_MARTS)
     >> export_starrocks >> check.override(task_id="check_starrocks")(DQ_STARROCKS, starrocks=True))


bank_daily()
