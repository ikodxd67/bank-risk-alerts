"""Интеграционные тесты витрин (нужен Oracle с загруженными dds и витринами за май–октябрь)."""
from collections import defaultdict
from datetime import date, datetime, timedelta
from decimal import Decimal

import oracledb
import pytest

from bra import db
from bra.generator import Bank, add_months

db.load_env()
try:
    db.connect("dwh").close()
except (oracledb.Error, KeyError):
    pytest.skip("Oracle недоступен", allow_module_level=True)

DAY = date(2026, 7, 15)
SNAPSHOT = date(2026, 10, 31)


@pytest.fixture(scope="module")
def dwh():
    with db.connect("dwh") as conn:
        yield conn


def test_turnover_adds_up_to_fact(dwh):
    cur = dwh.cursor()
    mart = cur.execute("SELECT SUM(trx_cnt), SUM(declined_cnt), SUM(approved_amount)"
                       " FROM mart_daily_turnover WHERE report_date = :d", d=DAY).fetchone()
    fact = cur.execute("SELECT COUNT(*), COUNT(CASE WHEN status = 'DECLINED' THEN 1 END),"
                       " SUM(CASE WHEN status = 'APPROVED' THEN amount END)"
                       " FROM fct_transactions WHERE trx_date = :d", d=DAY).fetchone()
    assert mart == fact


def test_dpd_matches_independent_python_calculation(dwh):
    """Та же просрочка, посчитанная заново на Python прямо по источнику, по правилу
    графика из генератора (add_months), — должна совпасть по каждому кредиту."""
    oracledb.defaults.fetch_decimals = True   # деньги точно, без float
    try:
        cur = dwh.cursor()
        loans = cur.execute("SELECT loan_id, issued_on, term_months, monthly_payment FROM src.loans"
                            " WHERE issued_on <= :d", d=SNAPSHOT).fetchall()
        paid = defaultdict(Decimal)
        for loan_id, amount in cur.execute("SELECT loan_id, amount FROM src.loan_payments WHERE paid_on <= :d",
                                           d=SNAPSHOT):
            paid[loan_id] += amount
        expected = {}
        for loan_id, issued, term, monthly in loans:
            issued, term = issued.date(), int(term)   # с fetch_decimals срок тоже Decimal
            if paid[loan_id] >= term * monthly:
                continue                                  # погашен — в снимок не попадает
            unpaid = [k for k in range(1, term + 1)
                      if add_months(issued, k) <= SNAPSHOT and k * monthly > paid[loan_id]]
            expected[loan_id] = (SNAPSHOT - add_months(issued, unpaid[0])).days if unpaid else 0
        mart = dict(cur.execute("SELECT loan_id, dpd FROM mart_loan_dpd WHERE snapshot_date = :d", d=SNAPSHOT))
    finally:
        oracledb.defaults.fetch_decimals = False
    assert len(expected) > 5_000
    assert mart == expected
    assert sum(1 for v in expected.values() if v > 90) > 0   # дефолтные кредиты дошли до 90+


def alerts(dwh, rule):
    return dwh.cursor().execute("SELECT COUNT(*), MIN(threshold), MAX(threshold) FROM fraud_alert"
                                " WHERE alert_date = :d AND rule_code = :r", d=DAY, r=rule).fetchone()


def test_threshold_lives_in_table(dwh):
    """Порог правила меняется UPDATE-ом таблицы — без выкатки кода.
    Порог понижаем, а не повышаем: при повышении срабатываний за день может стать
    ноль, и проверить, что новый порог записан рядом со срабатыванием, будет не на чем."""
    cur = dwh.cursor()
    (old,) = cur.execute("SELECT threshold FROM fraud_rule WHERE rule_code = 'AMOUNT_30D'").fetchone()
    before, *_ = alerts(dwh, "AMOUNT_30D")
    try:
        cur.execute("UPDATE fraud_rule SET threshold = 4 WHERE rule_code = 'AMOUNT_30D'")
        dwh.commit()
        cur.callproc("pkg_marts.build_fraud", [DAY])
        after, low, high = alerts(dwh, "AMOUNT_30D")
        assert after > before and low == high == 4
    finally:
        cur.execute("UPDATE fraud_rule SET threshold = :1 WHERE rule_code = 'AMOUNT_30D'", [old])
        dwh.commit()
        cur.callproc("pkg_marts.build_fraud", [DAY])
    assert alerts(dwh, "AMOUNT_30D")[0] == before


def test_rules_catch_planted_fraud():
    """Проверка по разметке генератора — её хранилище не видит. За июль каждая
    карта-день с подложенным мошенничеством должна получить хотя бы одно срабатывание."""
    bank = Bank()
    with db.connect("dwh") as conn:
        flagged = set(conn.cursor().execute(
            "SELECT DISTINCT card_id, alert_date FROM fraud_alert"
            " WHERE alert_date BETWEEN DATE '2026-07-01' AND DATE '2026-07-31'"))
    missed, total = defaultdict(int), defaultdict(int)
    for d in range(31):
        day = date(2026, 7, 1) + timedelta(days=d)
        for case in bank.fraud_cases(day):
            card = case.rows[0][1]
            total[case.kind] += 1
            missed[case.kind] += (card, datetime.combine(day, datetime.min.time())) not in flagged
    recall = {kind: 1 - missed[kind] / total[kind] for kind in total}
    assert all(r >= RECALL_FLOOR[kind] for kind, r in recall.items()), recall


# Защита от регресса: прогон 2026-11-11 дал за июль VELOCITY, GEO, ATO — 1.0, AMOUNT — 0.733.
# AMOUNT ниже, потому что у «холодных» карт меньше 3 покупок за 30 дней и правило молчит.
RECALL_FLOOR = {"VELOCITY": 0.95, "AMOUNT": 0.7, "GEO": 0.95, "ATO": 0.95}
