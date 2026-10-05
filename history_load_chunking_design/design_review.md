# Architecture review — Iceberg historical load chunk planner

**Revision 8 — 2026-10-05.** This revision is built on the **real table structure**: two reference DDLs for
one source table, in its CURRENT and HISTORY layers (`reference_ddl.sql`, screenshots in `sources/`).
Revisions 6–7 record the latest decisions (§1a), explain how the technique is chosen for each table (§4), and
recommend the chunk size (§4.3). The metadata is now two tables (§6). Revision 8 sizes chunks from the
warehouse the script runs on (§4.3).
Scope:
- **Planner only.** It analyses Iceberg tables and writes metadata. It never builds load SQL and never
  touches target tables.
- **How it runs:** an anonymous Snowflake Scripting block, run by hand from a Snowflake Workspace.
- **Inputs:** one database and one schema (both required; **any** database or schema), plus an optional
  list of one or more tables.

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
3. **Decide from each table's own partition setup, not from its layer or database name.** The script has
   to work on any database and schema. So it reads which columns the table is actually partitioned on,
   and uses that. CURRENT vs HISTORY only changes which partition columns exist. It's recorded for
   information, not used to decide. `EFFCTV_TS` / `EXPRTN_TS` are source business dates present in both
   layers, so they say nothing about the table type.
4. **Record the point in time the plan describes (`PROFILED_AT`).** CURRENT tables change in place. How the
   loader uses this is the loader's concern; retention is confirmed out of scope.
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

## 1a. Decisions recorded (2026-10-05)

| # | Decision |
|---|---|
| D1 | The script must handle **any database and schema**, CURRENT or HISTORY. The decision is driven by each table's partition setup and columns, never by database or schema names (§3.3) |
| D2 | Time Travel retention is **not a planner concern**. The planner records `PROFILED_AT` for information |
| D3 | The metadata location is set by variables at the top of the script, `metadata_database = 'test_db'` and `metadata_schema = 'test_schema'`, to be updated by hand once finalised (§5.1) |
| D4 | Whether `GRS_PROCESS_DATE` is derived from `GRS_REFINED_TIMESTAMP` is **unknown**. The design no longer depends on it: a split-day chunk is always "this day **and** this timestamp range" |
| D5 | The layer type (append-only vs updated) doesn't matter. All data is loaded either way, and the goal is only to decide chunking |
| D6 | **If a table's chunking can't be decided, that table gets status `FAILED` with the reason, and the script moves on to the next table.** The run never stops because of one table |
| D7 | No script yet |
| D8 | There is no given chunk size. **Recommended starting value: 10 GB of Iceberg data per chunk**, with a 250M-row cap (§4.3) |
| D9 | **No `HIST_PLAN_RUN` table.** The run summary is returned to the Workspace. `RUN_ID` stays as a column on `HIST_PLAN_TABLE` to group one run's rows |
| D10 | **No `HIST_PLAN_CONFIG` table.** Its settings become variables at the top of the script (§5.1) |
| D11 | **Status is held at table level in `HIST_PLAN_TABLE`**: `PLANNED` / `FAILED` / `SKIPPED` / `SUPERSEDED`, with the reason. The chunk table has no status column |
| D12 | **A wrong name in the input table list → the script validates, reports and exits.** Nothing is written. A name that exists but isn't an Iceberg table also counts as wrong |
| D13 | **With no table list, non-Iceberg objects are skipped and reported**: how many, which ones, and why. Reported in the Workspace output and recorded in `HIST_PLAN_TABLE` |
| D14 | **Chunk size follows the warehouse.** The script detects the size of the warehouse it is running on and derives the chunk size from it. Medium (10 GB) is the fallback if detection fails. Two optional overrides exist (§4.3) |
| D15 | **Skipped objects are kept in `HIST_PLAN_TABLE` with status `SKIPPED`** and the reason (one current row per object) |

---

## 2. What changed from revision 4

