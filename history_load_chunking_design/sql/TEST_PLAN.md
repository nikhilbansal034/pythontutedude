# Chunk planner — test plan and evidence checklist

How to run the SQL in this folder, what each run should show, and which screenshot to take. Share the
screenshots under their evidence IDs (E01, E02, …) so each can be checked against the expected result
here.

> This plan is for the synthetic test data. To run the planner on real tables in a client environment,
> follow `CLIENT_RUNBOOK.md` instead.

Everything runs in a **Snowflake Workspace**. Files with a `DECLARE … BEGIN … END;` block are run as one
unit: select the whole file, then run. Plain-SQL files can be run statement by statement.

## Before you start

| Setting | Where | Value for the test |
|---|---|---|
| Metadata location | `01`, `03`, `04`, `05`, `06` | `test_db.test_schema` |
| Test source schema | `02`, `03`, `04`, `05` | `TEST_DB.CHUNK_TEST_SRC` |
| Storage for test Iceberg tables | `02` → `ext_volume` | **`SNOWFLAKE_MANAGED`** (default): Snowflake stores the files, so no external volume is needed. Or the name of a volume your role may use (`SHOW EXTERNAL VOLUMES;`) |
| `BASE_LOCATION` prefix | `02` → `base_prefix` | Only used with a real external volume: `test/chunk_planner` (each run adds a timestamped sub-folder) |
| **Chunk size for the test** | `04` → `max_chunk_rows` | **`1000`**. The test tables are tiny, so the row cap is what forces chunking. Every expected result below assumes 1000 |
| Role | — | Needs `CREATE SCHEMA` on `TEST_DB`, use of the external volume, and `SELECT` / `INSERT` / `UPDATE` / `DELETE` on the metadata tables |
| Warehouse | — | Any. Its size does not change the plan |

### Using your own database and schema names

There are two locations, and every file must agree on both:

| Location | What it is | Set in |
|---|---|---|
| **Plan tables** (default `test_db.test_schema`) | Where `HIST_PLAN_TABLE` / `HIST_PLAN_CHUNK` live | `01` `SET meta_location` · `03` `metadata_database` + `metadata_schema` · `04` `metadata_database` + `metadata_schema` · `05` `SET meta_location` and Part B · `06` `SET meta_location` |
| **Test source** (default `TEST_DB.CHUNK_TEST_SRC`) | Where `02` builds the test tables, and what `04` plans | `02` `test_database` + `test_schema_src` · `03` the same · `04` `p_database` + `p_schema` · `05` `SET src_database` / `src_schema` and Part B · `06` the same |

**Run `01` first, for the plan-table location you chose.** `04` stops with *"Metadata location … is not
usable"* if the plan tables are not there. Keep the plan tables in a schema of their own, separate from the
schema being planned.

## The run sequence

| Run | File | Inputs to set | What it proves | Evidence |
|---|---|---|---|---|
| R0 | `01_metadata_ddl.sql` | — | The two metadata tables exist | **E01** |
| R1 | `02_test_setup.sql` | `ext_volume` (default `SNOWFLAKE_MANAGED`) | 11 test objects with the expected row counts | **E02** |
| R2 | `03_smoke_test.sql` | — | Every scripting construct the planner needs works in your account | **E03** |
| R3 | `04_chunk_planner.sql` | `p_tables = 'T01_CUR_SPREAD, T99_DOES_NOT_EXIST, t09_standard_table'`, `max_chunk_rows = 1000` | A bad name in the input list → report all problems, exit, write nothing (D12) | **E04**, then **E05** |
| R4 | `04_chunk_planner.sql` | `p_schema = 'NO_SUCH_SCHEMA'`, `p_tables = ''` | A bad schema → report and exit | **E06** |
| R5 | `04_chunk_planner.sql` | `p_schema = 'CHUNK_TEST_SRC'`, `p_tables = ''`, `max_chunk_rows = 1000` | Full schema run: every branch of the decision procedure | **E07** |
| R6 | `05_validate.sql` A1, A2, A3, A4, then Part B | — | Outcomes, every chunk boundary, tiling, and exactly-once coverage against the data | **E08–E12** |
| R7 | `04_chunk_planner.sql` | same as R5 | Re-run is safe: planned tables are skipped; T07 fails again without stopping the run; non-Iceberg objects keep one row each | **E13**, then A5 → **E14** |
| R8 | `04_chunk_planner.sql` | `p_tables = 't01_cur_spread'` (lower case), `p_force_replan = TRUE`, `max_chunk_rows = 1000` | Case-insensitive name resolution; a forced re-plan supersedes the old plan instead of editing it | **E15**, then A5 → **E16** |
| R9 | `05_validate.sql` Part B | — | Still exactly-once after the re-plan | **E17** |

