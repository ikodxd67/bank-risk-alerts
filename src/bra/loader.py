"""Запись синтетического банка в схему src."""
from __future__ import annotations

from datetime import date, timedelta

import oracledb

from bra.generator import Bank

INSERT = {
    "clients": "INSERT INTO clients VALUES (:1, :2, :3, :4, :5, :6, :7)",
    "cards": "INSERT INTO cards VALUES (:1, :2, :3, :4)",
    "merchants": "INSERT INTO merchants VALUES (:1, :2, :3, :4)",
    "transactions": "INSERT INTO transactions VALUES (:1, :2, :3, :4, :5, :6, :7, :8, :9)",
    "fraud_reports": "INSERT INTO fraud_reports VALUES (:1, :2, :3)",
    "loan_payments": "INSERT INTO loan_payments VALUES (:1, :2, :3, :4)",
}
# кредит, выданный в перегружаемый день, мог уже получить платежи из следующих дней —
# удалить его нельзя (внешний ключ), поэтому вставляем только отсутствующие
INSERT_LOAN = """
INSERT INTO loans
SELECT :1, :2, :3, :4, :5, :6 FROM dual
WHERE NOT EXISTS (SELECT 1 FROM loans WHERE loan_id = :7)"""
# в обычном SQL позиционные переменные считаются по вхождениям, а не по именам,
# поэтому loan_id передаём второй раз седьмым значением


def _loan_rows(loans: list[tuple]) -> list[tuple]:
    return [(*loan, loan[0]) for loan in loans]


def _many(cur: oracledb.Cursor, sql: str, rows: list[tuple], sizes: tuple = ()) -> None:
    for i in range(0, len(rows), 50_000):
        if sizes:  # иначе драйвер угадывает тип колонки по первой строке, а там может быть NULL
            cur.setinputsizes(*sizes)
        cur.executemany(sql, rows[i:i + 50_000])


TRX_SIZES = (None, None, oracledb.DB_TYPE_NUMBER, None, None, None, None, 20, None)


def init(conn: oracledb.Connection, bank: Bank) -> None:
    """Справочники и всё, что было до начала истории операций."""
    cur = conn.cursor()
    (count,) = cur.execute("SELECT COUNT(*) FROM clients").fetchone()
    if count:
        raise SystemExit("src уже заполнена: сначала очистите схему (docker compose down -v)")
    _many(cur, INSERT["clients"], bank.clients)
    _many(cur, INSERT["cards"], bank.card_rows)
    _many(cur, INSERT["merchants"], bank.merchants)
    _many(cur, INSERT_LOAN, _loan_rows(bank.loans_issued(None, bank.cfg.start - timedelta(days=1))))
    _many(cur, INSERT["loan_payments"], bank.payments_before(bank.cfg.start))
    conn.commit()


def load_day(conn: oracledb.Connection, bank: Bank, day: date) -> dict[str, int]:
    """Один день источника одной транзакцией. Повторный запуск даёт то же самое."""
    cur = conn.cursor()
    cur.execute("DELETE FROM transactions WHERE trx_ts >= :d AND trx_ts < :d + 1", d=day)
    cur.execute("DELETE FROM fraud_reports WHERE reported_at = :d", d=day)
    cur.execute("DELETE FROM loan_payments WHERE paid_on = :d", d=day)

    trx = bank.transactions(day)
    reports = bank.fraud_reports(day)
    loans = bank.loans_issued(day, day)
    payments = bank.payments(day)
    updates = bank.client_updates(day)

    _many(cur, INSERT["transactions"], trx, TRX_SIZES)
    _many(cur, INSERT["fraud_reports"], reports)
    _many(cur, INSERT_LOAN, _loan_rows(loans))
    _many(cur, INSERT["loan_payments"], payments)
    _many(cur, "UPDATE clients SET city = :1, segment = :2, updated_at = :3 WHERE client_id = :4", updates)
    conn.commit()
    return {"transactions": len(trx), "fraud_reports": len(reports), "loans": len(loans),
            "loan_payments": len(payments), "client_updates": len(updates)}
