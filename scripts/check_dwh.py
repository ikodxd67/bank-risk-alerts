"""Сверка хранилища с источником и состояние загрузок. Запуск: .venv/Scripts/python scripts/check_dwh.py"""
import sys

from bra import db

sys.stdout.reconfigure(encoding="utf-8")
db.load_env()
cur = db.connect("dwh").cursor()


def q(title: str, sql: str) -> None:
    print(f"\n-- {title}")
    for row in cur.execute(sql):
        print("  ", *row)


q("журнал загрузок: шаг, статус, запусков, строк всего, среднее время, с", """
  SELECT step, status, COUNT(*), SUM(row_cnt),
         ROUND(AVG(EXTRACT(SECOND FROM finished_at - started_at) + 60 * EXTRACT(MINUTE FROM finished_at - started_at)), 2)
  FROM etl_log GROUP BY step, status ORDER BY step, status""")
q("ошибки в журнале", """
  SELECT step, TO_CHAR(load_date, 'YYYY-MM-DD'), SUBSTR(REPLACE(message, CHR(10), ' | '), 1, 160)
  FROM etl_log WHERE status = 'ERROR' ORDER BY log_id""")
q("сверка по месяцам: источник (операций, сумма) и хранилище (операций, сумма)", """
  SELECT s.m, s.n, s.amt, f.n, f.amt, CASE WHEN s.n = f.n AND s.amt = f.amt THEN 'OK' ELSE 'DIFF' END
  FROM (SELECT TO_CHAR(trx_ts, 'YYYY-MM') m, COUNT(*) n, SUM(amount) amt
        FROM src.transactions GROUP BY TO_CHAR(trx_ts, 'YYYY-MM')) s
  FULL JOIN (SELECT TO_CHAR(trx_date, 'YYYY-MM') m, COUNT(*) n, SUM(amount) amt
             FROM fct_transactions GROUP BY TO_CHAR(trx_date, 'YYYY-MM')) f ON f.m = s.m
  ORDER BY 1""")
q("партиции факта (interval создаёт их сами)", """
  SELECT partition_position, partition_name, high_value
  FROM user_tab_partitions WHERE table_name = 'FCT_TRANSACTIONS' ORDER BY partition_position""")

print("\n-- план запроса за один день: читается одна партиция (Pstart = Pstop)")
cur.execute("EXPLAIN PLAN FOR SELECT SUM(amount) FROM fct_transactions WHERE trx_date = DATE '2026-07-15'")
for (line,) in cur.execute("SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'BASIC +PARTITION'))"):
    print("  ", line)

q("дубли trx_id в факте (должно быть 0)",
  "SELECT COUNT(*) FROM (SELECT trx_id FROM fct_transactions GROUP BY trx_id HAVING COUNT(*) > 1)")
q("измерения: версий клиента, клиентов, открытых версий, карт, продавцов", """
  SELECT (SELECT COUNT(*) FROM dim_client), (SELECT COUNT(DISTINCT client_id) FROM dim_client),
         (SELECT COUNT(*) FROM dim_client WHERE valid_to = DATE '9999-12-31'),
         (SELECT COUNT(*) FROM dim_card), (SELECT COUNT(*) FROM dim_merchant) FROM dual""")
q("пересекающиеся версии клиента (должно быть 0)", """
  SELECT COUNT(*) FROM dim_client a JOIN dim_client b
    ON a.client_id = b.client_id AND a.client_sk < b.client_sk
   AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to""")
