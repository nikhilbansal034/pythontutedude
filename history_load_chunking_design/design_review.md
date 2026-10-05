# Architecture review — Iceberg historical load chunk planner

**Revision 5 — 2026-10-05.** This revision is built on the **real table structure**: two reference DDLs for
one source table, in its CURRENT and HISTORY layers (`reference_ddl.sql`, screenshots in `sources/`).
Scope is unchanged from revision 4:
- **Planner only.** It analyses Iceberg tables and writes metadata. It never builds load SQL and never
  touches target tables.
- **How it runs:** an anonymous Snowflake Scripting block, run by hand from a Snowflake Workspace.
- **Inputs:** one database and one schema (both required), plus an optional list of one or more tables.

§2 lists what changed.

Reviewed: `solution_design.md` (this folder). Cross-checked against current Snowflake and Qlik Replicate
docs.

---

## 0. Verdict

The real DDL makes the planner **simpler and safer** than the generic design. Every table carries the same
`GRS_*` audit and partition columns, so the planner never has to guess.

1. **Chunk on the partition column, in whole days.** CURRENT tables are partitioned on
   `GRS_PROCESS_DATE` and HISTORY tables on `GRS_PROCESS_YEAR/MONTH/DAY`. Chunks made of whole partition
   days are **guaranteed** to skip all other files, so there is nothing to test or score.
2. **Split a day only when it is too big for one chunk.** First try `GRS_REFINED_TIMESTAMP` ranges within
   that day. If that can't split it, use hash buckets on `GRS_UNIQUE_ID`, which always produces even
   pieces.
3. **Detect the layer from the DDL, not from SCD date columns.** `EFFCTV_TS` / `EXPRTN_TS` appear in
   **both** tables. They are the source system's own validity dates, so the SCD rule from revision 4
   (look for `row_effective_date` / `row_expiration_date`) would get every table wrong. The partition
   columns and hash columns identify the layer reliably.
4. **CURRENT tables change in place, so a plan is only valid at one point in time.** The planner records
   that point (`PROFILED_AT`), and the loader must read `AT` it. Time Travel retention has to cover the gap
   between planning and loading.
5. **Store timestamp boundaries as `TIMESTAMP_TZ`, not `TIMESTAMP_NTZ`.** Every timestamp column here is
   `TIMESTAMP_LTZ`. Comparing an LTZ column with an NTZ value applies the reader's session time zone, which
   can shift chunk edges by hours.

The earlier findings on exact boundaries, immutable plans, input handling and Workspace execution still
hold (§5, §7).

---

## 1. Scope and inputs (unchanged from revision 4)

| In scope | Out of scope |
|---|---|
| Inputs: database + schema (required); one or many table names (optional). With no names given, every Iceberg table in the schema | Building load SQL |
| Read DDL, identify layer and standard columns, profile, decide chunks | Loading data; target tables |
| Write metadata: number of chunks, size, chunk column, range per chunk | Load reconciliation, retries |
| Validate inputs; isolate failures to one table | IDMC (deferred), Tasks, stored procedures |
| Run as an anonymous block from a Snowflake Workspace | |

---

## 2. What changed from revision 4

| Revision 4 | Revision 5 |
|---|---|
| Generic candidate list (partition column, landing timestamp, `row_effective_date`, surrogate key, other dates), scored per table | **One fixed approach** for the standard structure: partition days, then an in-day split. Business columns are never candidates (§4) |
| SCD2 detected by `row_effective_date` / `row_expiration_date` | **Layer detected** by partition columns + hash columns + database name (§3.3) |
| `EXPLAIN` pruning probe per candidate | **Not needed.** Whole-day chunks skip other files by definition. The probe stays only as a test for the loader's HISTORY-table filter (§9) |
| Window-function cut over hour buckets | **Simple loop over days.** The list has one row per day, so it's small (§8) |
| Timestamp boundaries `TIMESTAMP_NTZ` | **`TIMESTAMP_TZ`** (§6, F7) |
| `PROFILED_AT` recorded as a convenience | **A requirement for CURRENT tables** (F8) |