| Revision 4 | Revision 5 |
|---|---|
| Generic candidate list (partition column, landing timestamp, `row_effective_date`, surrogate key, other dates), scored per table | **One decision procedure**: partition days, then an in-day split, with fallbacks for non-standard tables. Business columns are never candidates (§4) |
| SCD2 detected by `row_effective_date` / `row_expiration_date` | **Layer detected** by partition columns + hash columns + database name (§3.3) |
| `EXPLAIN` pruning probe per candidate | **Not needed.** Whole-day chunks skip other files by definition. The probe stays only as a test for the loader's HISTORY-table filter (§9) |
| Window-function cut over hour buckets | **Simple loop over days.** The list has one row per day, so it's small (§8) |
| Timestamp boundaries `TIMESTAMP_NTZ` | **`TIMESTAMP_TZ`** (§6, F7) |
| `PROFILED_AT` recorded as a convenience | Revision 5 made it a loader requirement. **Revision 6: recorded for information only** (D2) |
| Layer detected by partition + hash columns + database name (rev 5) | **Revision 6: database name not used.** The chunk axis comes from the actual partition spec. Layer is informational (D1, §3.3) |

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

**A note on terminology (D5: it does not affect chunking).** By its DDL, the HISTORY table is a **change log**. It has the CDC operation
(`OP`), the change sequence, and before/after hashes (`LAST_ROW_HASH` / `NEW_ROW_HASH`). It is not an SCD2
table with dates that Zone1 maintains. The validity dates (`EFFCTV_TS` / `EXPRTN_TS`) come from the source
and appear in the CURRENT table too. This doesn't change chunking. It does matter to anyone who assumes
"SCD2" means one open version per key.

### 3.3 What the script reads about each table (metadata only, no data scanned)

| What | From | Used for |
|---|---|---|
| Is it an Iceberg table? | `INFORMATION_SCHEMA.TABLES.IS_ICEBERG` | Scope |
| **Which columns it is partitioned on, and how** (identity, `DAY(…)`, `MONTH(…)` …) | `partition_specs` from `SHOW ICEBERG TABLES`, or the `PARTITION BY` clause from `GET_DDL` | **Choosing the chunk axis** (§4.2) |
| Column names and types | `INFORMATION_SCHEMA.COLUMNS` | Finding `GRS_REFINED_TIMESTAMP`, `GRS_UNIQUE_ID`, and the partition columns' types |
| Size in bytes, and file row counts | `ICEBERG_TABLE_FILES` | Small-table test; average row size |
| Layer, for information | `ROW_HASH` vs `NEW_ROW_HASH`/`LAST_ROW_HASH` present | Shown in the metadata only. Never decides anything |

Nothing here depends on the database or schema name, so the same script works anywhere (D1).

---

## 4. How the chunking technique is chosen

### 4.1 Same rules for every table, different result per table

There is **one decision procedure**, applied the same way to every table, so results are consistent and
easy to review. What it produces is **different per table**, because it is driven by that table's own
information and data:

| What adapts | Driven by | Example |
|---|---|---|
| **Chunk axis**: which column(s) divide the chunks | The table's partition spec (§4.2) | `GRS_PROCESS_DATE` on CURRENT tables; `GRS_PROCESS_YEAR/MONTH/DAY` on HISTORY tables |
| **Rows per chunk** | One size target in bytes ÷ this table's average row size | A wide table gets fewer rows per chunk than a narrow one, so both produce similarly sized chunks |
| **Chunk ranges**: how many days each chunk covers | How many rows each day holds | Quiet periods → one chunk spans hundreds of days; busy periods → a few days per chunk |
| **Whether a day is split, and how** | Rows in that day, and whether `GRS_REFINED_TIMESTAMP` spreads within it | A bulk backfill day of 600M rows becomes ~12 pieces; a normal day stays whole |
| **Single chunk or not** | Table size | A small reference table → one chunk, no ranges |

So the approach is fixed, but the technique and the ranges are tailored to each table automatically.
Nothing is hand-tuned per table. The size target is one variable at the top of the script (§4.3).

### 4.2 Step 1: choose the chunk axis from the table information

The first row that matches wins:

| Table information | Chunk axis | File skipping |
|---|---|---|
| Partitioned on a DATE column, identity (e.g. `GRS_PROCESS_DATE`) | **Partition day** | **Guaranteed** |
| Partitioned on year/month/day INT columns (e.g. `GRS_PROCESS_YEAR/MONTH/DAY`) | **Partition day**, the three combined into one date | **Guaranteed** |
| Partitioned with a time transform on a timestamp (`DAY(ts)`, `MONTH(ts)`, `YEAR(ts)`, `HOUR(ts)`) | **Partition period** at that transform's granularity | **Guaranteed** |
| Not partitioned on a date (or other transforms, not seen in the reference DDL), but has `GRS_REFINED_TIMESTAMP` | **`GRS_REFINED_TIMESTAMP` ranges** across the table | Depends on file layout. Not guaranteed |
| No date partition and no `GRS_REFINED_TIMESTAMP`, but has `GRS_UNIQUE_ID` | **Hash buckets** on `GRS_UNIQUE_ID` | None: each chunk reads the whole table |
| None of the above | — | Table → **`FAILED`**: "no usable chunk column" (D6) |

