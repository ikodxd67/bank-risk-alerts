"""Интеграционные тесты пакетов хранилища. Нужен живой Oracle со схемами src и dwh
(docker compose up, bra migrate/init/generate/load). Без базы — пропускаются.

Тесты меняют общую базу, поэтому каждый возвращает за собой всё, что тронул.
"""
from datetime import date, datetime, timedelta
from pathlib import Path

import oracledb
import pytest

from bra import db, loader
from bra.generator import Bank

db.load_env()
try:
    oracledb.connect(user="dwh", password=db.os.environ["DWH_PASSWORD"],
                     dsn=db.os.environ.get("ORACLE_DSN", "localhost:1521/FREEPDB1")).close()
except (oracledb.Error, KeyError):
    pytest.skip("Oracle недоступен", allow_module_level=True)

FIRST, OPEN = datetime(1900, 1, 1), datetime(9999, 12, 31)
LOADED_DAY = date(2026, 7, 15)          # день, который уже есть в хранилище
FUTURE = date(2099, 1, 1)               # дата для SCD2: заведомо позже любой версии


@pytest.fixture(scope="module")
def src():
    with db.connect("src") as conn:
        yield conn


@pytest.fixture(scope="module")
def dwh():
    with db.connect("dwh") as conn:
        yield conn


def fact_day(dwh, day):
    return dwh.cursor().execute(
        "SELECT COUNT(*), SUM(amount), SUM(client_sk) FROM fct_transactions WHERE trx_date = :d",
        d=day).fetchone()


def last_log(dwh, step, day):
    return dwh.cursor().execute(
        "SELECT status, row_cnt, message FROM etl_log WHERE step = :s AND load_date = :d"
        " ORDER BY log_id DESC FETCH FIRST 1 ROW ONLY", s=step, d=day).fetchone()


def test_old_day_reloads_facts_but_not_dims(dwh):
    """Прошлый день: факт перегружается сколько угодно раз, а измерения — нет (ORA-20002),
    иначе версии клиентов легли бы задним числом."""
    cur = dwh.cursor()
    before = fact_day(dwh, LOADED_DAY)
    for _ in range(2):
        cur.callproc("pkg_dds.load_transactions", [LOADED_DAY])
    assert fact_day(dwh, LOADED_DAY) == before
    (last_version,) = cur.execute("SELECT MAX(valid_from) FROM dim_client").fetchone()
    if last_version.date() > LOADED_DAY:
        with pytest.raises(oracledb.DatabaseError, match="ORA-20002"):
            cur.callproc("pkg_dds.run_day", [LOADED_DAY])
        cur.execute("DELETE FROM etl_log WHERE load_date = :d AND step = 'load_dims' AND status = 'ERROR'"
                    " AND message LIKE 'ORA-20002%'", d=LOADED_DAY)   # ожидаемая ошибка — не сбой дня
        dwh.commit()


def test_run_day_twice_gives_same_result(dwh):
    """Последний загруженный день — полный run_day дважды даёт то же самое."""
    cur = dwh.cursor()
    (day,) = cur.execute("SELECT MAX(trx_date) FROM fct_transactions").fetchone()
    day = day.date()
    before = fact_day(dwh, day)
    for _ in range(2):
        cur.callproc("pkg_dds.run_day", [day])
    assert fact_day(dwh, day) == before
    status, rows, _ = last_log(dwh, "load_transactions", day)
    assert (status, rows) == ("OK", before[0])
    src_day = cur.execute("SELECT COUNT(*), SUM(amount) FROM src.transactions"
                          " WHERE trx_ts >= :d AND trx_ts < :d + 1", d=day).fetchone()
    assert src_day == before[:2]


@pytest.fixture
def client_1(src, dwh):
    """Клиент 1: запоминаем источник и все версии в измерении, после теста возвращаем."""
    s, d = src.cursor(), dwh.cursor()
    src_row = s.execute("SELECT city, segment, updated_at FROM clients WHERE client_id = 1").fetchone()
    (hist_max,) = s.execute("SELECT MAX(hist_id) FROM client_history").fetchone()
    versions = d.execute("SELECT client_sk, client_id, full_name, birth_date, city, segment,"
                         " valid_from, valid_to FROM dim_client WHERE client_id = 1").fetchall()
    yield 1
    s.execute("UPDATE clients SET city = :1, segment = :2, updated_at = :3 WHERE client_id = 1", src_row)
    s.execute("DELETE FROM client_history WHERE hist_id > :1", [hist_max])   # и строки триггера от теста
    src.commit()
    d.execute("DELETE FROM dim_client WHERE client_id = 1")
    d.executemany("INSERT INTO dim_client (client_sk, client_id, full_name, birth_date, city, segment,"
                  " valid_from, valid_to) VALUES (:1, :2, :3, :4, :5, :6, :7, :8)", versions)
    d.execute("DELETE FROM etl_log WHERE load_date >= DATE '2098-01-01'")
    dwh.commit()