---

## 3. What the reference DDLs tell us

### 3.1 Column roles (both layers)

| Group | Columns | Use for chunking |
|---|---|---|
| **Partition (CURRENT)** | `GRS_PROCESS_DATE DATE` | **Primary**: whole-day chunks |
| **Partition (HISTORY)** | `GRS_PROCESS_YEAR`, `GRS_PROCESS_MONTH`, `GRS_PROCESS_DAY INT` | **Primary**: together one logical day |
| **GRS watermarks** | `GRS_REFINED_TIMESTAMP`, `GRS_RAW_TIMESTAMP` (`TIMESTAMP_LTZ(6)`) | **Secondary**: splits an oversized day. `GRS_REFINED_TIMESTAMP` is preferred (the refined-layer watermark) |
| **GRS record id** | `GRS_UNIQUE_ID STRING` (UUID per record) | **Fallback**: hash buckets inside a day. Always even, always splittable |
| GRS audit, other | `GRS_LANDING_DATE` (STRING), `GRS_LANDING_SOURCE_PATH`, `GRS_RAW_SOURCE_PATH`, `GRS_EXECUTION_UUID`, `ROW_HASH` / `NEW_ROW_HASH` / `LAST_ROW_HASH` | Never. They are strings, one value per run, or hashes |
| **CDC headers** (Qlik Replicate) | `OP`, `AR_H_TIMESTAMP` (STRING), `CHANGE_SEQ_NUM` (STRING) | Never. They are strings. `CHANGE_SEQ_NUM` is monotonic, but as text it would need parsing |
| **Business** (table-specific) | Primary key `APLD_COVRG_INSRBL_OBJ_ID`, other `*_ID`, `EFFCTV_TS`, `EXPRTN_TS`, `CREAT_TS`, `LAST_UPDT_TS`, … | Never. Names vary by table, and several change in place (`EXPRTN_TS`, `LAST_UPDT_TS`) |

Because only the standard `GRS_*` columns are used, **the planner never has to understand a table's
business columns.** That is what lets one script handle every table.

### 3.2 The two layers

| | CURRENT (`…_CURRENT_RAW_DB`), you call it SCD1 | HISTORY (`…_HISTORY_RAW_DB`), you call it SCD2 |
|---|---|---|
| Behaviour | Mirrors the source as it is now. Rows are **updated or deleted in place** | **Append-only.** Every change is a new row; nothing is overwritten (W3 glossary, "history bucket") |
| Partitioning | `GRS_PROCESS_DATE` | `GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY` |
| Hash columns | `ROW_HASH` | `NEW_ROW_HASH`, `LAST_ROW_HASH` |
| Can a row move between partitions? | **Yes.** An update rewrites the row with a new `GRS_PROCESS_DATE` | No |
| Iceberg file row counts | Can overstate rows: v3 tables updated in place may carry deletion vectors | Exact, since nothing is deleted |
| Catalog | Snowflake-managed (`CATALOG = 'SNOWFLAKE'`), Iceberg v3 | Same |

**A point to confirm (Q1).** By its DDL, the HISTORY table is a **change log**. It has the CDC operation
(`OP`), the change sequence, and before/after hashes (`LAST_ROW_HASH` / `NEW_ROW_HASH`). It is not an SCD2
table with dates that Zone1 maintains. The validity dates (`EFFCTV_TS` / `EXPRTN_TS`) come from the source
and appear in the CURRENT table too. This doesn't change chunking. It does matter to anyone who assumes
"SCD2" means one open version per key.

### 3.3 Detecting the layer from the DDL

| Signal | CURRENT | HISTORY |
|---|---|---|
| Partition columns present | `GRS_PROCESS_DATE` | `GRS_PROCESS_YEAR/MONTH/DAY` |
| Hash columns present | `ROW_HASH` | `NEW_ROW_HASH` + `LAST_ROW_HASH` |
| Database name contains | `CURRENT` | `HISTORY` |

