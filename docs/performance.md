# Performance notes

Measured on 2026-11-11 by [`scripts/perf.py`](../scripts/perf.py); raw output with full plans is in
[`evidence/step-5-perf.txt`](evidence/step-5-perf.txt). Oracle Database 26ai Free (Release 23.26.3)
in Docker on a laptop, `NOARCHIVELOG`, synthetic data. Absolute times are laptop times; the
ratios and the session statistics are the point.

## 1. Loading the same rows four ways

The task: copy July's card transactions from the source view `v_trx_src` (source joined to
`dim_card` and point-in-time `dim_client`) into a scratch table. Code: [`sql/perf/pkg_perf.sql`](../sql/perf/pkg_perf.sql).

| Method | What it does |
|---|---|
| `row_by_row` | cursor `FOR` loop, one `INSERT` per row |
| `bulk_forall` | `BULK COLLECT ... LIMIT 1000` into a collection, `FORALL` insert per batch |
| `one_sql` | one `INSERT ... SELECT` |
| `one_sql_append` | the same with `/*+ APPEND */` (direct-path insert above the high-water mark) |

**One month, 672 860 rows, median of 3 runs** (session statistics from `v$mystat`):

| Method | Seconds | SQL executions | Cursor fetches | Redo, MB | CPU, s | Logical reads |
|---|---|---|---|---|---|---|
| `row_by_row` | 11.92 | 672 865 | 6 729 | 233.3 | 7.06 | 1 439 482 |
| `bulk_forall` | 3.35 | 678 | 673 | 63.5 | 2.07 | 746 981 |
| `one_sql` | 2.57 | 13 | — | 63.3 | 0.77 | 106 435 |
| `one_sql_append` | 1.26 | 155 | — | 0.2 | 1.11 | 44 725 |

**One day, 20 171 rows, median of 3 runs:** `row_by_row` 0.37 s, `bulk_forall` 0.09 s,
`one_sql` 0.23 s, `one_sql_append` 0.27 s (why `one_sql` loses here is in §1.4).

### What the numbers say

1. **Row by row costs one SQL execution per row.** 672 865 executions vs 13: each `INSERT` is a
   switch from PL/SQL to the SQL engine. It also writes 3.7× more redo for the same rows:
   each single-row insert carries its own redo overhead, while array inserts share it.
2. **The fetch side of the loop was already batched.** 6 729 fetches for 672 860 rows is
   100 rows per fetch: the PL/SQL compiler turns a cursor `FOR` loop into array fetches of 100.
   The package is compiled with `PLSQL_OPTIMIZE_LEVEL = 2` (`user_plsql_object_settings`).
   The slow part is the per-row `INSERT`, not reading.
   `BULK COLLECT LIMIT 1000` makes 673 fetches, and `FORALL` turns 672 860 inserts into 673.
3. **`BULK COLLECT` + `FORALL` is 3.6× faster than row by row**, with the same redo as one SQL.
   It is the right tool when rows need PL/SQL logic between read and write. When they don't,
   one SQL statement is simpler and at least as fast.
4. **`APPEND` writes almost no redo here (0.2 MB vs 63 MB) and is the fastest on a month.**
   The database is in `NOARCHIVELOG`, so a direct-path insert does not log the data blocks. In
   `ARCHIVELOG` (any production database) it would log them unless the table is `NOLOGGING`,
   and a `NOLOGGING` load cannot be recovered from backups. Its costs:
   - It takes an exclusive table lock (`LOCK TABLE "PERF_TRX" IN EXCLUSIVE MODE` is visible in `v$sql`).
   - The table cannot be read in the same transaction (ORA-12838).
   - It always writes above the high-water mark. It also costs about 155 extra SQL executions on
     every run: recursive calls, most likely space allocation (not investigated further).
   - On a single day it is slower than a plain insert.

   The warehouse uses `APPEND` only where it fits: `reload_month` fills an empty exchange table
   with it.

### 1.4 Why `one_sql` lost on a single day

This one is about plans, not methods. `perf.py` truncates the scratch table before every run.
`TRUNCATE` is DDL and invalidates every cursor on that table, so the `INSERT ... SELECT` is
re-optimized on each run. After statistics were gathered it chose a full scan of
`TRANSACTIONS`. The `BULK COLLECT` cursor reads only `v_trx_src`, so it is not invalidated. It
keeps the plan from its first parse, an index range scan with the day's peeked binds.