def versions(dwh, client_id):
    return dwh.cursor().execute(
        "SELECT city, segment, valid_from, valid_to FROM dim_client WHERE client_id = :1"
        " ORDER BY valid_from", [client_id]).fetchall()


def test_scd2(src, dwh, client_1):
    s, d = src.cursor(), dwh.cursor()
    (old_city, old_segment, start, _), = versions(dwh, client_1)
    assert start == FIRST
    new_city = "Oskemen" if old_city != "Oskemen" else "Almaty"
    day = datetime.combine(FUTURE, datetime.min.time())

    # изменение → старая версия закрыта днём изменения, открыта новая; повтор ничего не меняет
    s.execute("UPDATE clients SET city = :1, updated_at = :2 WHERE client_id = 1", [new_city, FUTURE])
    src.commit()
    for _ in range(2):
        d.callproc("pkg_dds.load_dims", [FUTURE])
    assert versions(dwh, client_1) == [(old_city, old_segment, FIRST, day),
                                       (new_city, old_segment, day, OPEN)]

    # второе изменение в тот же день правит версию дня, а не плодит версию нулевой длины
    new_segment = "PREMIUM" if old_segment == "MASS" else "MASS"
    s.execute("UPDATE clients SET segment = :1 WHERE client_id = 1", [new_segment])
    src.commit()
    d.callproc("pkg_dds.load_dims", [FUTURE])
    assert versions(dwh, client_1)[-1] == (new_city, new_segment, day, OPEN)
    assert len(versions(dwh, client_1)) == 2

    # «обновили, но ничего не поменяли» — новой версии нет
    next_day = FUTURE + timedelta(days=1)
    s.execute("UPDATE clients SET updated_at = :1 WHERE client_id = 1", [next_day])
    src.commit()
    d.callproc("pkg_dds.load_dims", [next_day])
    assert len(versions(dwh, client_1)) == 2

    # назад во времени нельзя
    with pytest.raises(oracledb.DatabaseError, match="ORA-20002"):
        d.callproc("pkg_dds.load_dims", [FUTURE - timedelta(days=1)])
    assert last_log(dwh, "load_dims", FUTURE - timedelta(days=1))[0] == "ERROR"


BAD_CARD, BAD_TRX = 999_999_999_999, 20260715700000


def test_client_versions_match_generator(dwh):
    """История клиентов, посчитанная заново на Python по генератору: на конец каждого дня
    берём состояние клиента, новая версия — когда оно отличается от прошлого. Должна
    совпасть с dim_client по каждому клиенту и дню (хранилище журнал не видит напрямую)."""
    cur = dwh.cursor()
    (last,) = cur.execute("SELECT MAX(trx_date) FROM fct_transactions").fetchone()
    bank = Bank()
    current = {cid: (city, seg) for cid, _, _, city, seg, _, _ in bank.clients}
    expected = {(cid, city, seg, FIRST) for cid, (city, seg) in current.items()}
    day = bank.cfg.start
    while day <= last.date():
        end_of_day = {cid: (city, seg) for city, seg, _, cid in bank.client_updates(day)}  # последнее за день
        for cid, state in end_of_day.items():
            if state != current[cid]:
                current[cid] = state
                expected.add((cid, *state, datetime.combine(day, datetime.min.time())))
        day += timedelta(days=1)
    actual = set(cur.execute("SELECT client_id, city, segment, valid_from FROM dim_client"
                             " WHERE valid_from <= :d", d=last))
    assert len(expected) > 50_000 + 5_000
    assert actual == expected


def test_regenerating_old_day_keeps_clients(src):
    """Перегенерация старого дня не откатывает клиентов к его изменениям (раньше откатывала)."""
    s = src.cursor()
    snapshot = "SELECT client_id, city, segment, updated_at FROM clients ORDER BY client_id"
    before = s.execute(snapshot).fetchall()
    (hist_max,) = s.execute("SELECT MAX(hist_id) FROM client_history").fetchone()
    try:
        loader.load_day(src, Bank(), LOADED_DAY)
        assert s.execute(snapshot).fetchall() == before
    finally:
        s.execute("DELETE FROM client_history WHERE hist_id > :1", [hist_max])  # повтор того же дня = те же строки
        src.commit()