- **All three signals agree** → the layer is decided.
- **They disagree, or a required column is missing** (the partition column, `GRS_REFINED_TIMESTAMP`, or
  `GRS_UNIQUE_ID`) → the table is `PLAN_FAILED` with a message naming what's missing. CONFIG can override
  the layer for a known exception.
- The block also confirms the table is **actually partitioned** on those columns, using the
  `partition_specs` from `SHOW ICEBERG TABLES` or `GET_DDL`. If it isn't, chunking still works, but the
  plan records that skipping files is not guaranteed.

---

## 4. Chunking approach for this structure

### 4.1 Procedure per table

```
0. Layer + structure check (§3.3)                     → PLAN_FAILED if not standard
1. Total bytes ≤ SMALL_TABLE_BYTES                    → 1 chunk (ALL)
2. Rows per partition day (cheap: one small column)  → day list, plus a count of NULL partitions
3. Walk the days in order, accumulating rows:
     day_rows > TARGET_ROWS          → close the open chunk; split this day (step 4)
     acc + day_rows > TARGET_ROWS    → close the open chunk; start a new one with this day
     else                            → add the day to the open chunk
4. Split one oversized day:
     a. rows per minute of GRS_REFINED_TIMESTAMP inside that day (reads only that day)
        no NULLs and largest minute ≤ TARGET_ROWS → DAY_SUBRANGE chunks on GRS_REFINED_TIMESTAMP
     b. otherwise                                → DAY_HASH: n = CEIL(day_rows / TARGET_ROWS) buckets
                                                    on HASH(GRS_UNIQUE_ID) within the day
5. NULL partition values (if any)                     → one NULL_PARTITION chunk
6. Check Σ chunk rows = table rows                    → else PLAN_FAILED
```

`TARGET_ROWS` = `TARGET_BYTES_PER_CHUNK / AVG_ROW_BYTES`, capped at `MAX_ROWS_PER_CHUNK`. The average row
size comes from the table's Iceberg file sizes divided by its rows.

### 4.2 Why this order

| Choice | Reason |
|---|---|
| Partition days first | Skipping other files is **guaranteed**, because a whole-day chunk maps exactly to that day's partition. It is also what Zone1 already uses to organise the data |
| `GRS_REFINED_TIMESTAMP` to split a day | It's on every table, never NULL by design (check that), and records written into a day partition likely arrive in roughly refined-timestamp order, so the split pieces should still skip files within the day |
| `GRS_UNIQUE_ID` hash as the last resort | It always splits, into exactly even pieces, whatever the data looks like. That covers a bulk backfill that stamped one refined timestamp on millions of rows. The cost: each hash piece reads the whole day. That's acceptable because it only happens for oversized days |
| No business columns | Their names vary by table and some change in place. The `GRS_*` columns are standard and suffice |

### 4.3 What to expect on real data

The Teradata backfill landed in the HISTORY layer within a short window. So, very likely, **a handful of
`GRS_PROCESS_*` days hold most of the history**, and step 4 will do much of the work for history tables.
That is exactly why the in-day split exists. The reconnaissance in §9 will show it before the script is
trusted.

---

## 5. Inputs, validation and running from a Snowflake Workspace

### 5.1 Inputs, declared at the top of the script

```sql
DECLARE
    -- ================= INPUTS: edit before each run =================
    p_database      VARCHAR DEFAULT 'GRS_DIAI_HISTORY_RAW_DB';
    p_schema        VARCHAR DEFAULT 'UNDERWRITING_LMPW';
    p_tables        VARCHAR DEFAULT '';      -- '' = all Iceberg tables in the schema
                                             -- or e.g. 'PRDSCT1D_SCOUT_APLD_COVRG_INSRBL_OBJ, PRDSCT1D_SCOUT_X'
    p_force_replan  BOOLEAN DEFAULT FALSE;
    -- =================================================================
    ...
BEGIN
    ...
END;
```

Inputs are not passed as session variables (`SET`), because a session variable's string value is capped
at **256 bytes**. A list of a few table names with these long names, about 40 characters each, would
exceed it.