That same cursor then ran for the month with the day's plan. So part of the logical reads
of `row_by_row` and `bulk_forall` on the month come from the plan, not from the method.
Execution counts, fetches and redo do not depend on the plan. Both plans are in the evidence file.

Why does the optimizer avoid the index? See §2.1.

## 2. Plans before and after

All plans are actual (`gather_plan_statistics`, `DBMS_XPLAN.DISPLAY_CURSOR(... 'ALLSTATS LAST')`),
taken on the second run with a warm cache. Every query returns the same row: 20 171
transactions, 265 673 333.58.

### 2.1 Function on an indexed column (`src.transactions`, 4.2 M rows, index on `trx_ts`)

| Query | Plan | Buffers | Time |
|---|---|---|---|
| `TRUNC(trx_ts) = DATE '2026-07-15'` | `TABLE ACCESS FULL` | 32 304 | 0.564 s |
| `trx_ts >= DATE '2026-07-15' AND trx_ts < DATE '2026-07-16'` | `TABLE ACCESS FULL` | 32 304 | 0.122 s |
| same range, `/*+ INDEX(t ix_transactions_ts) */` | `INDEX RANGE SCAN` → `TABLE ACCESS BY INDEX ROWID BATCHED` | 20 199 | 0.012 s |

- **`TRUNC(trx_ts)` hides the column from the index.** The index stores `trx_ts`, not
  `TRUNC(trx_ts)`. With the function the only possible access is a full scan, and `TRUNC` runs
  for each of 4.2 M rows: 0.56 s vs 0.12 s for the same full scan without the function.
- **With the plain range the optimizer still chose the full scan.** The reason is the
  clustering factor: how many table blocks you visit when you read the index in order.

  | Index | Clustering factor | Rows | Table blocks |
  |---|---|---|---|
  | `IX_TRANSACTIONS_TS` | 4 219 150 | 4 244 815 | 32 537 |
  | primary key (`trx_id`) | 42 814 | 4 353 598 | 32 537 |

  The `trx_ts` clustering factor is close to the row count: neighbouring index entries point
  to different blocks. The generator writes a day card by card, not in time order, so rows of
  one day sit in the same few hundred blocks, but in random order. The cost model counts a
  block visit per row and expects physical I/O. Under that model 20 k single-block visits lose
  to a 32 k-block multiblock scan.
- **With a warm cache the index is 10× faster anyway** (0.012 s, 20 199 buffers). This is the
  classic case where the optimizer is right by its model and wrong for this box.
- **The fix is in the data, not in a hint.** Insert the source sorted by `trx_ts`, or rebuild the
  table ordered by it, and the clustering factor drops to about the block count. If queries
  really must filter by `TRUNC(trx_ts)`, a function-based index on `TRUNC(trx_ts)` serves them
  (not measured here).
- **The warehouse avoids the question.** Facts are partitioned by `trx_date`, and a day is a
  partition read (§2.2).

### 2.2 Function on the partition key (`fct_transactions`, monthly interval partitions)

| Query | Plan | Partitions read | Buffers | Time |
|---|---|---|---|---|
| `TO_CHAR(trx_date, 'YYYY-MM-DD') = '2026-07-15'` | `PARTITION RANGE ALL` | 8 (Pstart 1, Pstop 1048575) | 49 625 | 0.552 s |
| `trx_date = DATE '2026-07-15'` | `PARTITION RANGE SINGLE` | 1 (partition 8) | 8 063 | 0.021 s |

A function on the partition key turns off partition pruning: Oracle cannot tell which
partition holds `TO_CHAR(...) = '2026-07-15'`, so it scans all of them. Here that means 6× the
buffers and 26× the time. The `Reads` column shows the full scan of all partitions also went to
disk (49 601 reads), while the single partition was served from memory. Every daily procedure
in `pkg_dds` and `pkg_marts` filters on the bare `trx_date` / `trx_ts` for this reason.

## 3. Takeaways for the warehouse code

- **Set-based SQL first.** `pkg_dds` and `pkg_marts` are `INSERT ... SELECT` / `MERGE`. PL/SQL
  loops only where a row needs procedural logic, and then as `BULK COLLECT LIMIT` + `FORALL`.
- **`APPEND` only into empty or exchange tables in batch windows**, never in concurrent daily
  inserts.
- **Filter on the bare column.** Write `col >= :d AND col < :d + 1`, not `TRUNC(col) = :d`.
  On partition keys this matters most.
- **Check the plan, not the intent.** An index existing doesn't mean it is used.
  Clustering factor and bind peeking decided two of the results above.