Both reference DDLs land in the first two rows. The last three rows are there so that a table which
doesn't follow the standard structure still gets planned, or fails cleanly, instead of stopping the run.

### 4.3 Step 2: set the size target, and the recommended chunk size

**Per table**: `TARGET_ROWS = target_chunk_bytes ÷ AVG_ROW_BYTES`, capped at `max_chunk_rows`. The average
row size is the table's Iceberg file bytes ÷ its rows, so wide tables get fewer rows per chunk. **If the
whole table is no bigger than `target_chunk_bytes`, it is one chunk** and the procedure stops here. No
separate small-table setting is needed.

**Recommended starting value: `target_chunk_bytes` = 10 GB** of Iceberg (compressed Parquet) data per chunk,
assuming loads run on a **Medium** warehouse. `max_chunk_rows` = 250M. The reasoning:

| Force | What it pushes towards | How 10 GB sits |
|---|---|---|
| **Keep every warehouse thread busy until the end of the chunk.** Each node has 8 threads (Medium = 4 nodes = 32 threads), and each thread works on one file at a time | Bigger. A chunk needs many files per thread | Snowflake-managed Iceberg files start at 16 MB (`TARGET_FILE_SIZE = AUTO`) and can grow to 128 MB. So 10 GB is about 80–640 files, roughly 2.5–20 per thread on a Medium. That's about 300 MB per thread |
| **Fixed cost per chunk** (compile, start, commit, any orchestration) should be small next to the chunk's run time | Bigger | A few seconds of overhead against minutes of work |
| **Cost of a failure**: a failed chunk is redone completely | Smaller | At most 10 GB is re-read |
| **A manageable number of chunks** | Bigger | 1 TB → ~100 chunks; 100 GB → ~10 |
| **Very narrow, highly compressible tables** do more work per compressed byte | A row cap | 250M rows caps them. For example, at 20 bytes/row, 10 GB would otherwise be 500M rows |

**Scale it with the warehouse, automatically (D14).** At about 300 MB per thread, the chunk size is
**2.5 GB per warehouse node**. The row cap scales the same way, at 62.5M rows per node:

| Warehouse size | Nodes | Threads | `target_chunk_bytes` | `max_chunk_rows` |
|---|---|---|---|---|
| X-Small | 1 | 8 | 2.5 GB | 62.5M |
| Small | 2 | 16 | 5 GB | 125M |
| **Medium (fallback)** | **4** | **32** | **10 GB** | **250M** |
| Large | 8 | 64 | 20 GB | 500M |
| X-Large | 16 | 128 | 40 GB | 1B |
| 2X-Large and above | 32+ | 256+ | **capped at 40 GB** | **capped at 1B** |

**How the script detects it.** Inside the block, this reads the current warehouse's row:

```sql
SHOW WAREHOUSES ->> SELECT "name", "size", "type" FROM $1 WHERE "is_current" = 'Y';
```

It then looks the size up in the table above.

**Order of precedence.** The first one that applies wins, and the result is recorded per table:

| # | Source | When | `SIZING_SOURCE` recorded |
|---|---|---|---|
| 1 | `p_target_chunk_bytes` variable | Set (not NULL). An explicit size for special cases | `OVERRIDE_BYTES` |
| 2 | `p_load_warehouse_size` variable, e.g. `'LARGE'` | Set. Use when the **loads will run on a different warehouse** than this script | `OVERRIDE_WAREHOUSE_SIZE` |
| 3 | **The current warehouse, detected** | Default | `DETECTED_CURRENT_WAREHOUSE` |
| 4 | Medium | Detection failed, or the size isn't recognised | `FALLBACK_MEDIUM` |

**One caution: the planning warehouse is not necessarily the loading warehouse.** Detection sizes chunks
for the warehouse the *script* runs on. If you plan on an X-Small to save credits but the loads run on a
Large, detection would give 2.5 GB chunks instead of 20 GB. So either run the script on the warehouse the
loads will use, or set `p_load_warehouse_size`. **A mismatch only affects efficiency, never correctness.**
Chunks still cover every row exactly once; they just run shorter or longer than intended. The Workspace
summary prints the warehouse and size it used, so a mismatch is visible straight away.

