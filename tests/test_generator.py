from datetime import date, timedelta

import pytest

from bra.generator import FRAUD_SEQ, REPORT_MAX_DELAY, Bank, Config, add_months

CFG = Config(n_clients=2_000, n_merchants=200, n_loans=300)
DAY = date(2026, 6, 10)


@pytest.fixture(scope="module")
def bank() -> Bank:
    return Bank(CFG)


def test_same_day_same_rows(bank):
    # идемпотентность загрузки дня держится на этом
    assert bank.transactions(DAY) == Bank(CFG).transactions(DAY)
    assert bank.fraud_reports(DAY) == Bank(CFG).fraud_reports(DAY)


def test_rows_are_inside_the_day_and_ids_unique(bank):
    rows = bank.transactions(DAY)
    assert all(DAY == r[3].date() for r in rows)
    assert len({r[0] for r in rows}) == len(rows)
    assert all(r[4] > 0 for r in rows)
    # ~0,3 операции на карту в день
    assert 0.25 < len(rows) / len(bank.cards) < 0.4


def test_reserved_range_holds_exactly_the_fraud(bank):
    # по этому признаку сверяем источник в SQL: номер > 900000 ⇔ мошенничество
    for d in range(30):
        day = DAY + timedelta(days=d)
        fraud = {i for c in bank.fraud_cases(day) for i in c.fraud_ids}
        reserved = {r[0] for r in bank.transactions(day) if r[0] % 1_000_000 > FRAUD_SEQ}
        assert fraud and reserved == fraud


def _cases(bank, kind, days=30):
    found = [c for d in range(days) for c in bank.fraud_cases(DAY + timedelta(days=d)) if c.kind == kind]
    assert found, kind
    return found


def test_velocity_is_a_burst_within_an_hour(bank):
    for case in _cases(bank, "VELOCITY"):
        ts = [r[3] for r in case.rows]
        assert len(ts) >= 6 and max(ts) - min(ts) <= timedelta(hours=1, minutes=30)
        assert {r[5] for r in case.rows} == {"ONLINE"}


def test_geo_goes_abroad_soon_after_home(bank):
    for case in _cases(bank, "GEO"):
        home, *abroad = case.rows
        assert home[6] == "KZ" and home[0] not in case.fraud_ids
        assert all(r[6] != "KZ" for r in abroad)
        assert abroad[0][3] - home[3] <= timedelta(hours=2)


def test_ato_is_night_p2p_from_new_device(bank):
    for case in _cases(bank, "ATO"):
        assert all(r[5] == "P2P" and r[7].startswith("F") and r[3].hour < 6 for r in case.rows)


def test_reports_point_to_fraud_of_last_two_weeks(bank):
    known = {i for d in range(1, REPORT_MAX_DELAY + 1)
             for c in bank.fraud_cases(DAY - timedelta(days=d)) for i in c.fraud_ids}
    reports = [r for d in range(REPORT_MAX_DELAY) for r in bank.fraud_reports(DAY + timedelta(days=d))]
    assert reports
    assert all(r[1] >= DAY for r in reports)
    # жалобы на случаи DAY-14..DAY-1 приходят не позже DAY+13 → все известны
    first_two_weeks = [r for r in reports if r[1] == DAY]
    assert {r[0] for r in first_two_weeks} <= known


def test_no_reports_before_history_start(bank):
    assert bank.fraud_reports(CFG.start) == []


def test_add_months_clamps_end_of_month():
    assert add_months(date(2026, 1, 31), 1) == date(2026, 2, 28)
    assert add_months(date(2026, 11, 30), 2) == date(2027, 1, 30)
    assert add_months(date(2026, 12, 15), 1) == date(2027, 1, 15)


def test_loan_payments_follow_issue(bank):
    loans = {l[0]: l for l in bank.loans_issued(None, CFG.start + timedelta(days=CFG.horizon_days))}
    for d in range(60):
        day = CFG.start + timedelta(days=d)
        for _, loan_id, paid_on, amount in bank.payments(day):
            assert paid_on > loans[loan_id][2]
            assert amount == loans[loan_id][5]
