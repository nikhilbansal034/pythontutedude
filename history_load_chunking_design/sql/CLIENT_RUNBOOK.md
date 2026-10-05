# Chunk planner: running it in a client environment

How to run the planner against real Iceberg tables. For the synthetic test run, see `TEST_PLAN.md`.

## In short

**Run two scripts: `01_metadata_ddl.sql` once, then `04_chunk_planner.sql`.** In each, change only the
database and schema settings at the top. Leave the chunk-size settings at their defaults.

| Script | Run in client? | Why |
|---|---|---|
| `01_metadata_ddl.sql` | **Yes, once** | Creates the two plan tables (`HIST_PLAN_TABLE`, `HIST_PLAN_CHUNK`). `IF NOT EXISTS`, safe to re-run |
| `04_chunk_planner.sql` | **Yes** | The planner. Reads the source tables and writes only to the two plan tables |
| `03_smoke_test.sql` | Optional pre-flight | Checks that the scripting features the planner needs work under your role. Creates temporary tables only |
| `05_validate.sql` | Optional, partly | A3, A4 and Part B are generic checks. A1, A2 and A5 compare against the synthetic test data, so skip them |
| `02_test_setup.sql` | **No** | Builds the synthetic test tables |
| `06_reset_test_metadata.sql` | **Only to start over** | Deletes every plan row for one source schema, history included |

The planner never changes source tables, never generates load SQL and never loads data. Its only side
effects are:
- rows in the two plan tables;
- session temporary tables (`HPLAN_TMP_*`), which disappear when the session ends;
- `ALTER SESSION SET TIMEZONE = 'UTC'` for the session that runs it.

## 1. Before you start

| Item | What is needed |
|---|---|
| **Metadata location** | One schema for the plan tables, **separate from the source schemas**, e.g. `<DB>.CHUNK_PLAN_META`. One location serves every source schema you plan. |
| **Role, metadata side** | `USAGE` on the database; `CREATE SCHEMA` on it, or `CREATE TABLE` on an existing schema; then `SELECT`, `INSERT`, `UPDATE`, `DELETE` on the two plan tables. Temporary tables need no extra privilege. |
| **Role, source side** | `USAGE` on the source database and schema, and `SELECT` on the Iceberg tables. **Tables the role cannot see are silently out of scope**: `SHOW ICEBERG TABLES` and `INFORMATION_SCHEMA` list only visible objects. |
| **Warehouse** | Any size runs it. Medium is the assumption behind the chunk-size defaults. |
| **Cost per table** | Every query reads only 1–3 columns: <br>• one `COUNT(*)` <br>• one file listing (`ICEBERG_TABLE_FILES`) <br>• one `GROUP BY` on the chunk column (`GRS_PROCESS_DATE`, `GRS_PROCESS_YEAR/MONTH/DAY` or `GRS_REFINED_TIMESTAMP`) <br>• for each day larger than one chunk, one extra `GROUP BY` filtered to that day. |
| **Approvals** | Check whether the client needs sign-off to run `COUNT(*)` and `GROUP BY` queries on these tables, and to create a schema. |

## 2. Step 1: create the plan tables (`01_metadata_ddl.sql`, once)

Edit one line, then run the whole file:

```sql
SET meta_location = '<DB>.<META_SCHEMA>';      -- e.g. 'CLIENT_DB.CHUNK_PLAN_META'
```

**Expect:** the final `SHOW TABLES` lists `HIST_PLAN_CHUNK` and `HIST_PLAN_TABLE`. The database must
already exist; the schema is created if missing.

## 3. Step 2 (optional): pre-flight (`03_smoke_test.sql`)

Edit the four settings, then run:

```sql
metadata_database VARCHAR DEFAULT '<DB>';             -- the metadata location from step 1
metadata_schema   VARCHAR DEFAULT '<META_SCHEMA>';
test_database     VARCHAR DEFAULT '<SOURCE_DB>';      -- a client source schema
test_schema_src   VARCHAR DEFAULT '<SOURCE_SCHEMA>';
```