### 5.2 Validation: checked before anything is written; all problems reported together

1. `p_database` / `p_schema` blank → fail. Database missing, or schema missing in it → fail, naming which.
2. **Table list given**:
   - Split on commas, trim, drop empty entries, remove duplicates.
   - Match each name against `INFORMATION_SCHEMA.TABLES`: an exact match first, then a case-insensitive
     match only if exactly one table matches. Never `LIKE`: `_` is a wildcard, and these names are full of
     underscores.
   - Each name ends up resolved, **not found**, **ambiguous**, or **not an Iceberg table**
     (`IS_ICEBERG = 'NO'`).
   - Any invalid name → the run fails with every invalid name listed. Nothing is written (Q7).
3. **No table list**: scope is every table with `IS_ICEBERG = 'YES'`. Non-Iceberg tables are reported as
   `SKIPPED_NOT_ICEBERG` (Q8).
4. A table with an active plan is reported `SKIPPED_ALREADY_PLANNED`, unless `p_force_replan` is set. Even
   then, the F2 guard applies.

### 5.3 Running it in a Workspace

- **The block runs as-is.** Snowsight runs `DECLARE … BEGIN … END;` directly, so no `EXECUTE IMMEDIATE`
  and no `$$` are needed. Confirm with a trivial block first (§9).
- **Context**: a role with `USAGE` on the source database and schema, `SELECT` on the tables, and write
  access to the metadata tables. Select a warehouse before running.
- **Output**: `RETURN TABLE(…)` gives one summary row per table: layer, outcome, method, chunk count,
  rows, any error. The same information is saved in `HIST_PLAN_RUN` / `HIST_PLAN_TABLE`.
- **Errors**:
  - Validation errors `RAISE` and nothing is written.
  - A problem with one table is recorded against it, and the run continues.
- **Interruptions**: each table commits separately, so a cancelled run keeps the finished tables.
  Re-running continues with the rest, and the interrupted run's log row is marked `ABORTED`.

---

## 6. Metadata tables

**`HIST_PLAN_TABLE`**: one row per table per plan version.

| Column | Purpose |
|---|---|
| `PLAN_ID`, `RUN_ID` | Plan identity; the run that produced it |
| `DATABASE_NAME`, `SCHEMA_NAME`, `TABLE_NAME` | The Iceberg table |
| `LAYER` | `CURRENT` / `HISTORY` (§3.3) |
| `PARTITION_COLUMNS` | `GRS_PROCESS_DATE`, or `GRS_PROCESS_YEAR,GRS_PROCESS_MONTH,GRS_PROCESS_DAY` |
| `PARTITION_VERIFIED` | Whether the Iceberg partition spec confirms those columns |
| `CHUNK_METHOD` | `SINGLE` / `PARTITION_DAYS` (all chunks whole days) / `PARTITION_DAYS_WITH_SPLITS` (some days split) |
| `PROFILED_AT` (`TIMESTAMP_TZ`) | The point in time the plan describes. The loader reads `AT` this (F8) |
| `TOTAL_ROWS`, `TOTAL_BYTES`, `COLUMN_COUNT`, `AVG_ROW_BYTES` | Profile |
| `DAY_COUNT`, `SPLIT_DAY_COUNT`, `CHUNK_COUNT`, `TARGET_ROWS_PER_CHUNK` | Result, and the target used |
| `IS_ACTIVE`, `PLAN_STATUS` | One active plan per table. Status is `PLANNED` / `PLAN_FAILED` / `SUPERSEDED` |
| `ERROR_MESSAGE`, `PLANNED_AT` | Audit |

**`HIST_PLAN_CHUNK`**: one row per chunk. Key: `(PLAN_ID, CHUNK_SEQ)`.

