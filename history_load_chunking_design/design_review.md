# Architecture review — Iceberg historical load chunk planner

**Revision 4 — 2026-10-05.** This revision covers the **planner only**. The planner analyses Iceberg tables
and writes metadata entries. It never builds load SQL and never touches target tables. **The planner is an
anonymous Snowflake Scripting block, run by hand from a Snowflake Workspace.** IDMC is deferred. Inputs are
one database and one schema (both required), plus an optional list of one or more table names. §2 lists
what changed from earlier revisions.

Reviewed: `solution_design.md` (this folder), cross-checked against current Snowflake docs.

---

## 0. Verdict

The design's planner is sound in outline: profile each table, chunk by data volume, give small tables one
chunk, isolate per-table failures, and write descriptors only. Five things should change before the DDL
and the block are written:

1. **Choose the chunk column from each table's DDL plus a cheap profile.** Do not use the single
   "partition spec, else the only date column" rule (§4). The DDL also identifies SCD1 vs SCD2. That
   matters because some SCD2 columns change over time and must never be chunk columns.
2. **Make the ranges exact and unambiguous**: half-open `[start, end)`, open-ended at both ends, NULLs
   handled, and the chunk counts adding up to the table's rows (F1).
3. **Make plans versioned and immutable**, so a re-run can't silently change chunks a downstream loader has
   already used (F2).
4. **Type the boundary columns** and split the metadata into a plan-level table and a chunk-level table (§6).
5. **Declare the inputs at the top of the script, not as session variables.** A session variable holds at
   most 256 bytes, and a list of table names will exceed that. Validate the whole table list before
   anything is written (§5).

---

## 1. Scope as confirmed

| In scope | Out of scope |
|---|---|
| Input: database + schema (required); **one or many table names (optional)**. With no names given, all Iceberg tables in the schema | Building per-chunk extraction or load SQL |
| Discover Iceberg tables; read their DDL | Loading data; creating or changing target tables |
| Profile: rows, bytes, columns, candidate chunk columns | Load-side reconciliation, retries, delete-and-reload |
| Decide per table: how many chunks, on which column, which ranges, what size | Orchestrating the downstream load |
| Write metadata entries; validate inputs; isolate per-table failures | |
| Run as an **anonymous block from a Snowflake Workspace** | Stored procedures (not allowed); Tasks (not needed); IDMC (deferred) |

The metadata answers four questions per Iceberg table: **how many chunks; the size of each (rows and
bytes); which column divides them; and each chunk's range on that column.**

---

## 2. What changed from earlier revisions

| Earlier finding | Now |
|---|---|
| ABC integration (rev 1) | **Withdrawn**: the load runs outside ABC |
| `MERGE` / chunk ordering / SCD2 parallel-load hazard (rev 1) | **Withdrawn**: loading is out of scope |
| Load reconciliation (`COUNT`/`HASH_AGG`), delete-then-insert retries (rev 2) | **Removed**: they belong to the loader |
| Calibrating chunk size on a real load (rev 1–2) | **Reduced to an input**: the target chunk size is a CONFIG value the loader team supplies (§3, F5) |
| Task + session variables (rev 1–2) | **Replaced**: inputs are declared at the top of the script (§5) |
| IDMC execution tests (rev 3) | **Deferred**: the script runs from a Snowflake Workspace. The IDMC points are kept as a short note at the end of §5 |
| Single optional table name (design, rev 1–3) | **Widened** to an optional list of one or more names (§5) |
| Boundaries, re-planning, DDL-driven column choice, typed metadata | **Kept**, reworded for planner scope |

---

## 3. Keep these from the design

- Descriptors only. No SQL is stored, so the loader owns its queries.
- Chunks are sized by data volume, not by calendar period.
- Small tables get one chunk.
- Inputs are validated before anything is written.
- One table's failure never stops the run, and failed tables are retryable.
- CONFIG holds the tunables (global default plus per-table overrides). Nothing is hard-coded.
- `SHOW ICEBERG TABLES` for discovery; `INFORMATION_SCHEMA.COLUMNS` for structure.

---

## 4. Choosing the chunk column from each table's structure