**Why cap at 40 GB?** Beyond X-Large, chunks would be 80 GB or more, so one failure would mean re-reading
a lot of data. Very large warehouses are usually better used running several chunks at once than running
huge chunks one at a time. The cap is a variable (`max_target_chunk_bytes`) if you disagree.

**Warehouse types:**
- **Standard warehouses**, Gen1 and Gen2, use the table above. Gen2 has faster nodes, so chunks simply
  finish sooner; calibration absorbs that.
- **Snowpark-optimized warehouses** have the same node counts and more memory per node, so the same
  mapping applies. The type is recorded.
- **Multi-cluster settings don't matter.** One chunk is one query, and one query runs on one cluster.

**Then calibrate it once.** This is a reasoned starting point, not a measured one. When the load team
first loads one chunk, measure its run time. **Aim for about 5–15 minutes per chunk**, and adjust
`bytes_per_node` in proportion: for example, if a 10 GB chunk on a Medium takes 30 minutes, halve it to
1.25 GB per node. Every warehouse size then scales correctly from the one measurement. A re-plan with
`p_force_replan` applies the new size. To help with this, the planner records each table's average
file size and file count.

### 4.4 Step 3: profile along the axis

Count rows per partition day. This reads only the partition column(s), so it's cheap (§8.1). It gives the
exact total row count, and shows whether any partition values are NULL.

### 4.5 Step 4: cut the days into chunks, splitting only the days that are too big

```
walk the days in order, keeping a running total for the open chunk:
  day_rows > TARGET_ROWS            → close the open chunk; split this day (below)
  running + day_rows > TARGET_ROWS  → close the open chunk; start a new one with this day
  otherwise                         → add the day to the open chunk

split one oversized day:
  a. count rows per minute of GRS_REFINED_TIMESTAMP inside that day (reads only that day)
     no NULLs and no single minute > TARGET_ROWS → DAY_SUBRANGE chunks: this day AND a timestamp range
  b. otherwise                                  → DAY_HASH chunks: this day AND hash bucket b of n,
                                                   n = CEIL(day_rows / TARGET_ROWS)

NULL partition values (if any) → one NULL_PARTITION chunk
finally: Σ chunk rows must equal the table's rows, otherwise the table → FAILED
```

Each split piece is always "this day **and** …". So it stays inside its day, whether or not
`GRS_PROCESS_DATE` is derived from `GRS_REFINED_TIMESTAMP` (D4).

### 4.6 Which technique is "best optimized"

"Optimized" here means three things, in this order:
1. **Each chunk reads as little as possible beyond its own rows**, by skipping files.
2. **Chunks are close to the target size and similar to each other.**
3. **There are as few chunks as the target allows.**

The techniques rank like this, and the procedure always uses the best one a table's information and data
allow, **decided day by day**:

| Rank | Technique | What a chunk reads | Chunk size accuracy | Used when |
|---|---|---|---|---|
| 1 | **Whole partition days** (`DAY_RANGE`) | Only its own days' files | Within one day's rows of the target | Default for every partitioned table |
| 2 | **Day + `GRS_REFINED_TIMESTAMP` sub-range** (`DAY_SUBRANGE`) | Only that day's files, often only part of them | Within one minute's rows of the target | A day bigger than the target, with timestamps spread out |
| 3 | **Day + hash bucket** (`DAY_HASH`) | All of that day's files, once per bucket | Exactly even | A day bigger than the target that the timestamp can't split (e.g. a bulk load stamped with one timestamp) |
| 4 | **`GRS_REFINED_TIMESTAMP` range over the whole table** | Depends on file layout; possibly the whole table | Within one minute's rows | Table not partitioned on a date |
| 5 | **Hash bucket over the whole table** | The whole table, every chunk | Exactly even | Last resort |

One table can mix ranks 1–3. For example, most days are grouped whole, while one backfill day is split
into hash buckets.

**Columns that are never used**, and why:
- **Business dates and keys** (`EFFCTV_TS`, `*_ID`, …): names differ per table, some change in place, and
  none of them is the partition column.