| Column | Purpose |
|---|---|
| `PLAN_ID`, `CHUNK_SEQ` | Identity and order |
| `CHUNK_TYPE` | `ALL` / `DAY_RANGE` / `DAY_SUBRANGE` / `DAY_HASH` / `NULL_PARTITION` |
| `DAY_START`, `DAY_END` (`DATE`) | Partition days, half-open `[start, end)`. NULL = unbounded (first and last `DAY_RANGE` only). For a split day, `DAY_END = DAY_START + 1` |
| `SUB_COLUMN` | `GRS_REFINED_TIMESTAMP` for `DAY_SUBRANGE`; `GRS_UNIQUE_ID` for `DAY_HASH` |
| `SUB_START_TS`, `SUB_END_TS` (`TIMESTAMP_TZ`) | `DAY_SUBRANGE` only. Half-open; NULL = open at the day edge |
| `HASH_BUCKET`, `HASH_MODULUS` | `DAY_HASH` only. A row is in the chunk when `MOD(ABS(HASH(GRS_UNIQUE_ID)), HASH_MODULUS) = HASH_BUCKET` |
| `ESTIMATED_ROWS`, `ESTIMATED_BYTES` | Chunk size. Rows are exact at `PROFILED_AT` for day and sub-range chunks, and an even share for hash chunks. Bytes = rows × `AVG_ROW_BYTES` |
| `STATUS` | The planner writes `PENDING`; the loader owns it after that (Q6) |

For HISTORY tables, `DAY_START` / `DAY_END` are logical dates made from `GRS_PROCESS_YEAR/MONTH/DAY`. The
loader turns them back into year/month/day conditions (§9, loader note).

**`HIST_PLAN_RUN`**: one row per execution. Holds:
- the inputs as given, and the resolved table list;
- the user and role, start and end time;
- counts of tables planned, skipped and failed;
- the run status.

**`HIST_PLAN_CONFIG`**: `SCOPE` (`*` or `db.schema.table`), `TARGET_BYTES_PER_CHUNK`, `MAX_ROWS_PER_CHUNK`,
`SMALL_TABLE_BYTES`, `SUBSPLIT_GRAIN` (default `MINUTE`), `MAX_HASH_BUCKETS_PER_DAY`. Per-table override:
`FORCE_LAYER`.

---

## 7. Findings on the original design

| # | Severity | Finding | Resolution |
|---|---|---|---|
| F1 | Critical | Boundaries from observed min/max, read with `BETWEEN`, leave gaps and overlaps; NULLs are dropped | Half-open ranges, open-ended first and last day ranges, a `NULL_PARTITION` chunk, and a rows-sum check (§4.1 step 6) |
| F2 | Critical | `MERGE` keyed on `CHUNK_SEQ` can rewrite boundaries under chunks already used, and leave orphan chunks behind | A new `PLAN_ID` per plan; chunk rows are insert-only; refuse to supersede a plan whose chunks aren't all `PENDING` unless forced; one transaction per table; drop the row-growth staleness rule |
| F3 | Important | Single-date-column heuristic and month→day recursion | Replaced by §4: partition days, then an in-day split |
| F4 | Important | `SHOW … LIKE` validation (case-insensitive, `_` wildcard) | `INFORMATION_SCHEMA.TABLES` exact matching (§5.2) |
| F5 | Important | CONFIG sized in rows only; `MIN_ROWS_TO_CHUNK = 1M` is very low; the "÷ columns" proxy | Size by bytes with a row cap; bytes threshold for small tables; column count kept for information only |
| F6 | Minor | "No open questions left"; Task and two invocation paths | Questions in §10; one path (Workspace) |
| **F7** | **Critical** | All timestamp columns are `TIMESTAMP_LTZ`. NTZ or `VARIANT` boundaries are read in whatever session time zone the loader uses, which can shift edges by hours | Store `SUB_*_TS` as `TIMESTAMP_TZ`; set `TIMEZONE = 'UTC'` at the top of the block, because `DATE_TRUNC` on LTZ depends on it |
| **F8** | **Critical** | CURRENT tables change in place, and an update moves a row to a new `GRS_PROCESS_DATE`. If the loader reads the live table, rows changed between plan and load are missed or loaded twice | Record `PROFILED_AT`; the loader must read `AT(TIMESTAMP => PROFILED_AT)`. Snowflake-managed Iceberg supports Time Travel, but retention (`DATA_RETENTION_TIME_IN_DAYS`, often 1 day by default) must cover the gap between plan and load (Q3) |

