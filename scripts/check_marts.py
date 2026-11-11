"""Отчёт по витринам: качество правил, просрочка, сверка оборотов. Запуск: .venv/Scripts/python scripts/check_marts.py"""
import sys

from bra import db

sys.stdout.reconfigure(encoding="utf-8")
db.load_env()
cur = db.connect("dwh").cursor()


def q(title: str, sql: str) -> None:
    print(f"\n-- {title}")
    for row in cur.execute(sql):
        print("  ", *row)


q("журнал витрин: шаг, статус, запусков, строк всего, среднее время, с", """
  SELECT step, status, COUNT(*), SUM(row_cnt),
         ROUND(AVG(EXTRACT(SECOND FROM finished_at - started_at) + 60 * EXTRACT(MINUTE FROM finished_at - started_at)), 2)
  FROM etl_log WHERE step LIKE 'build%' GROUP BY step, status ORDER BY step, status""")
q("обороты = факт (дней с расхождением, должно быть 0)", """
  SELECT COUNT(*) FROM (
    SELECT report_date d, SUM(trx_cnt) n, SUM(approved_amount) amt FROM mart_daily_turnover GROUP BY report_date
    MINUS
    SELECT trx_date, COUNT(*), NVL(SUM(CASE WHEN status = 'APPROVED' THEN amount END), 0)
    FROM fct_transactions WHERE trx_date IN (SELECT report_date FROM mart_daily_turnover) GROUP BY trx_date)""")
q("правила из таблицы fraud_rule: код, порог, мин. история, активно", """
  SELECT rule_code, threshold, min_history, is_active FROM fraud_rule ORDER BY rule_code""")
q("качество правил по дням с полной историей и созревшими жалобами: правило, срабатываний, подтверждено, precision, recall",
  "SELECT * FROM v_fraud_rule_quality ORDER BY rule_code")
q("полнота по видам мошенничества: вид, операций, recall по операциям, карта-дней, recall по карта-дням",
  "SELECT * FROM v_fraud_recall_by_type ORDER BY fraud_type")
q("что если поменять порог AMOUNT_30D (считается по признакам, таблицу не трогаем): порог, срабатываний, подтверждено, precision", """
  WITH mature AS (SELECT f.first_day, l.last_day
                  FROM (SELECT MIN(trx_date) + 30 AS first_day FROM fct_transactions) f,
                       (SELECT MAX(reported_at) - 14 AS last_day FROM fraud_label) l),
       t AS (SELECT COLUMN_VALUE AS thr FROM TABLE(sys.odcinumberlist(5, 6, 8, 10, 12)))
  SELECT t.thr, COUNT(*), COUNT(l.trx_id), ROUND(COUNT(l.trx_id) / COUNT(*), 3)
  FROM t
  JOIN mart_trx_features f
    ON f.channel <> 'ATM' AND f.purchase_cnt_30d >= 3 AND f.amount >= t.thr * f.avg_purchase_30d
  LEFT JOIN fraud_label l ON l.trx_id = f.trx_id
  WHERE f.trx_date BETWEEN (SELECT first_day FROM mature) AND (SELECT last_day FROM mature)
  GROUP BY t.thr ORDER BY t.thr""")
q("срабатываний в день по правилам (мин / среднее / макс, без 30 дней прогрева) — база для алерта «ноль срабатываний»", """
  SELECT rule_code, MIN(n), ROUND(AVG(n), 1), MAX(n)
  FROM (SELECT rule_code, alert_date, COUNT(*) n FROM fraud_alert
        WHERE alert_date >= (SELECT MIN(trx_date) + 30 FROM fct_transactions) GROUP BY rule_code, alert_date)
  GROUP BY rule_code ORDER BY rule_code""")
q("просрочка по корзинам на последний снимок: дата, корзина, кредитов, просроченная сумма, доля", """
  SELECT TO_CHAR(snapshot_date, 'YYYY-MM-DD'), bucket, loans, overdue_amount, loan_share FROM v_dpd_buckets
  WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM mart_loan_dpd)
  ORDER BY DECODE(bucket, '0', 0, '1-30', 1, '31-60', 2, '61-90', 3, 4)""")
q("roll rate сентябрь → октябрь: из корзины, в корзину, кредитов, доля", """
  SELECT from_bucket, to_bucket, loans, loan_share FROM v_dpd_roll_rate
  WHERE from_month_end = DATE '2026-09-30'
  ORDER BY DECODE(from_bucket, '0', 0, '1-30', 1, '31-60', 2, '61-90', 3, 4), to_bucket""")