### 4.1 Why the design's rule isn't enough

The design uses the partition-spec time column, otherwise "the single DATE/TIMESTAMP column", otherwise a
key range. That rule has four gaps:
- Most Zone1 tables have **several** date/timestamp columns: landing timestamp, `row_effective_date`,
  `row_expiration_date`, business dates. The "single column" rule would rarely fire, and most tables would
  fall to the key-range path.
- It never checks the things that make a column usable: NULLs, whether one value holds too many rows, and
  whether a range on it actually skips files.
- It doesn't exclude **columns whose values change**. For SCD2, `row_expiration_date` changes when a
  version closes. A row chunked on it at plan time can sit in a different chunk by load time, and so be
  loaded twice or not at all.
- It treats SCD1 and SCD2 the same, although their safe columns differ.

### 4.2 What makes a column a good chunk column

| # | Criterion | Why | How the planner measures it |
|---|---|---|---|
| 1 | **No NULLs**, or a separate NULL chunk | Range filters skip NULL rows | `COUNT_IF(col IS NULL)` |
| 2 | **Splittable**: no single value holds more than the target chunk size | One value can't be split across chunks | Largest bucket in the density pass |
| 3 | **Prunes well**: a range on it skips most files | Otherwise every chunk the loader runs reads the whole table | `EXPLAIN` of a ~1/N slice: `partitionsAssigned / partitionsTotal`. Compile-time only, no data read (⚠️ check that it works on Iceberg, §9) |
| 4 | **Values never change** | A row must stay in one chunk between plan and load | DDL rule, §4.3 |
| 5 | **Sortable type**: DATE / TIMESTAMP / NUMBER | Clean ranges. Strings bring collation problems | `INFORMATION_SCHEMA.COLUMNS.DATA_TYPE` |

### 4.3 SCD1 vs SCD2: what the DDL changes

| | SCD1 | SCD2 |
|---|---|---|
| Detected by | Lacks the SCD2 date pair | Has `row_effective_date` **and** `row_expiration_date` (project naming; CONFIG can override) |
| Natural candidates | Landing timestamp, numeric surrogate key, created date | Landing timestamp, **`row_effective_date`**, numeric surrogate key |
| **Never the chunk column** | Columns updated in place (last-updated timestamps, status) | **`row_expiration_date`**, current/active flags, `is_del` |
| Typical distribution | Recent-heavy on update-type columns | Effective dates spread across years, which suits even chunks |

### 4.4 Candidate order

All read from the DDL: `INFORMATION_SCHEMA.COLUMNS`, plus `partition_specs` from `SHOW ICEBERG TABLES`.

1. **Iceberg partition source column**, with a time or identity transform on a date or number. Skipping
   files is guaranteed.
2. **Landing/audit timestamp** (`GRS_REFINED_TIMESTAMP`, or the DMigrator landing column). It is on every
   Zone1 table and usually matches the order files were written in.
   ⚠️ If DMigrator stamped one value per batch, one value may hold hundreds of millions of rows and fail
   criterion 2. Reconnaissance will show this (§9).
3. **SCD2 only: `row_effective_date`.**
4. **Single-column numeric surrogate key.**
5. **Other DATE/TIMESTAMP columns** not excluded in §4.3.

### 4.5 Decision procedure per table

```
1. bytes ≤ SMALL_TABLE_BYTES                      → SINGLE: 1 chunk, no range
2. for each candidate in order (§4.4):
      fails NULL / never-changes / type rule      → skip
      EXPLAIN probe → pruning ratio               (no data read)
   rank: good pruning first, then fewest NULLs
3. density pass on the best candidate (§8.2)
      largest bucket ≤ target                     → RANGE on that column
      else retry once at a finer grain; still too big → next candidate
4. nothing passes                                 → KEY_HASH on the key column(s), few buckets
```

The plan row records the method, the column, and every candidate's statistics and pruning ratio. Anyone
can then see why a table was chunked that way, and override it in CONFIG (`FORCE_CHUNK_COLUMN`,
`FORCE_METHOD`).