---

## 8. SQL sketches (illustrative, not executed)

### 8.1 Rows per partition day

```sql
-- CURRENT layer
SELECT GRS_PROCESS_DATE AS process_day, COUNT(*) AS day_rows
FROM   IDENTIFIER(:fq_table)
GROUP  BY GRS_PROCESS_DATE;

-- HISTORY layer
SELECT DATE_FROM_PARTS(GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY) AS process_day,
       COUNT(*) AS day_rows
FROM   IDENTIFIER(:fq_table)
GROUP  BY GRS_PROCESS_YEAR, GRS_PROCESS_MONTH, GRS_PROCESS_DAY;
```

This reads only the partition column or columns. A row with `process_day IS NULL` means there are NULL
partitions, which go to the `NULL_PARTITION` chunk.

### 8.2 Day walk: a loop in the block

The day list is small (one row per day), so a cursor loop over it is clearer than set-based tricks:

```sql
FOR d IN day_cursor DO                       -- ordered by process_day, NULL day excluded
    IF (d.day_rows > target_rows) THEN
        -- close the open DAY_RANGE (if any) at DAY_END = d.process_day
        -- split this day (8.3 / 8.4), each piece DAY_START = d.process_day, DAY_END = +1 day
    ELSEIF (acc_rows + d.day_rows > target_rows) THEN
        -- close the open DAY_RANGE at DAY_END = d.process_day; open a new one at d.process_day
    ELSE
        -- add d.day_rows to the open DAY_RANGE
    END IF;
END FOR;
```

The first `DAY_RANGE` gets `DAY_START = NULL` and the last gets `DAY_END = NULL`. Days with no data
between two chunks are absorbed automatically, because each chunk ends where the next begins.

### 8.3 Splitting an oversized day by `GRS_REFINED_TIMESTAMP`

```sql
SELECT DATE_TRUNC('MINUTE', GRS_REFINED_TIMESTAMP) AS minute_start,
       COUNT(*)                                     AS minute_rows,
       COUNT_IF(GRS_REFINED_TIMESTAMP IS NULL)      AS null_rows
FROM   IDENTIFIER(:fq_table)
WHERE  GRS_PROCESS_DATE = :split_day                -- HISTORY: year/month/day = parts of :split_day
GROUP  BY 1;
```

Walk the minutes the same way as the days. If there are any NULLs, or the largest minute is still bigger
than `TARGET_ROWS`, use 8.4 instead.

### 8.4 Hash fallback inside a day

No query is needed. `HASH_MODULUS = CEIL(day_rows / target_rows)`, giving chunks for buckets
`0 … HASH_MODULUS-1`, each with an estimated `day_rows / HASH_MODULUS` rows. Check once per table that
`GRS_UNIQUE_ID` has no NULLs.

⚠️ `HASH()` is deterministic, but I found no Snowflake documentation promising its output stays the same
across releases. All buckets of one day should therefore be loaded within the same short window. If that
can't be guaranteed, use a bucket function defined by the data itself: `GRS_UNIQUE_ID` is a UUID, so its
leading hex characters are already uniformly spread (e.g. `MOD(TO_NUMBER(SUBSTR(GRS_UNIQUE_ID, 1, 4),
'XXXX'), HASH_MODULUS)`). This depends on confirming the UUID format.

### 8.5 Size inputs

```sql
SELECT SUM(FILE_SIZE) AS total_bytes, SUM(ROW_COUNT) AS file_rows
FROM   TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(TABLE_NAME => :fq_table));
-- AVG_ROW_BYTES = total_bytes / (SUM of day_rows from 8.1); exact rows come from 8.1, not file_rows
```

---

## 9. Next steps, in order