To repeat from a clean state, run `06_reset_test_metadata.sql` and start again at R3.

**If a run used the wrong settings** (for example `max_chunk_rows` left at its default of 250 million, which plans
every test table as one `SINGLE` chunk), run `06` before re-testing. Otherwise the next run skips every table
as *already planned*. Check the `*** SUMMARY ***` row of each run: it must say `1000 rows max per chunk`.

**If the source schema holds other objects** besides T01–T11, they are counted in the summary (normally as
non-Iceberg SKIPPED). The summary counts change; A1, A2 and A5 list only the test tables, while A3, A4 and Part B would also list any other
Iceberg table that got planned.

## Expected results

### E02 — `02_test_setup.sql`

| Object | Rows | Built to test |
|---|---|---|
| `T01_CUR_SPREAD` | 9000 | CURRENT layout, `GRS_PROCESS_DATE` partition, 30 days × 300 (every other day): plain day ranges |
| `T02_HIST_BACKFILL_SPREAD` | 5800 | HISTORY layout, year/month/day partition, one 3,500-row backfill day **spread** over 70 minutes: in-day timestamp split |
| `T03_HIST_BACKFILL_SAME_TS` | 2900 | HISTORY layout, one 2,500-row day where every row has the **same** refined timestamp: hash split |
| `T04_SMALL` | 500 | Smaller than one chunk: single chunk |
| `T05_NULL_PARTITION` | 1750 | 150 rows with a NULL partition value: `NULL_VALUES` chunk |
| `T06_UNPARTITIONED_TS` | 2700 | Not partitioned, has `GRS_REFINED_TIMESTAMP`: fallback axis |
| `T07_NO_USABLE_COLUMN` | 2000 | No partition and no `GRS_*` columns: must **fail** cleanly |
| `T08_UNIQUE_ID_ONLY` | 2500 | Only `GRS_UNIQUE_ID`: whole-table hash buckets |
| `T09_STANDARD_TABLE` | 10 | Standard table: **skipped** |
| `T10_VIEW` | 10 | View: **skipped** |
| `T11_EMPTY` | 0 | Empty Iceberg table: single chunk with 0 rows |

### E03 — `03_smoke_test.sql`

Checks 1–8, 11 and 12 should be `PASS`. Checks 9 and 10 are optional capabilities:
- **Check 9 `PASS`**: the Iceberg partition spec is readable, and the planner records `PARTITION_VERIFIED = TRUE` on partitioned tables.
- **Check 9 `INFO`**: the planner falls back to the `GRS_PROCESS_*` naming convention and records `PARTITION_VERIFIED = FALSE`.
- **Check 10 `INFO`**: chunks are sized by `max_chunk_rows` only.

Neither `INFO` result changes any expected result below. **Any `FAIL` → stop and share the screenshot.**

### E04 — R3, bad names in the list

| TABLE_NAME | OUTCOME | REASON |
|---|---|---|
| `T99_DOES_NOT_EXIST` | `VALIDATION_FAILED` | not found in TEST_DB.CHUNK_TEST_SRC |
| `t09_standard_table` | `VALIDATION_FAILED` | exists but is not an Iceberg table (standard table) |
| `*** SUMMARY ***` | `EXITED` | Input validation failed: 2 of 3 table names are invalid. Nothing was written. |

**E05**: `SELECT COUNT(*) FROM test_db.test_schema.HIST_PLAN_TABLE;` returns **0**. `T01_CUR_SPREAD` was valid, but
nothing is planned when any name is wrong.

### E06 — R4, bad schema