**Ask the loader team one question here** (Q1): does the loader need **all rows of a business key in the
same chunk**? It would, for example, if it recomputes SCD2 dates or deduplicates. If yes, range chunks are
wrong for those tables, and `KEY_HASH` becomes the method for them.

---

## 5. Inputs, validation and running from a Snowflake Workspace

### 5.1 Input contract

| Input | Required | Form | Behaviour |
|---|---|---|---|
| `P_DATABASE` | Yes | Database name | Must exist |
| `P_SCHEMA` | Yes | Schema name | Must exist in `P_DATABASE` |
| `P_TABLES` | No | Comma-separated list, e.g. `'POLICY_TXN, CLAIM_HDR, "claim_line"'`. Empty or NULL means none were given | **Empty → every Iceberg table in the schema. One or more names → exactly those tables** |
| `P_FORCE_REPLAN` | No (default `FALSE`) | Boolean | Re-plan tables that already have an active plan, still subject to the F2 guard |

### 5.2 How inputs are supplied: declared at the top of the script

```sql
DECLARE
    -- ================= INPUTS: edit before each run =================
    p_database      VARCHAR DEFAULT 'ZONE1_DB';
    p_schema        VARCHAR DEFAULT 'POLICY';
    p_tables        VARCHAR DEFAULT '';      -- '' = all Iceberg tables in the schema
                                             -- or e.g. 'POLICY_TXN, CLAIM_HDR'
    p_force_replan  BOOLEAN DEFAULT FALSE;
    -- =================================================================
    ...
BEGIN
    ...
END;
```

**Why not session variables (`SET p_tables = …`)?** A session variable's string value is limited to
**256 bytes**. Twenty-odd table names would exceed it, and the run would fail before it starts. Variables
declared inside the block have no such limit, and keeping all inputs in one visible place at the top of
the file is clearer for a script run by hand.

**Why a comma-separated string rather than an `ARRAY`?** It's easier to type and edit. The block splits it
(`SPLIT_TO_TABLE`), trims spaces, drops empty entries, and removes duplicates before validating.

### 5.3 Validation: everything is checked before anything is written, and all problems are reported together

1. `P_DATABASE` or `P_SCHEMA` blank → fail.
2. Database doesn't exist → fail, naming it. Schema doesn't exist in it → fail, naming it.
3. **Table list given**: resolve each name against `INFORMATION_SCHEMA.TABLES` for that schema.
   - **Exact match** first. That covers quoted, lower-case Iceberg names such as `"claim_line"`.
   - Otherwise a **case-insensitive match**, but only if exactly one table matches.
   - The outcomes:

     | Result | Name status |
     |---|---|
     | No match | **not found** |
     | More than one case-variant matches | **ambiguous** |
     | Found, but `IS_ICEBERG = 'NO'` | **not an Iceberg table** |

   - **Recommended behaviour**: if *any* listed name is invalid, fail the run with one message listing
     every invalid name and its reason. Nothing is written. A typo then can't silently drop a table from
     the plan (Q7).
   - Never treat names as `LIKE` patterns. `SHOW … LIKE` is case-insensitive and treats `_` as a wildcard,
     so `POL_TXN` would also match `POLXTXN`.
4. **No table list**: scope is every table in the schema with `IS_ICEBERG = 'YES'`.
   - Non-Iceberg tables are **not planned**. They are listed as `SKIPPED_NOT_ICEBERG` in the run summary,
     so it's visible that they exist (Q8).
   - A schema with no Iceberg tables finishes with a clear "0 tables in scope" summary, not an error.
5. **Already planned**: a table with an active plan is reported `SKIPPED_ALREADY_PLANNED`, unless
   `P_FORCE_REPLAN = TRUE`. In that case the F2 guard still applies.

### 5.4 Running it in a Snowflake Workspace

- **No `EXECUTE IMMEDIATE` and no `$$` wrapper is needed.** Snowsight runs a `DECLARE … BEGIN … END;`
  block directly. Workspaces is Snowsight's file editor, so it should behave the same. Confirm with a
  one-line block before the real run (§9).