def test_failed_load_keeps_the_day_and_logs_error(src, dwh):
    """Операция по карте, которой хранилище ещё не знает: загрузка падает целиком,
    DELETE дня откатывается, в журнале ERROR с текстом ошибки."""
    s, d = src.cursor(), dwh.cursor()
    before = fact_day(dwh, LOADED_DAY)
    s.execute("INSERT INTO cards VALUES (:1, 1, 'DEBIT', DATE '2026-07-01')", [BAD_CARD])
    s.execute("INSERT INTO transactions VALUES (:1, :2, NULL, :3, 1000, 'POS', 'KZ', NULL, 'APPROVED')",
              [BAD_TRX, BAD_CARD, datetime(2026, 7, 15, 12)])
    src.commit()
    try:
        with pytest.raises(oracledb.DatabaseError, match="ORA-01400"):
            d.callproc("pkg_dds.load_transactions", [LOADED_DAY])   # без load_dims — карты в dim_card нет
        assert fact_day(dwh, LOADED_DAY) == before
        status, _, message = last_log(dwh, "load_transactions", LOADED_DAY)
        assert status == "ERROR" and "ORA-01400" in message and "PKG_DDS" in message
    finally:
        s.execute("DELETE FROM transactions WHERE trx_id = :1", [BAD_TRX])
        s.execute("DELETE FROM cards WHERE card_id = :1", [BAD_CARD])
        src.commit()
        d.callproc("pkg_dds.load_transactions", [LOADED_DAY])       # последний статус дня снова OK
    assert fact_day(dwh, LOADED_DAY) == before


def test_date_with_time_is_rejected(dwh):
    bad = datetime(2026, 7, 15, 10, 30)
    cur = dwh.cursor()
    with pytest.raises(oracledb.DatabaseError, match="ORA-20001"):
        cur.callproc("pkg_dds.load_transactions", [bad])
    assert last_log(dwh, "load_transactions", bad)[0] == "ERROR"
    cur.execute("DELETE FROM etl_log WHERE load_date = :1", [bad])  # не оставлять ложную ошибку дня для алертов
    dwh.commit()


def test_reload_month_by_partition_exchange(dwh):
    cur = dwh.cursor()
    month, nxt = date(2026, 6, 1), date(2026, 7, 1)
    fact_sql = ("SELECT COUNT(*), SUM(amount), MIN(loaded_at) FROM fct_transactions"
                " WHERE trx_date >= :1 AND trx_date < :2")
    count, amount, _ = cur.execute(fact_sql, [month, nxt]).fetchone()
    parts = cur.execute("SELECT COUNT(*) FROM user_tab_partitions WHERE table_name = 'FCT_TRANSACTIONS'").fetchone()
    started = cur.execute("SELECT SYSTIMESTAMP FROM dual").fetchone()[0]

    cur.callproc("pkg_dds.reload_month", [month])

    count2, amount2, loaded = cur.execute(fact_sql, [month, nxt]).fetchone()
    src_month = cur.execute("SELECT COUNT(*), SUM(amount) FROM src.transactions"
                            " WHERE trx_ts >= :1 AND trx_ts < :2", [month, nxt]).fetchone()
    assert (count2, amount2) == (count, amount) == src_month
    assert loaded.replace(tzinfo=None) >= started.replace(tzinfo=None)   # строки действительно новые
    assert cur.execute("SELECT COUNT(*) FROM user_tab_partitions"
                       " WHERE table_name = 'FCT_TRANSACTIONS'").fetchone() == parts
    assert cur.execute("SELECT COUNT(*) FROM user_tables"
                       " WHERE table_name = 'FCT_TRANSACTIONS_EXCH'").fetchone() == (0,)
    assert last_log(dwh, "reload_month", month)[:2] == ("OK", count)


def test_migrate_fails_on_plsql_compile_error(dwh, tmp_path: Path):
    bad = tmp_path / "bad.sql"
    bad.write_text("CREATE OR REPLACE PROCEDURE tmp_broken IS BEGIN no_such_thing; END;\n/\n", encoding="utf-8")
    cur = dwh.cursor()
    try:
        with pytest.raises(RuntimeError, match="PLS-00201"):
            db._run_file(cur, bad)
    finally:
        cur.execute("DROP PROCEDURE IF EXISTS tmp_broken")
