"""Замеры шага 5: способы загрузки и планы до/после.
Запуск: .venv/Scripts/python scripts/perf.py > docs/evidence/step-5-perf.txt
Нужен dwh с ролью SELECT_CATALOG_ROLE (v$mystat, v$sql, DBMS_XPLAN.DISPLAY_CURSOR).
"""
import sys
import time
from datetime import date

from bra import db

sys.stdout.reconfigure(encoding="utf-8")
db.load_env()
conn = db.connect("dwh")
cur = conn.cursor()
db._run_file(cur, db.ROOT / "sql" / "perf" / "pkg_perf.sql")

STATS = ("execute count", "redo size", "CPU used by this session", "session logical reads")
METHODS = ("row_by_row", "bulk_forall", "one_sql", "one_sql_append")
DAY = (date(2026, 7, 15), date(2026, 7, 16))
MONTH = (date(2026, 7, 1), date(2026, 8, 1))


def mystat() -> dict:
    return dict(cur.execute(
        "SELECT n.name, m.value FROM v$mystat m JOIN v$statname n ON n.statistic# = m.statistic#"
        " WHERE n.name IN (:1, :2, :3, :4)", STATS))


def cursor_fetches() -> tuple:
    # курсор цикла/BULK COLLECT в PL/SQL — статический SQL, Oracle хранит его текст в верхнем регистре
    return cur.execute("SELECT NVL(SUM(fetches), 0), NVL(SUM(rows_processed), 0) FROM v$sql"
                       " WHERE sql_text LIKE 'SELECT * FROM V_TRX_SRC WHERE TRX_TS >=%'").fetchone()


def run(method: str, rng: tuple) -> dict:
    cur.execute("TRUNCATE TABLE perf_trx")
    f0, s0 = cursor_fetches(), mystat()
    t = time.perf_counter()
    cur.callproc(f"pkg_perf.{method}", list(rng))
    seconds = time.perf_counter() - t
    s1, f1 = mystat(), cursor_fetches()
    (rows,) = cur.execute("SELECT COUNT(*) FROM perf_trx").fetchone()
    return {"s": seconds, "rows": rows, "fetches": f1[0] - f0[0],
            **{k: s1[k] - s0[k] for k in STATS}}


def show(title: str, results: dict) -> None:
    print(f"\n-- {title}")
    print(f"   {'способ':16}{'строк':>9}{'сек':>8}{'SQL-вызовов':>13}{'fetch курсора':>15}"
          f"{'redo, МБ':>10}{'CPU, с':>8}{'logical reads':>15}   (все 3 запуска, с)")
    for m, r in results.items():
        print(f"   {m:16}{r['rows']:>9}{r['s']:>8.2f}{r['execute count']:>13}{r['fetches']:>15}"
              f"{r['redo size'] / 2**20:>10.1f}{r['CPU used by this session'] / 100:>8.2f}"
              f"{r['session logical reads']:>15}   ({r['all']})")


print("# Шаг 5: замеры. Oracle Free 26ai (23.26.3) в Docker на ноутбуке, NOARCHIVELOG. Данные сгенерированы.")
run("one_sql", DAY)   # прогрев: кэш блоков источника и разбор курсоров

def median_of_3(rng: tuple) -> dict:
    out = {}
    for m in METHODS:
        tries = sorted((run(m, rng) for _ in range(3)), key=lambda r: r["s"])
        out[m] = tries[1]                                   # медиана из трёх по времени
        out[m]["all"] = " / ".join(f"{r['s']:.2f}" for r in tries)
    return out


show("один день 2026-07-15, медиана из 3 запусков", median_of_3(DAY))
show("месяц 2026-07, медиана из 3 запусков", median_of_3(MONTH))
cur.execute("TRUNCATE TABLE perf_trx")

# --- планы: фактические (gather_plan_statistics + ALLSTATS LAST) ---
with db.connect("src") as src:
    src.cursor().callproc("DBMS_STATS.GATHER_TABLE_STATS", ["SRC", "TRANSACTIONS"])
cur.callproc("DBMS_STATS.GATHER_TABLE_STATS", ["DWH", "FCT_TRANSACTIONS"])

CASES = [
    ("perf_a1", "функция на индексированной колонке: TRUNC(trx_ts) = день",
     "SELECT /*+ gather_plan_statistics */ COUNT(*) AS perf_a1, SUM(amount) FROM src.transactions"
     " WHERE TRUNC(trx_ts) = DATE '2026-07-15'"),
    ("perf_a2", "та же выборка диапазоном: trx_ts >= день AND trx_ts < день + 1",
     "SELECT /*+ gather_plan_statistics */ COUNT(*) AS perf_a2, SUM(amount) FROM src.transactions"
     " WHERE trx_ts >= DATE '2026-07-15' AND trx_ts < DATE '2026-07-16'"),
    ("perf_a3", "тот же диапазон, индекс навязан хинтом (оптимизатор сам выбрал полный просмотр)",
     "SELECT /*+ gather_plan_statistics INDEX(t ix_transactions_ts) */ COUNT(*) AS perf_a3, SUM(amount)"
     " FROM src.transactions t WHERE trx_ts >= DATE '2026-07-15' AND trx_ts < DATE '2026-07-16'"),
    ("perf_b1", "функция на ключе партиционирования: TO_CHAR(trx_date) = строка",
     "SELECT /*+ gather_plan_statistics */ COUNT(*) AS perf_b1, SUM(amount) FROM fct_transactions"
     " WHERE TO_CHAR(trx_date, 'YYYY-MM-DD') = '2026-07-15'"),
    ("perf_b2", "сам ключ: trx_date = день",
     "SELECT /*+ gather_plan_statistics */ COUNT(*) AS perf_b2, SUM(amount) FROM fct_transactions"
     " WHERE trx_date = DATE '2026-07-15'"),
]
print("\n-- почему оптимизатор не берёт индекс по trx_ts: clustering factor ≈ числу строк, а не блоков")
print("   индекс, clustering_factor, строк в индексе; блоков таблицы")
for row in cur.execute("SELECT i.index_name, i.clustering_factor, i.num_rows, t.blocks FROM all_indexes i"
                       " JOIN all_tables t ON t.owner = i.owner AND t.table_name = i.table_name"
                       " WHERE i.owner = 'SRC' AND i.table_name = 'TRANSACTIONS'"):
    print("  ", *row)
print("\n-- время запроса (второй запуск, кэш прогрет), сек")
for tag, title, sql in CASES:
    cur.execute(sql).fetchall()
    t = time.perf_counter()
    result = cur.execute(sql).fetchone()
    print(f"   {tag} {time.perf_counter() - t:.3f}  результат {result}  — {title}")

for tag, title, sql in CASES:
    print(f"\n-- план {tag}: {title}\n   {sql}")
    sql_id, child = cur.execute(
        "SELECT sql_id, child_number FROM v$sql WHERE sql_text LIKE :1 AND sql_text NOT LIKE '%v$sql%'"
        " ORDER BY last_active_time DESC FETCH FIRST 1 ROW ONLY", [f"%{tag}%"]).fetchone()
    for (line,) in cur.execute("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(:1, :2,"
                               " 'ALLSTATS LAST +PARTITION'))", [sql_id, child]):
        print("  ", line)