- **Context**: run under a role with `USAGE` on the source database and schema, `SELECT` on its Iceberg
  tables, and `INSERT`/`UPDATE` on the metadata tables. Select a warehouse in the workspace before running.
  Profiling scans can be heavy, so a dedicated warehouse is better.
- **Output**: the block ends with `RETURN TABLE(…)`, a summary row per table that shows in the results
  grid. It has: table, outcome (`PLANNED` / `SKIPPED_ALREADY_PLANNED` / `SKIPPED_NOT_ICEBERG` /
  `PLAN_FAILED`), SCD type, method, chunk column, chunk count, total rows, error. The same information is
  saved in `HIST_PLAN_RUN` and `HIST_PLAN_TABLE`.
- **Errors**:
  - Input validation problems `RAISE`, which shows as a red error in the workspace with nothing written.
  - A problem with one table is recorded against that table, and the run carries on to the next table.
- **Long runs and interruptions**:
  - Tables are planned one after another, and **each table's writes commit separately**.
  - If the run is cancelled half-way, finished tables keep their plans. Re-running the same inputs skips
    them and continues with the rest.
  - The interrupted run's `HIST_PLAN_RUN` row would stay `RUNNING`. The next run marks it `ABORTED`.
- **Very large schemas**: everything runs as one statement. Snowflake's default statement timeout is
  2 days, but it may be set lower for your account or warehouse. For very large schemas, run in batches
  by passing table lists.

**Later, if this moves to IDMC**, re-check five things:
- whether IDMC tries to resolve the `$$` delimiters as its own parameters;
- whether it splits scripts on `;` (which breaks blocks);
- how parameters are passed;
- whether a `RAISE` fails the IDMC task;
- connection timeouts.

The block's design doesn't need to change for any of them.

---

## 6. Metadata tables (revised shapes)

**`HIST_PLAN_TABLE`**: one row per table per plan version. Answers "how many chunks, on which column".

| Column | Purpose |
|---|---|
| `PLAN_ID` | Plan identity. A new plan is a new row; old plans are never edited |
| `RUN_ID` | The planner run that produced it |
| `DATABASE_NAME`, `SCHEMA_NAME`, `TABLE_NAME` | The Iceberg table |
| `SCD_TYPE` | `SCD1` / `SCD2`, from DDL or a CONFIG override |
| `CHUNK_METHOD` | `SINGLE` / `RANGE` / `KEY_HASH` |
| `CHUNK_COLUMN`, `CHUNK_COLUMN_TYPE` | The column dividing the chunks, and its data type |
| `HASH_KEY_COLUMNS` | For `KEY_HASH` only |
| `PROFILED_AT` | Exact timestamp the profile was taken. The loader can read the table `AT` this time for counts that match |
| `TOTAL_ROWS`, `TOTAL_BYTES`, `COLUMN_COUNT`, `AVG_ROW_BYTES` | Profile results |
| `CHUNK_COUNT`, `TARGET_BYTES_PER_CHUNK` | Result, and the target the chunks were cut to |
| `CANDIDATES_EVALUATED` (`VARIANT`) | Each candidate's NULLs, distinct count, min/max, pruning ratio, and why it was or wasn't chosen |
| `IS_ACTIVE` | Exactly one active plan per table |
| `PLAN_STATUS` | `PLANNED` / `PLAN_FAILED` / `SUPERSEDED` |
| `ERROR_MESSAGE`, `PLANNED_AT` | Audit |

**`HIST_PLAN_CHUNK`**: one row per chunk. Answers "the size and range of each chunk".
Key: `(PLAN_ID, CHUNK_SEQ)`.

| Column | Purpose |
|---|---|
| `PLAN_ID`, `CHUNK_SEQ` | Identity and order |
| `CHUNK_TYPE` | `RANGE` / `NULL_VALUES` / `HASH` / `ALL` |
| `RANGE_START_TS`, `RANGE_END_TS` | For date/timestamp columns |
| `RANGE_START_NUM`, `RANGE_END_NUM` | For numeric columns |
| `HASH_BUCKET`, `HASH_MODULUS` | For `KEY_HASH` |
| `ESTIMATED_ROWS`, `ESTIMATED_BYTES` | Chunk size. Rows are exact as of `PROFILED_AT`; bytes = rows × `AVG_ROW_BYTES` (compressed-size estimate) |
| `STATUS` | The planner writes `PENDING`; the loader owns every later value. Kept because the original requirement asked for status fields and because re-planning checks it (F2) |

