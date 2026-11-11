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


HISTORY_LAST_STATE_DIFF = """
SELECT COUNT(*) FROM (
    (SELECT client_id, full_name, birth_date, city, segment, changed_at FROM (
         SELECT h.*, ROW_NUMBER() OVER (PARTITION BY client_id ORDER BY changed_at DESC, hist_id DESC) AS rn
         FROM client_history h)
     WHERE rn = 1
     MINUS
     SELECT client_id, full_name, birth_date, city, segment, updated_at FROM clients)
    UNION ALL
    (SELECT client_id, full_name, birth_date, city, segment, updated_at FROM clients
     MINUS
     SELECT client_id, full_name, birth_date, city, segment, changed_at FROM (
         SELECT h.*, ROW_NUMBER() OVER (PARTITION BY client_id ORDER BY changed_at DESC, hist_id DESC) AS rn
         FROM client_history h)
     WHERE rn = 1))"""


def backfill_client_history(conn: oracledb.Connection, bank: Bank, end: date) -> int:
    """Журнал клиентов для базы, заполненной до появления триггера (002_client_history).
    Генератор детерминирован, поэтому изменения за прошлые дни восстанавливаются точно.
    Проверка: последнее состояние каждого клиента в журнале = строка в clients."""
    cur = conn.cursor()
    (count,) = cur.execute("SELECT COUNT(*) FROM client_history").fetchone()
    if count:
        raise SystemExit("журнал уже заполнен")
    rows = [(cid, name, birth, city, seg, reg) for cid, name, birth, city, seg, reg, _ in bank.clients]
    names = {cid: (name, birth) for cid, name, birth, *_ in rows}
    day = bank.cfg.start
    while day <= end:
        rows += [(cid, *names[cid], city, seg, upd) for city, seg, upd, cid in bank.client_updates(day)]
        day += timedelta(days=1)
    _many(cur, "INSERT INTO client_history (client_id, full_name, birth_date, city, segment, changed_at)"
               " VALUES (:1, :2, :3, :4, :5, :6)", rows)   # порядок строк = порядок hist_id
    (diff,) = cur.execute(HISTORY_LAST_STATE_DIFF).fetchone()
    if diff:
        conn.rollback()
        raise SystemExit(f"журнал не сходится с clients: {diff} строк расходятся, ничего не записано")
    conn.commit()
    return len(rows)


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
    # перегенерация старого дня не должна откатывать клиента: изменение старше текущего — пропускаем
    _many(cur, "UPDATE clients SET city = :1, segment = :2, updated_at = :3"
               " WHERE client_id = :4 AND updated_at <= :5", [(*u, u[2]) for u in updates])
    conn.commit()
    return {"transactions": len(trx), "fraud_reports": len(reports), "loans": len(loans),
            "loan_payments": len(payments), "client_updates": len(updates)}
