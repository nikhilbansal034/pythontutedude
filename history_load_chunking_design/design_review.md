# Architecture review — Iceberg → native historical load chunking

**Revision 2 — 2026-10-05.** Revised after answers on the four points below. Revision 1 assumed the load runs
inside the ABC framework. That assumption was wrong, and §2 lists what it changed.

Reviewed: `solution_design.md` (this folder). Cross-checked against current Snowflake docs. The ABC reference
(`../w2-abc-framework/reference.md`) is used **only for facts about the Zone1 tables themselves**, not for
how the load runs.

---

## 0. Verdict

The design's core is sound and stays: a planner that profiles each table, chunks by data volume, and writes
descriptors to a control table that a separate executor reads. Four things still need to change before
building:

1. **Settle the load type first: plain copy or transform.** If the target is a 1:1 copy of the Iceberg
   table, each chunk is a plain `INSERT … SELECT` into an empty table. `MERGE` is unnecessary, and so is any
   ordering between chunks, for SCD1 and SCD2 alike (§4, C1). That is the simplest and safest build, and
   everything below assumes it unless stated otherwise.
2. **Choose the chunk column from each table's structure plus a cheap profile, not from a single
   heuristic.** §5 gives the decision procedure. SCD1 vs SCD2 matters here for *which columns are safe to
   chunk on* (a mutable column such as `row_expiration_date` must never be used), not for how the copy
   works.
3. **Fix the correctness gaps that hold regardless of ABC**: chunk boundaries that leave gaps or overlaps
   (C3), a re-plan rule that can double-load or drop rows (C4), and a cut-off that defines exactly which
   rows count as "history" (C2).
4. **Build it as an anonymous Snowflake Scripting block, run on demand.** Leave the Task out unless the client
   confirms it, because a Task can't receive the session-variable parameters (C5).

---

## 1. Requirement as understood, with the answers received

- **Leg in scope**: Zone1 Snowflake Iceberg tables → Snowflake native tables, historical data only.
- **Deliverable**: a planner that, per Iceberg table, analyses its structure and data, picks a chunking
  approach, and writes the matching entries to a metadata table: parent table, chunk column, start/end,
  size, status/audit. The extraction query per chunk belongs to the execution layer.

| # | Question | Answer (2026-10-05) | Effect |
|---|---|---|---|
| 1 | Inside or outside ABC? | **Outside ABC** | Revision 1's ABC-based findings are withdrawn (§2). This solution now owns its own reconciliation, restart and cut-off |
| 2 | SCD type of source tables | **Both SCD1 and SCD2.** Decide chunking from the table's DDL | New §5: structure-driven chunk decision |
| 3 | Stored procedure constraint | **Anonymous Scripting blocks allowed.** Tasks still to be confirmed | C5: design for an on-demand block, with no Task dependency |
| 4 | Why `MERGE`? | "Analyse the source, decide chunking, write the metadata entry" | Agreed: no `MERGE` for a copy into an empty target (C1). One precondition still needs confirming (Q1) |

---

## 2. What changed from revision 1

| Rev 1 finding | Status | Why |
|---|---|---|
| C1 — must integrate with ABC `'H'` | **Withdrawn** | The load runs outside ABC |
| C2 — chunk column must be the ABC audit/UTC column | **Restated** (§5) | The UTC rule existed for ABC's windows. For a copy, any column that splits the rows cleanly is correct. Which one is best becomes a question of distribution and pruning |
| C3 — boundaries must tile the window | **Kept**, reframed | There is no ABC window. Boundaries must still have no gaps and no overlaps, and must cover the whole cut-off scope (C2, C3 below) |
| C4 — re-planning creates overlaps/orphans | **Kept** | Not ABC-related |
| C5 — parallel time chunks unsafe for SCD2 `MERGE` | **Withdrawn for a 1:1 copy** | That hazard needs a `MERGE` that derives one version from another. An `INSERT` copy has neither, so chunks are independent. It only comes back if the load transforms (C1) |
| C6 — Task + session variables | **Kept**, narrowed | Anonymous blocks are allowed. The Task question is still open |
| I3 — sizes too small due to ABC per-run overhead | **Softened** | Only the IDMC per-chunk overhead remains. Calibration still decides the number |