**Range semantics**: written once in the table comment and in this document; never as SQL:
- A row belongs to a chunk if `value >= start AND value < end` (half-open).
- `start` is NULL on the first chunk and `end` is NULL on the last, meaning unbounded.
- If the column has NULLs, they get their own `NULL_VALUES` chunk.

**`HIST_PLAN_RUN`**: one row per planner execution. Holds:
- the inputs as given (`P_DATABASE`, `P_SCHEMA`, `P_TABLES` raw string, `P_FORCE_REPLAN`) and the resolved
  table list (`VARIANT`);
- the user and role, and start and end time;
- counts of tables in scope, planned, skipped and failed;
- run status: `RUNNING` / `COMPLETED` / `COMPLETED_WITH_ERRORS` / `FAILED_VALIDATION` / `ABORTED`.

**`HIST_PLAN_CONFIG`**: `SCOPE` (`*` or `db.schema.table`), `TARGET_BYTES_PER_CHUNK`, `MAX_ROWS_PER_CHUNK`,
`SMALL_TABLE_BYTES`, `PROFILE_GRAIN`, `MIN_PRUNING_RATIO`, `MAX_HASH_BUCKETS`.
Per-table overrides: `FORCE_METHOD`, `FORCE_CHUNK_COLUMN`, `FORCE_SCD_TYPE`.

---

## 7. Findings on the design (planner scope)

### F1 — Critical: ranges must cover every row exactly once

- Use **half-open ranges**, where chunk *n*'s end is chunk *n+1*'s start. A range read with `BETWEEN`
  double-counts boundary values, or leaves sub-second gaps on timestamps.
- **Open-ended first and last chunks.** The design takes start and end from the observed minimum and
  maximum, so rows added outside those values after planning would fall in no chunk.
- Count **NULLs** in the chosen column and put them in their own chunk. Never drop them.
- **Invariant check before writing**: Σ chunk `ESTIMATED_ROWS` = `TOTAL_ROWS`. If it fails, the table is
  `PLAN_FAILED`.

### F2 — Critical: re-planning must not rewrite a plan the loader may be using

The design's `MERGE` keyed on `(table, CHUNK_SEQ)` has two failure modes:
- It rewrites chunk boundaries under the same sequence numbers. A loader that has already loaded old
  chunk 3 would then see a different chunk 3, and rows are duplicated or lost.
- When the new plan has fewer chunks, old higher-numbered chunks are left behind.

**Fix:**
- Every plan is a new `PLAN_ID`. Chunk rows are insert-only. The old plan is marked `SUPERSEDED` and
  `IS_ACTIVE` moves to the new one.
- The planner **refuses** to supersede a plan if any of its chunks has a `STATUS` other than `PENDING`,
  unless `FORCE_REPLAN` is set.
- Each table's writes happen in one explicit transaction, so a failure can't leave half a plan.
- Drop the row-growth staleness rule. The design itself notes the row count it relies on can be stale for
  Iceberg tables. `PROFILED_AT` plus explicit re-plans is simpler and exact.

### F3 — Important: profile in one pass and cut with window functions

- Collect every candidate's NULLs, min/max and distinct count in **one scan** (§8.1 sketch). Then run one
  fine-grained density pass on the chosen column (§8.2).
- Cut the chunks set-based: a running sum of rows per bucket, then `FLOOR(rows_before / target)`. This
  removes the month→day recursion and `MAX_BUCKET_OVERAGE_MULTIPLE`.
- Default `PROFILE_GRAIN` to `HOUR` (configurable). If history landed over a few days, `MONTH` would put a
  whole table in one bucket.
- Use the profile's own `COUNT(*)` as the row total. `ICEBERG_TABLE_FILES` row counts don't subtract
  row-level deletes, so use them only for the cheap small-table test.

### F4 — Important: input validation details