One `VALIDATION_FAILED` row, *Schema NO_SUCH_SCHEMA not found in database TEST_DB…*, and the `EXITED`
summary.

### E07 — R5, full schema run (`max_chunk_rows = 1000`)

| TABLE_NAME | OUTCOME | LAYER | CHUNK_AXIS | CHUNK_METHOD | CHUNK_COUNT | TOTAL_ROWS |
|---|---|---|---|---|---|---|
| `T09_STANDARD_TABLE` | SKIPPED — *Not an Iceberg table (standard table)* | | | | | |
| `T10_VIEW` | SKIPPED — *Not an Iceberg table (view)* | | | | | |
| `T07_NO_USABLE_COLUMN` | FAILED — *No usable chunk column…* | UNKNOWN | NONE | | | 2000 |
| `T01_CUR_SPREAD` | PLANNED | CURRENT | PARTITION_DAY | DAY_RANGES | 10 | 9000 |
| `T02_HIST_BACKFILL_SPREAD` | PLANNED | HISTORY | PARTITION_YMD | DAY_RANGES_WITH_SPLITS | 7 | 5800 |
| `T03_HIST_BACKFILL_SAME_TS` | PLANNED | HISTORY | PARTITION_YMD | DAY_RANGES_WITH_SPLITS | 4 | 2900 |
| `T04_SMALL` | PLANNED | CURRENT | PARTITION_DAY | SINGLE | 1 | 500 |
| `T05_NULL_PARTITION` | PLANNED | CURRENT | PARTITION_DAY | DAY_RANGES | 3 | 1750 |
| `T06_UNPARTITIONED_TS` | PLANNED | CURRENT | REFINED_TS_DAY | DAY_RANGES | 3 | 2700 |
| `T08_UNIQUE_ID_ONLY` | PLANNED | UNKNOWN | UNIQUE_ID_HASH | HASH_BUCKETS | 3 | 2500 |
| `T11_EMPTY` | PLANNED | CURRENT | PARTITION_DAY | SINGLE | 1 | 0 |
| `*** SUMMARY ***` | COMPLETED — *Objects in scope: 11 \| Planned: 8 \| Failed: 1 \| Skipped: 2 (non-Iceberg: 2, already planned: 0) \| Target: 10 GB / 1000 rows max per chunk …* | | | | | |

`T06` shows `LAYER = CURRENT` because it carries a `ROW_HASH` column. Layer is information only.

### The chunks behind E07 (what A2 checks)

These were computed by hand and confirmed by an independent simulation of the algorithm.

| Table | # | Type | Day range `[start, end)` | Inside the day | Rows |
|---|---|---|---|---|---|
| T01 | 1–10 | DAY_RANGE | `NULL→01-07`, `01-07→01-13`, … `02-18→02-24`, `02-24→NULL` (3 data days each) | | 900 each |
| T02 | 1 | DAY_RANGE | `NULL → 2026-03-10` | | 300 |
| T02 | 2 | DAY_SUBRANGE | `03-10 → 03-11` | refined ts `NULL → 00:20` | 1000 |
| T02 | 3 | DAY_SUBRANGE | `03-10 → 03-11` | `00:20 → 00:40` | 1000 |
| T02 | 4 | DAY_SUBRANGE | `03-10 → 03-11` | `00:40 → 01:00` | 1000 |
| T02 | 5 | DAY_SUBRANGE | `03-10 → 03-11` | `01:00 → NULL` | 500 |
| T02 | 6 | DAY_RANGE | `03-11 → 03-16` | | 1000 |
| T02 | 7 | DAY_RANGE | `03-16 → NULL` | | 1000 |
| T03 | 1–3 | DAY_HASH | `04-05 → 04-06` | `GRS_UNIQUE_ID` bucket 0, 1, 2 of 3 | 833, 833, 834 (estimates) |
| T03 | 4 | DAY_RANGE | `04-06 → NULL` | | 400 |
| T04 | 1 | ALL | | | 500 |
| T05 | 1 | DAY_RANGE | `NULL → 06-03` | | 800 |
| T05 | 2 | DAY_RANGE | `06-03 → NULL` | | 800 |
| T05 | 3 | NULL_VALUES | partition value is NULL | | 150 |
| T06 | 1–3 | DAY_RANGE | `NULL→05-03`, `05-03→05-05`, `05-05→NULL` (UTC date of `GRS_REFINED_TIMESTAMP`) | | 900 each |
| T08 | 1–3 | HASH | whole table | `GRS_UNIQUE_ID` bucket 0, 1, 2 of 3 | 833, 833, 834 (estimates) |
| T11 | 1 | ALL | | | 0 |