Your question 4 was the right challenge. My revision 1 brought in `MERGE` because ABC's job load uses one,
and that does not apply here.

---

## 3. Keep these from the design

- The planner and executor are separate and talk only through the control table, which holds descriptors
  and no SQL.
- Chunks are sized by data volume, not by calendar period.
- Small tables get one chunk.
- Each table's planning is isolated, and a failed table is marked retryable.
- `IN_PROGRESS` / `DONE` rows are never overwritten.
- The chunk size target comes from a calibration run, not a borrowed industry number.
- Planning runs on its own warehouse.

---

## 4. Findings

### C1 — Critical: decide "plain copy" vs "transform" before anything else

It is unclear whether the native target is a **1:1 copy** of the Iceberg table (same columns, same rows), or
a **remodelled** table that needs derived columns, deduplication or computed expiry dates.

**If it's a 1:1 copy into an empty target (recommended, and assumed below):**
- Each chunk is `INSERT INTO native SELECT … FROM iceberg WHERE <chunk predicate>`. No `MERGE`.
- Chunks are independent, so they can run **in any order and in parallel**, for SCD1 and SCD2 alike.
  Splitting one key's SCD2 versions across chunks is harmless, because each row is copied as-is.
- **Re-running a chunk safely**: a failed `INSERT` commits nothing, so retrying is just re-running it. The one
  dangerous case is an `INSERT` that committed but whose status update failed. Make the executor's chunk
  load `DELETE FROM native WHERE <chunk predicate>; INSERT …` in one transaction. Delete-then-insert also
  stays eligible for full PDO, where an upsert would not (the design's own PDO finding).
- Per-chunk reconciliation becomes exact. Compare `COUNT(*)` and `HASH_AGG(*)` of the chunk predicate on
  source and on target. Equal values mean the chunk's content is identical, not just its row count.

**If the target is remodelled:** derived SCD2 columns (expiry from the next version, version numbers,
deduplication) need *all* of a key's rows together. Time-range chunks then break unless they run strictly
in order with a `MERGE`, which is revision 1's C5. In that case, chunk on a **hash of the business key** so
that each chunk holds whole keys (§5.4, method `KEY_HASH`).

**Also confirm**: is the target **empty** when the history load starts, and does anything else write to it
while history runs? Two examples would be an ABC incremental starting early, or a second tool. If something
does, a plain `INSERT` is no longer safe. (Q1, Q2)

### C2 — Critical: define the cut-off, meaning exactly which rows are "history"

ABC no longer defines a window, so this solution has to. Zone1 tables can keep receiving rows and updates
while history runs (DMigrator re-sends, Zone1 reruns). Without a fixed scope:
- chunk counts drift between plan time and load time, and
- rows that arrive late are either missed, or loaded twice: once by history and once by whatever
  incremental process takes over afterwards.

**Recommendation: pin each table to a snapshot.** Record `SNAPSHOT_TS` per table at plan time. Plan
**and** execute with `FROM <table> AT(TIMESTAMP => SNAPSHOT_TS)`. Snowflake supports Time Travel on Iceberg
tables, with a refresh caveat for externally-managed ones. This gives four things:
- every chunk reads the same immutable data;
- the plan's counts stay true;
- the chunk column can be *any* column, even one that changes later;
- the hand-off to the later incremental process is one precise timestamp per table.

Two things have to be true for this to work. The Iceberg snapshot must not be expired (by Zone1 snapshot
maintenance) before the load finishes, and Snowflake's retention period must cover the load's duration
(Q3). If pinning isn't possible, the fallback is a fixed upper bound on the landing timestamp
(`GRS_REFINED_TIMESTAMP <= cutoff`), recorded per table, with a contract that no in-scope row changes while
history runs.

### C3 — Critical: chunk boundaries must cover every row exactly once

- **Half-open ranges** `[start, end)`. Chunk *n*'s `end` equals chunk *n+1*'s `start`. Never use `BETWEEN`:
  boundary rows load twice, or fall into sub-second gaps.
- **Open-ended first and last chunks.** Store `start = NULL` on the first chunk and `end = NULL` on the
  last, and treat NULL as unbounded. Values below the profiled minimum or above the maximum then can't be
  lost. The snapshot or cut-off in C2 bounds the scope instead.
- **NULLs in the chunk column**: either choose a column with zero NULLs (§5 does this), or add one explicit
  `IS NULL` chunk (`CHUNK_TYPE = 'NULL_VALUES'`). Never drop them silently.
- **Plan-time invariant**, written to the plan header: Σ chunk rows = `COUNT(*)` at the snapshot.

### C4 — Critical: re-planning can double-load or drop rows

This is the same issue as revision 1, unchanged:
- `MERGE` keyed on `CHUNK_SEQ` keeps old `DONE` chunks and adds new chunks with different boundaries, which
  creates overlaps or gaps.
- A smaller new plan leaves old `PENDING` rows behind as orphans.
- The row-growth staleness test reads a row count that can be stale.

**Fix**:
- Give each plan a `PLAN_ID`, and make the plan immutable once any chunk has started.
- Allow re-planning only when nothing is `IN_PROGRESS` or `DONE`. It then runs as one transaction that
  retires the old plan and inserts the new one.
- Drop `STALENESS_GROWTH_PCT`. With C2, growth after `SNAPSHOT_TS` belongs to the incremental process by
  definition.

### C5 — Important: implementation as an anonymous block, with no Task dependency

- Anonymous blocks cover everything the planner needs: loops, `EXECUTE IMMEDIATE` dynamic SQL, `RESULTSET`,
  and exception handlers.
- Parameters arrive as **session variables** (`SET v_db = …;` then `$v_db` in `DECLARE`). That works when an
  operator or a client tool runs the block in its own session.
- **A Task cannot use them**, because a Task runs in its own session. If Tasks are ever allowed and wanted,
  read parameters from a small `PLAN_REQUEST` table instead, and use the same table for manual runs, so that
  there is one code path.
- **For a one-time historical load, a Task adds little.** Planning runs once per table, or a few times.
  Recommend operator-run (Snowsight/SnowSQL) or IDMC-run. Confirm whether the client's IDMC Snowflake
  connection can submit an `EXECUTE IMMEDIATE $$…$$` block; this has not been verified (Q5).
- Dynamic identifiers: use `IDENTIFIER(:var)` or careful quoting. Iceberg tables written by Spark or Glue
  often have **lower-case, quoted** column names.

### I1 — Important: profile in one pass, cut with window functions, drop the recursion

- Gather all candidate-column statistics for a table in **one scan** (§6.1). Then run one fine-grained
  density pass on the chosen column (§6.2).
- Cut chunks set-based: take a running `SUM` of rows per bucket, then `FLOOR(rows_before / target)`. No
  month→day recursion and no `MAX_BUCKET_OVERAGE_MULTIPLE`.
- `ICEBERG_TABLE_FILES` row counts don't subtract row-level deletes, so use them only for the cheap
  small-table test. The profile's own `COUNT(*)` is the source of truth.

### I2 — Important: the control table — separate the grains, and type the boundaries

- **Plan header**: one row per table per plan. Holds the chosen method and column, the *reason* it was
  chosen, the candidate statistics, the snapshot, the row count, the chunk count, status and error.
- **Chunk table**: one row per chunk. `PLAN_FAILED` belongs on the header, not as a fake chunk row.
- **Typed boundaries instead of `VARIANT`**: `START_TS/END_TS` for date/time columns, `START_NUM/END_NUM`
  for numbers, `HASH_BUCKET/HASH_MODULUS` for hash chunks. They are unambiguous for IDMC to bind, and avoid
  time-zone surprises from `VARIANT` timestamps. See §7.

### I3 — Important: chunk sizing

- Bytes per chunk normalises wide vs. narrow tables; keep a row cap as a second guard. The design's
  "rows ÷ columns" proxy feeds no decision and can go.
- **The real cost driver is pruning, not chunk count.** If the chunk predicate can't skip files, *every*
  chunk scans the whole table, so 50 chunks means roughly 50 full scans. Fewer, larger chunks are then
  much cheaper. §5 measures pruning before choosing.
- Calibrate on a real IDMC chunk run on a large table, at two sizes. `STATEMENT_TIMEOUT_IN_SECONDS`
  (default 2 days, unless lowered at account, user or warehouse level) is a hard ceiling to check, not a
  target.
- `MIN_ROWS_TO_CHUNK = 1M` is very low; a 1M-row copy is trivial. Use a bytes threshold, set after
  calibration.

### I4 — Important: reconciliation is part of this design

Outside ABC, nothing else will check completeness.
- At plan time, the C3 invariant.
- Per chunk, after load: source vs. target `COUNT(*)` and `HASH_AGG(*)` on the chunk predicate at
  `SNAPSHOT_TS` (C1).
- Per table, at the end: all chunks `DONE` and the totals match. SCD-specific checks too:
  - **SCD2**: open versions per key are ≤ 1 and match the source.
  - **SCD1**: key uniqueness matches the source.

### I5 — Minor

- **Input validation**: `SHOW … LIKE` is case-insensitive and treats `_` as a wildcard, so filter the
  results to an exact match. `SHOW TABLES` / `INFORMATION_SCHEMA.TABLES` carry `IS_ICEBERG`.
- Load chunks in chunk-column order, so the target's micro-partitions come out naturally clustered on that
  column.
- Set `TIMEZONE = 'UTC'` explicitly in planning and execution sessions, because `DATE_TRUNC` on
  `TIMESTAMP_LTZ` depends on it.
- The Status line in the design ("no open questions left") overstates readiness. The design's own PDO
  action items are still open.

---

## 5. Choosing the chunking approach from each table's structure

### 5.1 What SCD type does and does not change

| | SCD1 | SCD2 |
|---|---|---|
| Copy mechanics (1:1, `INSERT`) | Same | Same |
| Parallel-safe chunks | Yes | Yes |
| Natural candidate columns | Landing/audit timestamp, surrogate key, created date | Landing/audit timestamp, **`row_effective_date`**, surrogate key |
| **Columns that must NOT be the chunk column** | Columns updated in place (e.g. last-updated timestamp) | **`row_expiration_date`**, current/active flags, delete flags (`is_del`): all change when a version closes |
| Typical distribution | Recent-heavy if keyed on an update time | Effective dates spread across years: good for even chunks |
| Post-load validation | Key uniqueness | One open version per key, no overlapping intervals |

So SCD type mainly decides **which columns are eligible** and **which checks run afterwards**. The
chunking mechanism is the same for both. With snapshot pinning (C2), even the mutable-column rule becomes a
safety margin rather than a hard requirement. It still stays in the design as a rule.

**How to detect SCD type from DDL**: a table is SCD2 if it has both `row_effective_date` and
`row_expiration_date` columns, the naming used across this project. Otherwise treat it as SCD1. Let CONFIG
override per table, because naming may differ in Zone1 (Q6).

### 5.2 What makes a column a good chunk column

| # | Criterion | Why | How it's measured |
|---|---|---|---|
| 1 | **No NULLs** (or very few, with a NULL chunk) | Range predicates skip NULLs | `COUNT_IF(col IS NULL)` |
| 2 | **Splittable**: no single value holds more than the target chunk size | One value can't be split across chunks | Largest bucket in the density pass |
| 3 | **Prunes well**: a range on it skips most files | Otherwise every chunk is a full scan (I3) | `EXPLAIN` of a 1/N slice: `partitionsAssigned / partitionsTotal`. This is compile-time only; no data is read |
| 4 | **Immutable** | A row must not move between chunks | DDL rule from §5.1 |
| 5 | **Sortable type**: DATE / TIMESTAMP / NUMBER | Clean range semantics. Strings bring collation and length problems | `INFORMATION_SCHEMA.COLUMNS.DATA_TYPE` |

### 5.3 Candidate columns, in priority order

All of these can be read from the DDL (`INFORMATION_SCHEMA.COLUMNS` plus `partition_specs` from
`SHOW ICEBERG TABLES`):

1. **The Iceberg partition source column**, if it has a time or identity transform on a date or number.
   Pruning is guaranteed.
2. **The landing/audit timestamp** (`GRS_REFINED_TIMESTAMP`, or the DMigrator landing column). It exists on
   every Zone1 table and usually matches the order files were written in, so pruning is likely good.
   **Risk:** if DMigrator stamps one value per batch, a single value can hold hundreds of millions of rows
   and fail criterion 2. Reconnaissance will show whether that happens.
3. **SCD2 only: `row_effective_date`.** Well spread across years. It prunes only if files were written
   roughly in that order.
4. **A single-column numeric surrogate key**, if one exists.
5. **Any other DATE/TIMESTAMP column** not excluded by §5.1.

### 5.4 Decision procedure, per table

```
1. Size ≤ SMALL_TABLE_BYTES                       → SINGLE (one chunk, no predicate)
2. For each candidate in priority order:
      fails NULL / immutable / type rule          → next candidate
      EXPLAIN-probe pruning ratio                  (cheap, compile-time)
   Rank passing candidates: good pruning first, then distribution
3. Density pass on the best candidate:
      largest bucket ≤ target                     → RANGE on that column  (TS or NUM)
      else try finer grain once; still too big    → next candidate
4. No candidate passes                            → KEY_HASH on the business key / primary key columns,
                                                     few buckets (each bucket is a full scan)
5. Remodelled-target case (C1)                    → KEY_HASH regardless, so each chunk holds whole keys
```

Every decision goes in the plan header: the method, the column, and the candidates with their statistics
and pruning ratios. A reviewer can then see *why* a table was chunked the way it was, and override it in
CONFIG.

### 5.5 What the metadata entry looks like for each method

| Method | Boundary columns filled | Predicate the executor builds (not the planner) |
|---|---|---|
| `SINGLE` | none | no `WHERE`, only `AT(TIMESTAMP => SNAPSHOT_TS)` |
| `RANGE_TS` | `START_TS`, `END_TS` (NULL = unbounded) | `col >= START_TS AND col < END_TS` |
| `RANGE_NUM` | `START_NUM`, `END_NUM` (NULL = unbounded) | `col >= START_NUM AND col < END_NUM` |
| `NULL_VALUES` | none | `col IS NULL` |
| `KEY_HASH` | `HASH_BUCKET`, `HASH_MODULUS`, key column list in header | `MOD(ABS(HASH(k1, k2, …)), HASH_MODULUS) = HASH_BUCKET` |

---

## 6. SQL sketches (illustrative, not executed)

### 6.1 One-pass candidate profile

The block generates this from the candidate list. Shown here for two candidates.

```sql
SELECT COUNT(*)                                    AS total_rows,
       COUNT_IF(grs_refined_timestamp IS NULL)     AS c1_nulls,
       MIN(grs_refined_timestamp)                  AS c1_min,
       MAX(grs_refined_timestamp)                  AS c1_max,
       APPROX_COUNT_DISTINCT(grs_refined_timestamp) AS c1_ndv,
       COUNT_IF(row_effective_date IS NULL)        AS c2_nulls,
       MIN(row_effective_date)                     AS c2_min,
       MAX(row_effective_date)                     AS c2_max,
       APPROX_COUNT_DISTINCT(row_effective_date)   AS c2_ndv
FROM   <src_table> AT(TIMESTAMP => :snapshot_ts);
```

### 6.2 Density pass and cut, for a timestamp column

```sql
WITH density AS (
    SELECT DATE_TRUNC(:grain, <chunk_col>) AS bucket_start, COUNT(*) AS bucket_rows
    FROM   <src_table> AT(TIMESTAMP => :snapshot_ts)
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
           MAX(bucket_rows)  AS largest_bucket      -- splittability check (criterion 2)
    FROM   cum
    GROUP  BY 1
)
SELECT ROW_NUMBER() OVER (ORDER BY chunk_no)                                AS chunk_seq,
       IFF(ROW_NUMBER() OVER (ORDER BY chunk_no) = 1, NULL, first_bucket)    AS start_ts,  -- NULL = unbounded
       LEAD(first_bucket) OVER (ORDER BY chunk_no)                           AS end_ts,    -- NULL on last chunk
       est_rows, largest_bucket
FROM   chunked;
```

For a numeric column, replace `DATE_TRUNC` with `WIDTH_BUCKET(<col>, :min, :max + 1, 10000)` and map the
bucket edges back to values. The rest is unchanged.

### 6.3 Pruning probe (no data read)

```sql
EXPLAIN USING TABULAR
SELECT * FROM <src_table>
WHERE  <chunk_col> >= :slice_start AND <chunk_col> < :slice_end;   -- a ~1/N slice from min/max
-- read partitionsAssigned / partitionsTotal from the TableScan row
```

⚠️ `EXPLAIN` reporting these figures is documented for Snowflake tables in general. **It has not been
verified to report meaningful pruning on Iceberg tables.** Check this in reconnaissance; if it doesn't
work, measure pruning from the query profile of one small real query instead.

---

## 7. Control table shapes (revised)

**`HIST_LOAD_PLAN`**: one row per table per plan.

| Column | Purpose |
|---|---|
| `PLAN_ID`, `RUN_ID` | Plan identity; the planning execution that produced it |
| `DATABASE_NAME`, `SCHEMA_NAME`, `TABLE_NAME` | Source table |
| `SCD_TYPE` | `SCD1` / `SCD2`, detected from DDL or overridden in CONFIG |
| `CHUNK_METHOD` | `SINGLE` / `RANGE_TS` / `RANGE_NUM` / `KEY_HASH` |
| `CHUNK_COLUMN` / `HASH_KEY_COLUMNS` | What the predicate binds to |
| `SNAPSHOT_TS` | Scope pin (C2) |
| `SOURCE_ROWS`, `SOURCE_BYTES`, `CHUNK_COUNT` | Profile results; `SOURCE_ROWS` must equal the sum of chunk estimates |
| `CANDIDATES_EVALUATED` (`VARIANT`) | Statistics and pruning ratio per candidate: the audit trail for the decision |
| `PLAN_STATUS` | `PLANNED` / `PLAN_FAILED` / `SUPERSEDED` / `LOADING` / `COMPLETE` / `RECON_FAILED` |
| `ERROR_MESSAGE`, `PLANNED_AT`, `COMPLETED_AT` | Audit |

**`HIST_LOAD_CHUNK`**: one row per chunk. Key: `(PLAN_ID, CHUNK_SEQ)`.

| Column | Purpose |
|---|---|
| `PLAN_ID`, `CHUNK_SEQ` | Identity |
| `CHUNK_TYPE` | `RANGE` / `NULL_VALUES` / `HASH` / `ALL` |
| `START_TS`, `END_TS`, `START_NUM`, `END_NUM` | Typed half-open boundaries; NULL = unbounded |
| `HASH_BUCKET`, `HASH_MODULUS` | For `KEY_HASH` |
| `ESTIMATED_ROWS`, `ESTIMATED_BYTES` | From the profile |
| `STATUS` | `PENDING` / `IN_PROGRESS` / `DONE` / `FAILED` |
| `SOURCE_ROWS_ACTUAL`, `ROWS_LOADED`, `SOURCE_HASH`, `TARGET_HASH` | Reconciliation (I4) |
| `STARTED_AT`, `COMPLETED_AT`, `ERROR_MESSAGE`, `ATTEMPT_COUNT` | Execution audit |

**`HIST_LOAD_CONFIG`**: `SCOPE` (`*` or `db.schema.table`), `TARGET_BYTES_PER_CHUNK`, `MAX_ROWS_PER_CHUNK`,
`SMALL_TABLE_BYTES`, `PROFILE_GRAIN`, `MIN_PRUNING_RATIO`, `MAX_HASH_BUCKETS`. Optional per-table overrides:
`FORCE_METHOD`, `FORCE_CHUNK_COLUMN`, `FORCE_SCD_TYPE`.

---

## 8. Next steps, in order

1. Answer Q1–Q3. Each one can change the build.
2. **Reconnaissance (read-only)** on 5–10 representative tables, mixing SCD1 and SCD2, small and large:
   - `SHOW ICEBERG TABLES`: managed or external, partitioned or not;
   - the §6.1 profile;
   - the §6.2 density pass on the landing timestamp, to see whether a single DMigrator value is enormous;
   - the §6.3 probe, to confirm `EXPLAIN` pruning works on Iceberg.

   This shows whether the §5.3 priority order holds on real data.
3. Calibrate one real IDMC chunk run at two sizes on a large table, with the session log showing full
   pushdown.
4. Then write the DDL and the anonymous planning block.

---

## 9. Open questions

| # | Question | Why it matters |
|---|---|---|
| Q1 | Is the native target a **1:1 copy** of the Iceberg table (same columns, no derivation), or remodelled? | Decides plain `INSERT` + any-order chunks, versus key-hash chunks and possibly `MERGE` (C1) |
| Q2 | Is the target **empty** at the start, and does anything else write to it while history runs? | A plain `INSERT` is only safe if nothing else writes |
| Q3 | Can each table be pinned to a snapshot (`AT(TIMESTAMP)`) for the whole load? Is Zone1 snapshot expiry, and Snowflake's retention period, long enough? If not, what is the history cut-off column and value? | Scope and consistency (C2); the hand-off point to incrementals |
| Q4 | Rough volumes: table count, largest table rows/TB, acceptable total duration? | Chunk size, and whether `KEY_HASH` is ever worth its full scans |
| Q5 | Who runs the planner block: an operator in Snowsight/SnowSQL, or IDMC? Can IDMC's Snowflake connection submit an `EXECUTE IMMEDIATE $$…$$` block? And are Tasks allowed? | Parameter mechanism (C5) |
| Q6 | Do Zone1 SCD2 tables reliably use `row_effective_date` / `row_expiration_date` (and `is_del`), and are business key columns identifiable from DDL or metadata? | SCD detection (§5.1) and the `KEY_HASH` key list |
| Q7 | Are Zone1 Iceberg tables partitioned, and on what? | Whether candidate 1 in §5.3 ever applies |

---

## 10. What was verified, and how

| Claim | Basis |
|---|---|
| Time Travel works on Iceberg tables; externally-managed ones need refresh | Snowflake Iceberg docs (via search extract) |
| `EXPLAIN` returns `partitionsTotal` / `partitionsAssigned` from compile-time pruning, without executing | Snowflake `EXPLAIN` docs (via search extract). **Not verified for Iceberg tables** |
| `STATEMENT_TIMEOUT_IN_SECONDS` defaults to 172,800 s (2 days), lowest level wins | Search extract citing Snowflake docs |
| An anonymous block counts as one statement for `EXECUTE IMMEDIATE`; `RESULTSET` and dynamic SQL are supported | Snowflake `EXECUTE IMMEDIATE` / `RESULTSET` docs (via search extract) |
| `SHOW … LIKE` is case-insensitive with `%`/`_` wildcards; `IS_ICEBERG` column exists | Snowflake docs / BCR 2023_08 (via search extract) |
| Iceberg file-level row counts exclude row-level deletes; Snowflake reads positional deletes and deletion vectors | Snowflake Iceberg docs and release notes (via search extract) |
| `GRS_REFINED_TIMESTAMP` on every Zone1 table; `row_effective_date` / `row_expiration_date` naming | `../w2-abc-framework/reference.md` (from KT transcripts; Zone1 naming still to confirm — Q6) |
| Session variables don't reach a Task's session | Reasoning from session scoping. **Not doc-verified.** Test with a one-line Task if Tasks come into play |
| All SQL in §6 | Written for this review, **not executed** |

`docs.snowflake.com` was blocked to direct fetch from this environment, so the Snowflake claims rely on
search-result extracts of the official pages.