1. **Workspace smoke test** (5 minutes): a trivial `DECLARE … BEGIN … RETURN TABLE(…) END;` block.
2. **Reconnaissance (read-only)** on 3–5 table pairs (CURRENT + HISTORY):
   - **8.1 on each table.** How many days are there? How concentrated are the history days?
   - **8.3 on the biggest history day.** Does `GRS_REFINED_TIMESTAMP` spread within a day, or is it one
     value?
   - **`SHOW ICEBERG TABLES`.** Do `partition_specs` match the DDL?
   - **NULL checks.** Are there any NULLs in the partition columns, `GRS_REFINED_TIMESTAMP` or
     `GRS_UNIQUE_ID`?
3. **Loader note** (for the load team, not the planner): for HISTORY tables, run `EXPLAIN` on the planned
   filter form (year/month/day conditions for a day range) to confirm it skips other partitions.
4. Then write the DDL for the four metadata tables, and the block.

---

## 10. Open questions

| # | Question | Why it matters |
|---|---|---|
| Q1 | Is HISTORY an **append-only change log** (one row per CDC change), as its DDL suggests, rather than an SCD2 table with Zone1-maintained dates? | Wording and downstream expectations; chunking is unaffected |
| Q2 | Which database and schema should hold the four metadata tables? | Where the block writes, and the permissions it needs |
| Q3 | How long between planning and loading? What is `DATA_RETENTION_TIME_IN_DAYS` on the CURRENT/HISTORY databases? | F8: the loader can only read `AT(PROFILED_AT)` within retention |
| Q4 | Will the historical load read **CURRENT tables, HISTORY tables, or both**? | Both work. It decides whether F8 is in play at all |
| Q5 | What target chunk size should be the starting default? | CONFIG. Placeholder until the load team decides |
| Q6 | Keep `STATUS` on the chunk table (the planner writes `PENDING`, the loader owns it after that), or should the loader keep its own status table? | Ownership |
| Q7 | One bad name in the table list: fail the whole run (recommended) or plan the valid ones? | §5.2 |
| Q8 | Skip and report non-Iceberg tables when no list is given (recommended)? | §5.2 |
| Q9 | Is `GRS_PROCESS_DATE` (and year/month/day) derived from `GRS_REFINED_TIMESTAMP`, from `GRS_RAW_TIMESTAMP`, or set independently? | Confirms that splitting a day on `GRS_REFINED_TIMESTAMP` stays inside that day |

---

## 11. What was verified, and how

| Claim | Basis |
|---|---|
| Column list, types, partitioning, catalog, Iceberg version | The two DDL screenshots (`sources/`), transcribed in `reference_ddl.sql` |
| `OP` / `AR_H_TIMESTAMP` / `CHANGE_SEQ_NUM` are Qlik Replicate CDC headers; the change sequence is monotonic `YYYYMMDDHHmmSShh…`; `AR_H_TIMESTAMP` is Replicate-server local time | Qlik Replicate "Headers" docs (via search extract). That these columns came from Qlik is an **inference** from the names |
| History bucket is append-only; current mirrors the source | `../w3-scd-effective-date-split/glossary.md` (from a meeting transcript) |
| Snowflake-managed Iceberg tables with `PARTITION BY` write partition metadata used for file skipping; identity transform = the raw column value | Snowflake "Partitioning for Apache Iceberg tables" docs (via search extract) |
| Comparing LTZ with NTZ interprets the NTZ value in the session time zone | Snowflake date/time docs (via search extract) |
| Snowsight runs blocks without `EXECUTE IMMEDIATE`; session variables are capped at 256 bytes | Snowflake docs (via search extract) |
| Snowflake-managed Iceberg supports Time Travel | Snowflake Iceberg docs (via search extract). The retention value on these databases is **unknown** (Q3) |
| Iceberg file row counts don't subtract deletes or deletion vectors | Snowflake Iceberg docs and release notes (via search extract) |
| All SQL in §8 | Written for this review, **not executed** |

`docs.snowflake.com` was not directly fetchable from this environment. Snowflake and Qlik claims rely on
search-result extracts of the official pages.