**Expect:**
- Checks 1–7, 11 and 12 PASS.
- Check 8 shows how many Iceberg tables your role sees in that schema. Ignore its "expect 9", which is for the test data.
- Checks 9 and 10 may say INFO:
  - **9 = INFO:** the partition spec is not readable, so the axis comes from column names only (`PARTITION_VERIFIED = FALSE`).
  - **10 = INFO:** file sizes are not readable, so chunks are sized by row count only.

  Neither stops the planner.

## 4. Step 3: plan one or two tables first (`04_chunk_planner.sql`)

Start small, with one CURRENT and one HISTORY table you know. Edit only these settings:

```sql
p_database        VARCHAR DEFAULT '<SOURCE_DB>';
p_schema          VARCHAR DEFAULT '<SOURCE_SCHEMA>';
p_tables          VARCHAR DEFAULT '<TABLE_A>, <TABLE_B>';   -- '' = every table in the schema
p_force_replan    BOOLEAN DEFAULT FALSE;

metadata_database VARCHAR DEFAULT '<DB>';                    -- the metadata location from step 1
metadata_schema   VARCHAR DEFAULT '<META_SCHEMA>';
```

**Leave the chunk-size settings at their defaults:**

```sql
target_chunk_bytes NUMBER(38,0) DEFAULT 10737418240;  -- 10 GB per chunk
max_chunk_rows     NUMBER(38,0) DEFAULT 250000000;    -- 250M rows per chunk
split_grain        VARCHAR      DEFAULT 'MINUTE';
```

> `max_chunk_rows = 1000` is **only** for the synthetic test data. Check the `*** SUMMARY ***` row: it must
> say `Target: 10 GB / 250000000 rows max per chunk`.

**Expect:** one row per table, then a `*** SUMMARY ***` row. Each table is PLANNED, FAILED (with the reason)
or SKIPPED (non-Iceberg, or already planned). A wrong table name stops the run with `VALIDATION_FAILED` and
writes nothing.

## 5. Step 4: plan the whole schema

Set `p_tables = ''` and run `04` again. Tables planned in step 3 are skipped as *already planned*. Repeat
for each source schema (CURRENT and HISTORY), keeping the same metadata location.

## 6. Step 5: read the plan

Run in the metadata schema (`USE SCHEMA <DB>.<META_SCHEMA>;`).

```sql
-- table level: one active row per table
SELECT DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, LAYER, PLAN_STATUS, CHUNK_AXIS, AXIS_COLUMNS,
       PARTITION_VERIFIED, CHUNK_METHOD, CHUNK_COUNT, TOTAL_ROWS,
       ROUND(TOTAL_BYTES / POWER(1024, 3), 2) AS TOTAL_GB, STATUS_REASON
  FROM HIST_PLAN_TABLE
 WHERE IS_ACTIVE AND UPPER(SCHEMA_NAME) = UPPER('<SOURCE_SCHEMA>')
 ORDER BY PLAN_STATUS, TABLE_NAME;

-- chunk sizes per table: no chunk should be far above 10 GB / 250M rows
SELECT t.TABLE_NAME, t.CHUNK_METHOD, COUNT(*) AS CHUNKS,
       MIN(c.ESTIMATED_ROWS) AS MIN_ROWS, ROUND(AVG(c.ESTIMATED_ROWS)) AS AVG_ROWS, MAX(c.ESTIMATED_ROWS) AS MAX_ROWS,
       ROUND(MAX(c.ESTIMATED_BYTES) / POWER(1024, 3), 2) AS MAX_GB
  FROM HIST_PLAN_TABLE t JOIN HIST_PLAN_CHUNK c ON c.PLAN_ID = t.PLAN_ID
 WHERE t.IS_ACTIVE AND t.PLAN_STATUS = 'PLANNED' AND UPPER(t.SCHEMA_NAME) = UPPER('<SOURCE_SCHEMA>')
 GROUP BY 1, 2 ORDER BY CHUNKS DESC;

-- every chunk of one table, in load order
SELECT c.CHUNK_SEQ, c.CHUNK_TYPE, c.DAY_START, c.DAY_END, c.SUB_COLUMN, c.SUB_START_TS, c.SUB_END_TS,
       c.HASH_BUCKET, c.HASH_MODULUS, c.ESTIMATED_ROWS, c.ESTIMATED_BYTES
  FROM HIST_PLAN_TABLE t JOIN HIST_PLAN_CHUNK c ON c.PLAN_ID = t.PLAN_ID
 WHERE t.IS_ACTIVE AND t.TABLE_NAME = '<TABLE_A>' AND UPPER(t.SCHEMA_NAME) = UPPER('<SOURCE_SCHEMA>')
 ORDER BY c.CHUNK_SEQ;
```