- The full rules are in §5.3. Resolve names exactly through `INFORMATION_SCHEMA.TABLES`, which also has
  an `IS_ICEBERG` column. Never use `SHOW … LIKE`, which is case-insensitive and treats `_` as a wildcard.
- Iceberg tables written by Spark or Glue often have **lower-case, quoted** names. Use
  `IDENTIFIER(:var)` or quote names exactly in every dynamic statement.
- Set `TIMEZONE = 'UTC'` at the top of the block. `DATE_TRUNC` on `TIMESTAMP_LTZ` depends on it.

### F5 — Important: chunk size is an input, so fix the design's sizing details

- Size chunks by **bytes**, which evens out wide vs. narrow tables, and keep a row cap as a second guard.
  The design's CONFIG has rows only, although its recommendation says "rows or bytes".
- Column count belongs in the metadata for information. It drives no decision, so drop the
  "÷ columns" proxy.
- `MIN_ROWS_TO_CHUNK = 1M` is very low. Use a bytes threshold.
- The real target value comes from whoever runs the loads. The planner just reads it from CONFIG.

### F6 — Minor

- The design's "Status: no open questions left" no longer holds. The questions in §10 are open.
- The design's "two invocation paths (Task + `EXECUTE IMMEDIATE`)" tradeoff no longer applies. There is
  one path: the script, run from a Workspace.

---

## 8. SQL sketches (illustrative, not executed)

### 8.1 One-pass candidate profile

The block generates this from the candidate list. Shown here for two candidates.

```sql
SELECT COUNT(*)                                     AS total_rows,
       COUNT_IF(grs_refined_timestamp IS NULL)      AS c1_nulls,
       MIN(grs_refined_timestamp)                   AS c1_min,
       MAX(grs_refined_timestamp)                   AS c1_max,
       APPROX_COUNT_DISTINCT(grs_refined_timestamp) AS c1_ndv,
       COUNT_IF(row_effective_date IS NULL)         AS c2_nulls,
       MIN(row_effective_date)                      AS c2_min,
       MAX(row_effective_date)                      AS c2_max,
       APPROX_COUNT_DISTINCT(row_effective_date)    AS c2_ndv
FROM   <src_table>;
```

### 8.2 Density pass and cut, for a timestamp column

```sql
WITH density AS (
    SELECT DATE_TRUNC(:grain, <chunk_col>) AS bucket_start, COUNT(*) AS bucket_rows
    FROM   <src_table>
    WHERE  <chunk_col> IS NOT NULL
    GROUP  BY 1
),
cum AS (
    SELECT bucket_start, bucket_rows,
           COALESCE(SUM(bucket_rows) OVER (ORDER BY bucket_start
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS rows_before
    FROM   density
),
chunked AS (
    SELECT FLOOR(rows_before / :target_rows) AS chunk_no,
           MIN(bucket_start) AS first_bucket,
           SUM(bucket_rows)  AS est_rows,
           MAX(bucket_rows)  AS largest_bucket     -- splittability check
    FROM   cum
    GROUP  BY 1
)
SELECT ROW_NUMBER() OVER (ORDER BY chunk_no)                             AS chunk_seq,
       IFF(ROW_NUMBER() OVER (ORDER BY chunk_no) = 1, NULL, first_bucket) AS range_start_ts,  -- NULL = unbounded
       LEAD(first_bucket) OVER (ORDER BY chunk_no)                        AS range_end_ts,    -- NULL on last chunk
       est_rows, largest_bucket
FROM   chunked;
```

`:target_rows` = `TARGET_BYTES_PER_CHUNK / AVG_ROW_BYTES`, capped at `MAX_ROWS_PER_CHUNK`. For a numeric
column, replace `DATE_TRUNC` with `WIDTH_BUCKET(<col>, :min, :max + 1, 10000)` and map the bucket edges back
to values.

### 8.3 Pruning probe (no data read)

```sql
EXPLAIN USING TABULAR
SELECT * FROM <src_table>
WHERE  <chunk_col> >= :slice_start AND <chunk_col> < :slice_end;   -- ~1/N slice from min/max
-- read partitionsAssigned / partitionsTotal from the TableScan row
```