- **`CHANGE_SEQ_NUM` and `AR_H_TIMESTAMP`**: stored as strings.
- **`GRS_LANDING_DATE`**: also a string.

### 4.7 Worked examples

The numbers are illustrative only, with `TARGET_ROWS` = 50M, which is what 10 GB gives at about
200 bytes/row.

**A — HISTORY table, 1.2B rows, mostly one Teradata backfill**

| Days | Rows | Result |
|---|---|---|
| 2026-08-14 | 620M | Too big → split. Timestamps spread → ~13 `DAY_SUBRANGE` chunks. One timestamp → 13 `DAY_HASH` chunks |
| 2026-08-15 | 380M | Too big → split into ~8 chunks the same way |
| 2026-08-16 … 2026-10-04 (50 days × 4M) | 200M | Grouped whole: 12 days per chunk (48M) → 5 `DAY_RANGE` chunks: 4 × 12 days + 1 × 2 days |
| **Total** | 1.2B | **~26 chunks**, all similar in size |

**B — CURRENT table, 300M rows over ~4 years, busier in recent periods** (updated rows move to recent
dates)

| Days | Rows | Result |
|---|---|---|
| Oldest 1,000 days (50k/day) | 50M | 1 chunk covering ~1,000 days |
| Next 200 quiet days + 50 busy days (800k/day) | 50M | 1 chunk covering 250 days |
| Last 250 busy days | 200M | 62 days per chunk → 5 chunks (4 × 62 days + 1 × 2 days) |
| **Total** | 300M | **7 chunks**, from 1,000 days down to 2 days wide, all about 50M rows |

**C — small reference table, 2M rows, 300 MB** → no bigger than the 10 GB target → **1 chunk** (`ALL`).

**D — a table in another schema, not partitioned, with `GRS_REFINED_TIMESTAMP`** → rank 4: timestamp ranges
across the table. The plan records that file skipping isn't guaranteed.

**E — a table with no date partition, no `GRS_REFINED_TIMESTAMP` and no `GRS_UNIQUE_ID`** → status
**`FAILED`**: "no usable chunk column". The run carries on with the next table (D6).

### 4.8 How each chunk's range is set

- **Half-open ranges.** A row is in a chunk when `start ≤ value < end`, so each chunk's `end` is the next
  chunk's `start`. No row can fall in two chunks or between them.
- **Whole-day chunks**: `DAY_START` = the chunk's first day, `DAY_END` = the next chunk's first day. Days
  with no data in between are covered automatically.
- **Open ends**: the **very first** chunk gets `DAY_START = NULL` and the **very last** gets
  `DAY_END = NULL`, meaning unbounded, but only when that chunk is a whole-day range.
- **Split day**: `DAY_START = that day`, `DAY_END = the next day`, plus either a `GRS_REFINED_TIMESTAMP`
  range or a hash bucket number. Within the day, the first piece's timestamp start and the last piece's
  timestamp end are open.
- **NULL partition values**: a separate `NULL_PARTITION` chunk.

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

    -- ====== METADATA LOCATION: update by hand once finalised (D3) ======
    metadata_database VARCHAR DEFAULT 'test_db';
    metadata_schema   VARCHAR DEFAULT 'test_schema';

    -- ====== CHUNK SIZING: see §4.3 (D8, D10, D14) ======
    p_target_chunk_bytes   NUMBER  DEFAULT NULL;         -- NULL = derive from warehouse size
    p_load_warehouse_size  VARCHAR DEFAULT NULL;         -- NULL = detect current warehouse; or 'MEDIUM', 'LARGE', ...
    bytes_per_node         NUMBER  DEFAULT 2684354560;   -- 2.5 GB per warehouse node (~300 MB per thread)
    rows_per_node          NUMBER  DEFAULT 62500000;     -- row cap per node, for very narrow tables
    max_target_chunk_bytes NUMBER  DEFAULT 42949672960;  -- 40 GB ceiling (X-Large)
    split_grain            VARCHAR DEFAULT 'MINUTE';     -- grain for splitting an oversized day
    -- =================================================================
    ...
BEGIN
    ...