## 7. Step 6 (optional): verify the plan (`05_validate.sql`)

1. At the top, set the three `SET` lines:
   - `meta_location` to the metadata location;
   - `src_database` and `src_schema` to the source schema.

   Run the `SET` and `USE` lines.
2. Run **A3** (chunk rows add up to the table) and **A4** (day chunks tile with no gaps or overlaps).
   - Both cover every active plan in the metadata location.
   - A4 returns one row per range chunk. No rows means there were no range chunks to check.
3. **Skip A1, A2 and A5.** They compare against the synthetic test tables.
4. **Part B** (exactly-once coverage against the source rows) reads each table's chunk column once per chunk.
   - Set its four defaults to the same locations.
   - **Set `p_tables` to one or two tables.** Prefer ones with a split day, i.e. `CHUNK_METHOD = DAY_RANGES_WITH_SPLITS`.
   - Do not run it on a whole large schema.

**Expect:** A3 PASS on every row; every A4 row PASS; Part B PASS with 0 rows in no chunk and 0 rows in two
or more.

## 8. Re-running, re-planning, cleaning up

| Need | How |
|---|---|
| Re-run safely | Run `04` again: tables with an active plan are skipped. |
| Re-plan after data changed | `p_force_replan = TRUE` with a `p_tables` list. The old plan becomes `SUPERSEDED`; nothing is overwritten. |
| Start a schema over | `06_reset_test_metadata.sql` with its `SET` lines pointed at the metadata location and the source schema. It deletes **all** plan rows for that schema, history included. |
| Remove everything | `DROP SCHEMA <DB>.<META_SCHEMA>;` (only if the schema holds nothing else). |

## 9. What to check and screenshot

| Check | Where | Good result |
|---|---|---|
| Scope | `*** SUMMARY ***` row | `Objects in scope` equals the objects you expect in the schema. Fewer means the role can't see some tables. |
| Sizing in force | `*** SUMMARY ***` row | `10 GB / 250000000 rows max per chunk` |
| Partition read from Iceberg | `PARTITION_VERIFIED` | `TRUE` on partitioned tables. `FALSE` means the axis came from column names: confirm the table's `PARTITION BY`. |
| File sizes read | `STATUS_REASON` | No "Iceberg file sizes unavailable" note. If there is one, chunks were sized by rows only. |
| Failures | `PLAN_STATUS = 'FAILED'` | Each has a clear `STATUS_REASON`. |
| Chunk sizes | Step 5, second query | `MAX_GB` around 10 or below; `MAX_ROWS` at most 250M. A hash chunk can be slightly above, because hash buckets are estimates. |
| Runtime | Workspace query time | Note the time per table, for the full-schema run. |

## 10. Troubleshooting

| Message | Cause and fix |
|---|---|
| `Metadata location … is not usable` | `01` was not run for that location, or `metadata_database` / `metadata_schema` in `04` don't match it. |
| `Schema … not found in database …, or not visible to role` | Wrong name, or the role lacks `USAGE` on the database or schema. |
| `VALIDATION_FAILED` for a table name | The table doesn't exist or the role can't see it. Nothing was written; fix the list and re-run. |
| A table is missing from the results | The role has no privilege on it, so `SHOW ICEBERG TABLES` doesn't list it. |
| `Not an Iceberg table` (SKIPPED) | Expected for standard tables and views. They are recorded so you can see what was left out. |
| `No usable chunk column` (FAILED) | The table needs more than one chunk but has no `GRS_PROCESS_*` partition column, `GRS_REFINED_TIMESTAMP` or `GRS_UNIQUE_ID`. A loader would need a column chosen by hand. |