---

## 9. Next steps, in order

1. **Workspace smoke test** (5 minutes): run a trivial `DECLARE … BEGIN … RETURN TABLE(…) END;` block in
   a Workspace. This confirms blocks and table results work there without `EXECUTE IMMEDIATE`.
2. **Reconnaissance (read-only)** on 5–10 tables, mixing SCD1/SCD2 and small/large:
   - `SHOW ICEBERG TABLES` (partitioned or not);
   - the §8.1 profile;
   - the §8.2 density pass on the landing timestamp, to see whether single values are huge;
   - the §8.3 probe, to confirm `EXPLAIN` reports pruning on Iceberg tables.

   This checks the §4.4 order against real data.
3. Then write the DDL for the four metadata tables, and the block with the §5 input contract.

---

## 10. Open questions

| # | Question | Why it matters |
|---|---|---|
| Q1 | Does the downstream loader need **all rows of a business key in one chunk** (e.g. it recomputes SCD2 dates or deduplicates)? | If yes, those tables need `KEY_HASH`, not ranges (§4.5) |
| Q2 | Which database and schema should hold the four metadata tables? A separate control schema, or the source schema? | Fixed location the block writes to; permissions |
| Q3 | What target chunk size will the loader team give, or should the planner start from a placeholder? | CONFIG default (F5) |
| Q4 | Do Zone1 SCD2 tables reliably use `row_effective_date` / `row_expiration_date` (and `is_del`)? Are key columns identifiable from DDL or a metadata list? | SCD detection (§4.3), and the key list for `KEY_HASH` |
| Q5 | Are Zone1 Iceberg tables partitioned? On what? | Whether candidate 1 in §4.4 ever applies |
| Q6 | Is "status" on the chunk table wanted at all, given the loader is out of scope? Or should the loader keep its own status table keyed on `(PLAN_ID, CHUNK_SEQ)`? | Ownership. The planner only needs status to protect against re-planning (F2) |
| Q7 | If one listed table name is wrong, should the run **fail as a whole** (recommended) or **plan the valid ones** and report the invalid ones? | §5.3 step 3 |
| Q8 | With no table list, should non-Iceberg tables in the schema be skipped and reported (recommended), or is the schema guaranteed to be Iceberg-only? | §5.3 step 4 |

---

## 11. What was verified, and how

| Claim | Basis |
|---|---|
| Snowsight runs `DECLARE … BEGIN … END` blocks directly; SnowSQL/CLI need `EXECUTE IMMEDIATE` | Snowflake "Understanding blocks in Snowflake Scripting" (via search extract). **Workspaces assumed to behave like Snowsight worksheets**; smoke test in §9 |
| Session variable string values are limited to 256 bytes | Snowflake "SQL variables" / `SET` docs (via search extract) |
| Snowflake Scripting supports `ARRAY` / `VARIANT` variables; `RETURN TABLE(…)` from a block | Snowflake Scripting docs (via search extract); the second is covered by the smoke test |
| IDMC uses `$$name` for its own parameters (relevant only if IDMC comes back) | Informatica/Snowflake migration docs (via search extract) |
| `EXPLAIN` returns `partitionsTotal` / `partitionsAssigned` without executing | Snowflake `EXPLAIN` docs (via search extract). **Not verified on Iceberg tables** |
| `STATEMENT_TIMEOUT_IN_SECONDS` default is 2 days, lowest level wins | Search extract citing Snowflake docs |
| `SHOW … LIKE` is case-insensitive with wildcards; `IS_ICEBERG` exists | Snowflake docs / BCR 2023_08 (via search extract) |
| Iceberg file-level row counts exclude row-level deletes | Snowflake Iceberg docs and release notes (via search extract) |
| `GRS_REFINED_TIMESTAMP` on every Zone1 table; SCD2 column naming | `../w2-abc-framework/reference.md` (from KT transcripts; to confirm, Q4) |
| All SQL in §8 | Written for this review, **not executed** |

`docs.snowflake.com` and Informatica's documentation pages were not directly fetchable from this
environment. The claims above rely on search-result extracts of the official pages.