### E08–E12 — `05_validate.sql`

| Evidence | Query | Pass condition |
|---|---|---|
| E08 | A1 | 11 rows, every `RESULT = PASS` |
| E09 | A2 | 32 rows, every `RESULT = PASS` (a `FAIL` row shows expected and actual side by side) |
| E10 | A3 | Every row `PASS`: chunk rows add up to the table |
| E11 | A4 | Every row `PASS`: no gaps, no overlaps between consecutive chunks |
| E12 | Part B | 8 rows, all `PASS`. `ROWS_IN_NO_CHUNK = 0` and `ROWS_IN_2PLUS_CHUNKS = 0` for every table. For range chunks, actual rows equal the estimate (`RANGE_CHUNKS_EXACT` "n of n"). Hash chunks are excluded from the exact check: their real counts vary around 833/834, which is expected |

### E13–E17 — re-runs

- **E13 (R7):**
  - The 8 planned tables show `SKIPPED — Already planned (plan …)`.
  - `T07` shows `FAILED` again.
  - `T09` and `T10` show `SKIPPED — Not an Iceberg table`.
  - Summary: *Planned: 0 | Failed: 1 | Skipped: 10 (non-Iceberg: 2, already planned: 8)*.
- **E14 (A5 after R7):**
  - `T07` has two rows: the first now `SUPERSEDED` and inactive, the second `FAILED` and active.
  - `T09` and `T10` still have exactly **one** `SKIPPED` row each.
  - `T01` has one `PLANNED` active row.
- **E15 (R8):** `T01_CUR_SPREAD` is `PLANNED` again with 10 chunks. The lower-case input resolved to the real name.
- **E16 (A5 after R8):** `T01` has two rows: the first `SUPERSEDED` and inactive, the second `PLANNED` and active.
- **E17 (R9):** Part B still all `PASS`.

## Useful queries once it has run

```sql
-- how many chunks each table has, and on which column
SELECT TABLE_NAME, PLAN_STATUS, CHUNK_AXIS, AXIS_COLUMNS, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS,
       ROUND(TOTAL_BYTES / POWER(1024, 3), 2) AS TOTAL_GB, STATUS_REASON
  FROM test_db.test_schema.HIST_PLAN_TABLE
 WHERE IS_ACTIVE
 ORDER BY PLAN_STATUS, TABLE_NAME;

-- the range of every chunk for one table
SELECT CHUNK_SEQ, CHUNK_TYPE, DAY_START, DAY_END, SUB_COLUMN, SUB_START_TS, SUB_END_TS,
       HASH_BUCKET, HASH_MODULUS, ESTIMATED_ROWS, ROUND(ESTIMATED_BYTES / POWER(1024, 3), 3) AS EST_GB
  FROM test_db.test_schema.HIST_PLAN_CHUNK
 WHERE PLAN_ID = (SELECT PLAN_ID FROM test_db.test_schema.HIST_PLAN_TABLE
                   WHERE TABLE_NAME = 'T02_HIST_BACKFILL_SPREAD' AND IS_ACTIVE AND PLAN_STATUS = 'PLANNED')
 ORDER BY CHUNK_SEQ;
```

## What is not covered by this test

- **Real-data volumes and skew.** That is the reconnaissance step in `../design_review.md` §9: run the
  planner on 3–5 real CURRENT/HISTORY table pairs with the production sizing, and look at the chunk counts.
- **Partition transforms other than identity** (`day(ts)`, `bucket[N]`, …). The reference DDL uses identity
  partitions only. A table partitioned another way falls back to `GRS_REFINED_TIMESTAMP` or `GRS_UNIQUE_ID`,
  which is still correct but doesn't guarantee file skipping.
- **Load-side behaviour.** Out of scope by design.