END;
```

The variables are declared at the top of the block, in `DECLARE`. Assigning them with `LET` at the very
start of `BEGIN` works too; either way they stay in one visible place. The two metadata tables are always
read and written as `metadata_database.metadata_schema.<table>`.

Inputs are not passed as session variables (`SET`), because a session variable's string value is capped
at **256 bytes**. A list of a few table names with these long names, about 40 characters each, would
exceed it.

### 5.2 Validation and skipping

**Input validation runs first. Any problem → the script reports it and exits, and nothing is written
(D12).**

1. `p_database` / `p_schema` blank → exit. Database missing, or schema missing in it → exit, naming which.
2. **Table list given**:
   - Split on commas, trim, drop empty entries, remove duplicates.
   - Match each name against `INFORMATION_SCHEMA.TABLES`: an exact match first, then a case-insensitive
     match only if exactly one table matches. Never `LIKE`: `_` is a wildcard, and these names are full of
     underscores.
   - A name that is **not found**, **ambiguous**, or **exists but is not an Iceberg table** is invalid.
   - **Any invalid name → exit**, with one message listing every invalid name and its reason. For example:
     `Input validation failed (2 of 5 names): PRDSCT1D_SCOUT_XYZ - not found; PRDSCT1D_SCOUT_V1 - view, not
     an Iceberg table`.

**Skipping, when no table list is given (D13).** Every object in the schema's
`INFORMATION_SCHEMA.TABLES` is accounted for. Iceberg tables are planned; everything else is skipped, with
a reason:

| Object | Skip reason recorded |
|---|---|
| Standard Snowflake table (`BASE TABLE`, `IS_ICEBERG = 'NO'`) | `Not an Iceberg table (standard table)` |
| `VIEW` / `MATERIALIZED VIEW` | `Not an Iceberg table (view)` / `(materialized view)` |
| `EXTERNAL TABLE` | `Not an Iceberg table (external table)` |
| `EVENT TABLE`, dynamic (`IS_DYNAMIC`), hybrid (`IS_HYBRID`), `TEMPORARY TABLE` | `Not an Iceberg table (<type>)` |

**Already planned** (in either mode): an Iceberg table with an active plan is skipped, with the reason
`Already planned (plan <PLAN_ID>); set p_force_replan = TRUE to re-plan`.

### 5.3 Running it in a Workspace

- **The block runs as-is.** Snowsight runs `DECLARE … BEGIN … END;` directly, so no `EXECUTE IMMEDIATE`
  and no `$$` are needed. Confirm with a trivial block first (§9).
- **Context**: a role with `USAGE` on the source database and schema, `SELECT` on the tables, and write
  access to the metadata tables. Select a warehouse before running.
- **Output**: `RETURN TABLE(…)` shows a result grid in the Workspace.
  - One row per table: table name, outcome (`PLANNED` / `FAILED` / `SKIPPED`), reason, chunk axis, chunk
    count, total rows, total bytes. Rows are ordered skipped, then failed, then planned.
  - **A final summary row** with the counts and the sizing used. For example: `In schema: 45 | Planned: 30 |
    Failed: 2 | Skipped: 13 (non-Iceberg: 10, already planned: 3) | Sizing: WH_LOAD_M (Medium, detected) →
    10 GB / 250M rows per chunk`.
  - The same outcomes are stored in `HIST_PLAN_TABLE` (D9, D11).
- **Errors**:
  - Validation errors `RAISE` and nothing is written.
  - **Any problem with one table** marks that table `FAILED` in `HIST_PLAN_TABLE`, with the reason in
    `ERROR_MESSAGE`, and the run continues with the next table (D6). Examples: no usable chunk column, a
    permission error, a profiling query error, or a row-sum mismatch.
- **Interruptions**: each table commits separately, so a cancelled run keeps the finished tables.
  Re-running with the same inputs skips them as already planned and continues with the rest.

---

## 6. Metadata tables

**`HIST_PLAN_TABLE`**: one row per table per plan version.

| Column | Purpose |
|---|---|
| `PLAN_ID`, `RUN_ID` | Plan identity; the run that produced it |
| `DATABASE_NAME`, `SCHEMA_NAME`, `TABLE_NAME` | The table |
| `OBJECT_TYPE` | From `INFORMATION_SCHEMA.TABLES`, e.g. `ICEBERG TABLE`, `BASE TABLE`, `VIEW`. Explains skips |
| `LAYER` | `CURRENT` / `HISTORY` / `UNKNOWN`. For information only (§3.3) |
| `CHUNK_AXIS` | `PARTITION_DAY` / `PARTITION_PERIOD` / `REFINED_TS_RANGE` / `UNIQUE_ID_HASH` (§4.2) |
| `PARTITION_COLUMNS` | `GRS_PROCESS_DATE`, or `GRS_PROCESS_YEAR,GRS_PROCESS_MONTH,GRS_PROCESS_DAY` |
| `PARTITION_VERIFIED` | Whether the Iceberg partition spec confirms those columns |
| `CHUNK_METHOD` | `SINGLE` / `PARTITION_DAYS` (all chunks whole days) / `PARTITION_DAYS_WITH_SPLITS` (some days split) |
| `PROFILED_AT` (`TIMESTAMP_TZ`) | The point in time the plan describes. The loader reads `AT` this (F8) |
| `TOTAL_ROWS`, `TOTAL_BYTES`, `COLUMN_COUNT`, `AVG_ROW_BYTES`, `FILE_COUNT`, `AVG_FILE_BYTES` | Profile. The file figures help calibrate the chunk size (§4.3) |
| `DAY_COUNT`, `SPLIT_DAY_COUNT`, `CHUNK_COUNT` | Result: **how many chunks this table has** |
| `TARGET_CHUNK_BYTES`, `TARGET_ROWS_PER_CHUNK` | The size target the chunks were cut to |
| `SIZING_WAREHOUSE`, `SIZING_WAREHOUSE_SIZE`, `SIZING_WAREHOUSE_TYPE`, `SIZING_SOURCE` | Which warehouse and size the target came from, and how (§4.3 precedence) |
| **`PLAN_STATUS`** | **`PLANNED`** (chunks are in `HIST_PLAN_CHUNK`) / **`FAILED`** (chunking couldn't be decided) / **`SKIPPED`** (not an Iceberg table) / **`SUPERSEDED`** (replaced by a newer plan) (D6, D11) |
| **`STATUS_REASON`** | Why it failed or was skipped, e.g. `No usable chunk column`, `Not an Iceberg table (view)`, or the Snowflake error text |
| `IS_ACTIVE` | One active row per table |
| `PLANNED_AT` | When this row was written |

Rows by status:
- **`FAILED`** rows keep the profile columns that were filled before the failure.
- **`SKIPPED`** rows fill only the identity, `OBJECT_TYPE`, status and reason columns. Each skipped object
  keeps **one** current row; a re-run replaces it rather than adding another.

**`HIST_PLAN_CHUNK`**: one row per chunk. Key: `(PLAN_ID, CHUNK_SEQ)`.

| Column | Purpose |
|---|---|
| `PLAN_ID`, `CHUNK_SEQ` | Identity and order |
| `CHUNK_TYPE` | `ALL` / `DAY_RANGE` / `DAY_SUBRANGE` / `DAY_HASH` / `NULL_PARTITION` |
| `DAY_START`, `DAY_END` (`DATE`) | Partition days, half-open `[start, end)`. NULL = unbounded: only on the very first or very last chunk, and only if that chunk is a `DAY_RANGE`. For a split day, `DAY_END = DAY_START + 1` |
| `SUB_COLUMN` | `GRS_REFINED_TIMESTAMP` for `DAY_SUBRANGE`; `GRS_UNIQUE_ID` for `DAY_HASH` |
| `SUB_START_TS`, `SUB_END_TS` (`TIMESTAMP_TZ`) | `DAY_SUBRANGE` only. Half-open; NULL = open at the day edge |
| `HASH_BUCKET`, `HASH_MODULUS` | `DAY_HASH` only. A row is in the chunk when `MOD(ABS(HASH(GRS_UNIQUE_ID)), HASH_MODULUS) = HASH_BUCKET` |
| `ESTIMATED_ROWS`, `ESTIMATED_BYTES` | Chunk size. Rows are exact at `PROFILED_AT` for day and sub-range chunks, and an even share for hash chunks. Bytes = rows × `AVG_ROW_BYTES` |

There is no status column here: status is held per table in `HIST_PLAN_TABLE` (D11).

For HISTORY tables, `DAY_START` / `DAY_END` are logical dates made from `GRS_PROCESS_YEAR/MONTH/DAY`. The
loader turns them back into year/month/day conditions (§9, loader note).

`HIST_PLAN_RUN` and `HIST_PLAN_CONFIG` from revision 6 are **removed** (D9, D10).

---

## 7. Findings on the original design

| # | Severity | Finding | Resolution |
|---|---|---|---|
| F1 | Critical | Boundaries from observed min/max, read with `BETWEEN`, leave gaps and overlaps; NULLs are dropped | Half-open ranges, open-ended first and last day ranges, a `NULL_PARTITION` chunk, and a rows-sum check (§4.5) |
| F2 | Critical | `MERGE` keyed on `CHUNK_SEQ` can rewrite boundaries under chunks already used, and leave orphan chunks behind | A new `PLAN_ID` per plan; chunk rows are insert-only. Re-planning happens only with `p_force_replan`: the old plan is marked `SUPERSEDED` (kept, never edited) and the new one becomes active. One transaction per table. Drop the row-growth staleness rule. The loader should always use the active plan, and not switch plans in the middle of a table |
| F3 | Important | Single-date-column heuristic and month→day recursion | Replaced by §4: partition days, then an in-day split |
| F4 | Important | `SHOW … LIKE` validation (case-insensitive, `_` wildcard) | `INFORMATION_SCHEMA.TABLES` exact matching (§5.2) |
| F5 | Important | CONFIG sized in rows only; `MIN_ROWS_TO_CHUNK = 1M` is very low; the "÷ columns" proxy | Size by bytes (10 GB starting value) with a row cap. A table no bigger than the target is one chunk. Column count kept for information only (§4.3) |
| F6 | Minor | "No open questions left"; Task and two invocation paths | Questions in §10; one path (Workspace) |
| **F7** | **Critical** | All timestamp columns are `TIMESTAMP_LTZ`. NTZ or `VARIANT` boundaries are read in whatever session time zone the loader uses, which can shift edges by hours | Store `SUB_*_TS` as `TIMESTAMP_TZ`; set `TIMEZONE = 'UTC'` at the top of the block, because `DATE_TRUNC` on LTZ depends on it |
| **F8** | Important (loader) | CURRENT tables change in place, and an update moves a row to a new `GRS_PROCESS_DATE`. If the loader reads the live table, rows changed between plan and load are missed or loaded twice | Record `PROFILED_AT` in the plan. How the loader handles changes after it is the loader's concern; retention was confirmed out of scope (D2) |

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

The very first chunk gets `DAY_START = NULL` and the very last gets `DAY_END = NULL`, when they are
`DAY_RANGE` chunks. Days with no data
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
4. Then write the DDL for the two metadata tables, and the block.

---

## 10. Open questions

Answered on 2026-10-05: D1–D15 in §1a. **No open questions block writing the DDL and the script.** Two
judgement calls are flagged for your review:
- the 40 GB ceiling for warehouses larger than X-Large (§4.3);
- the 2.5 GB-per-node starting value. It must be calibrated on the first real load either way.

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
| Snowflake-managed Iceberg supports Time Travel | Snowflake Iceberg docs (via search extract). Retention is not a planner concern (D2) |
| Iceberg file row counts don't subtract deletes or deletion vectors | Snowflake Iceberg docs and release notes (via search extract) |
| Snowflake-managed Iceberg `TARGET_FILE_SIZE` defaults to `AUTO`, starting at 16 MB; options up to 128 MB | Snowflake `CREATE/ALTER ICEBERG TABLE` docs (via search extract) |
| 8 threads per warehouse node (Medium = 32); one file per thread at a time | Third-party warehouse-sizing write-ups (via search extract). Not an official Snowflake page |
| Nodes double per size, from X-Small = 1 to 6X-Large = 512; Snowpark-optimized has the same sizes with 16× memory per node and isn't offered in X-Small or Small | Snowflake warehouse docs and third-party summaries (via search extract) |
| `SHOW WAREHOUSES` has `name`, `size`, `type`, `is_current`; `CURRENT_WAREHOUSE()` returns the name; `SHOW … ->> SELECT … FROM $1` works in a scripting block, with double-quoted column names | Snowflake `SHOW WAREHOUSES`, `CURRENT_WAREHOUSE`, and flow-operator docs (via search extract) |
| `INFORMATION_SCHEMA.TABLES` `TABLE_TYPE` values; `IS_DYNAMIC`, `IS_HYBRID` columns | Snowflake `TABLES` view docs (via search extract) |
| 10 GB / 5–15 minutes per chunk | **Reasoned starting values, not measured.** Calibrate on the first real load (§4.3) |
| All SQL in §8 | Written for this review, **not executed** |

`docs.snowflake.com` was not directly fetchable from this environment. Snowflake and Qlik claims rely on
search-result extracts of the official pages.
