"""bra — команды проекта: накат схем, генерация источника, сводка."""
from __future__ import annotations

import argparse
import sys
import time
from datetime import date, timedelta

from bra import db, loader
from bra.generator import Bank, Config


def main(argv: list[str] | None = None) -> None:
    sys.stdout.reconfigure(encoding="utf-8")  # консоль Windows по умолчанию cp1251: «₸» и кириллица ломаются
    p = argparse.ArgumentParser(prog="bra")
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("migrate", help="накатить sql/<schema>/*.sql")
    m.add_argument("schema", choices=["src", "dwh"])
    sub.add_parser("init", help="справочники и история до начала операций")
    g = sub.add_parser("generate", help="операции за дни [start, end]")
    g.add_argument("--start", type=date.fromisoformat, default=Config.start)
    g.add_argument("--end", type=date.fromisoformat)
    sub.add_parser("stats", help="сводка по src")
    args = p.parse_args(argv)

    db.load_env()
    if args.cmd == "migrate":
        with db.connect(args.schema) as conn:
            applied = db.migrate(conn, db.ROOT / "sql" / args.schema)
        print("накатил:", ", ".join(applied) or "нечего")
    elif args.cmd == "init":
        with db.connect("src") as conn:
            loader.init(conn, Bank())
        print("справочники загружены")
    elif args.cmd == "generate":
        bank = Bank()
        day, end = args.start, args.end or args.start
        with db.connect("src") as conn:
            while day <= end:
                t = time.perf_counter()
                counts = loader.load_day(conn, bank, day)
                print(day, counts, f"{time.perf_counter() - t:.1f} с", flush=True)
                day += timedelta(days=1)
    else:
        with db.connect("src") as conn:
            print_stats(conn)


def print_stats(conn) -> None:
    cur = conn.cursor()
    for table in ["clients", "cards", "merchants", "transactions", "fraud_reports", "loans", "loan_payments"]:
        (n,) = cur.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
        print(f"{table:15} {n:>12,}".replace(",", " "))
    print("\nпо месяцам: операции, сумма (млн ₸), подтверждённый фрод")
    for row in cur.execute("""
        SELECT TO_CHAR(t.trx_ts, 'YYYY-MM'), COUNT(*), ROUND(SUM(t.amount) / 1e6),
               COUNT(f.trx_id)
        FROM transactions t LEFT JOIN fraud_reports f ON f.trx_id = t.trx_id
        GROUP BY TO_CHAR(t.trx_ts, 'YYYY-MM') ORDER BY 1"""):
        print("  ", *row)
    print("\nжалобы по видам мошенничества")
    for row in cur.execute("SELECT fraud_type, COUNT(*) FROM fraud_reports GROUP BY fraud_type ORDER BY 2 DESC"):
        print("  ", *row)


if __name__ == "__main__":
    main()
