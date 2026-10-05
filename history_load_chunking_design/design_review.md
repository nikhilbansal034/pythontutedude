# Architecture review — Iceberg → native historical load chunking

Reviewed: `solution_design.md` (this folder), 2026-10-05.
Reviewed against: the design itself, the ABC framework reference (`../w2-abc-framework/reference.md`), the
W3 constraints (`../w3-scd-effective-date-split/solution_design.md` §1), and current Snowflake docs where
they could be reached (see §9 for what was and was not verified).

---

## 0. Verdict in one paragraph

The chunking *algorithm* is sound in spirit: adaptive, volume-aware ranges, a small-table short-circuit,
per-table failure isolation, and a descriptor-only control table. The *solution* has a bigger problem. It is
designed as if this were a standalone Iceberg→native copy, and it never mentions the ABC framework. Per the
ABC reference, a historical load is ABC execution type **`'H'`**. It has a fixed sourcing window
(`1900-01-01` → `MAX(GRS_REFINED_TIMESTAMP)`), it runs through ABC's job load (source qualifier with full PDO
→ stage → `MERGE` into an SCD2 target), and ABC has its own run, restart, count and reconciliation semantics.
Once you look at it in that context, five of the design's decisions change: the driver column, the chunk
boundaries, the re-plan rule, whether chunks can run in parallel, and how the planner runs at all (Task plus
session variables). The good news is that the ABC context also **removes most of the design's complexity**.
Because the chunk column is a known audit/watermark column, there is nothing to auto-detect from partition
specs, no month→day recursion, and no need for Snowflake Scripting.

**Recommendation:** keep the overall shape (plan → control table → IDMC executes). Rework it per §2 and
§3 below. Resolve the questions in §8 before writing DDL.

---

## 1. What the design is solving (my understanding, for confirmation)

- **Leg in scope**: Zone1 Snowflake Iceberg tables → Zone2 Snowflake native tables, for the one-time
  historical load. Teradata → Zone1 is DMigrator's job and out of scope.
- **Deliverable**: a *planner* that profiles each Iceberg table (rows, bytes, columns) and writes chunk
  descriptors to a control table: parent table, chunk column, start/end, size, status/audit. The
  extraction query per chunk is built by the execution layer, not the planner.
- **Constraints already recorded**: IDMC with PDO executes the load. No persistent stored procedure.
  Re-runs must be idempotent. One bad table must not kill the run.
- **Implicit but not stated in the design, from the ABC reference**:
  - The historical load is ABC `batch_rerun_flag = 'H'`, which is **not built yet** (§11 of the reference).
  - Its window is `1900-01-01` → `MAX(GRS_REFINED_TIMESTAMP)` across the batch's tables, taken from
    `batch_run_stats`. `etl_data_ingestion_source_window` is **not** used.
  - Extraction is always keyed on **UTC audit fields, never business dates**. DMigrator adds a UTC landing
    column for history.
  - Historical runs about 10 days, then a catch-up load covers the days that passed during it.
  - Job load is source qualifier (dedup, `LEAD`-derived `row_expiration_date`, hashing) → stage → `MERGE`.

If any of these "implicit" points is wrong for this workstream (for example, history is deliberately being
loaded *outside* ABC), several findings below soften. That is question Q1 in §8.

---

## 2. What is solid — keep it

| Decision | Why it's right |
|---|---|
| Planner and executor separated by a control table | Correct seam. Lets IDMC stay the executor and keeps the planner restartable |
| Descriptors only, no SQL in the control table | Avoids SQL injection and stale-SQL problems, and keeps IDMC mappings as the single owner of query logic |
| Adaptive volume-aware chunks over flat calendar chunks | Historical volume is never flat. Equal-width ranges would give badly skewed chunks |
| Small-table short-circuit | Reference/static tables need no special handling (the threshold value is wrong, see §3.3) |
| Per-table exception isolation with a retryable failed state | Exactly the right failure granularity for a schema-wide run |
| Never overwrite `IN_PROGRESS` / `DONE` | Right instinct. The implementation is not enough on its own (see §3, C4) |
| PDO kept over a bypass of IDMC | Agreed. ABC depends on full PDO (reference §3), so bypassing IDMC would bypass ABC |
| Calibrating chunk size empirically instead of borrowing a number | Agreed. What gets measured has to change (see §3.3) |
| Separate planning warehouse | Fine, and cheap to do |

---

## 3. Findings

Severity: **Critical** means it will produce wrong data, or a design that cannot be deployed as written.
**Important** means it works but costs real money or time, or makes operations harder. **Minor** means
clean-up.

### C1 — Critical: the design sits outside the ABC framework

**What the design says**: CONTROL drives an IDMC/PDO mapping that runs
`INSERT ... SELECT ... WHERE period BETWEEN :start AND :end` per chunk.

**What actually executes a Zone1→Zone2 load**: ABC job load. That means job preload, then the source
qualifier (dedup, parent lookup, hash, `row_expiration_date` via the next version), then stage, then
`MERGE`, then post-load counts, balance reconciliation and Aurora write-back. Each run is tracked in
`batch_run_stats` / `job_run_stats` with restart semantics (restart auto-cleans the target; a non-empty
stage table skips source→stage).

**Why it matters**:
- If each chunk is *its own* ABC run, chunk count multiplies the per-run ABC overhead: preload,
  DQ rules, count checks, reconciliation, Aurora write-back. That pushes chunk size up a lot (§3.3).
- If chunks are *inside* one ABC `'H'` run, ABC's run-level restart and count logic has to understand
  chunks, and today it does not.
- Either way, the control table has to align with ABC, not run as a second, parallel control plane.
  Today ABC metadata lives in Aurora with Snowflake copies only where full PDO needs them (reference §3).
  The chunk table follows that same rule: it lives in Snowflake **because** the PDO source qualifier must
  join it, exactly as `etl_data_ingestion_source_window` does.

**Recommendation**: model each chunk as a **sub-window of the `'H'` batch window**. The cleanest fit is
for the job-load source qualifier to read `[chunk_start, chunk_end)` from the chunk table in the same way it
reads `sourcing_start_datetime` / `sourcing_end_datetime` from the source-window table for incrementals.
That keeps the mapping change to one join. Then decide with the ABC owners (Swayam, per the reference)
whether a chunk is a job run or a step within one. This is Q1–Q3.

### C2 — Critical: the chunk column must be the ABC watermark/audit column, not a detected partition or business date

**What the design says**: take the driver column from the Iceberg partition spec
(`year`/`month`/`day`/`hour` transform). Otherwise use the single DATE/TIMESTAMP column. Otherwise use a
key range.

**Problems**:
1. ABC's rule is that extraction is keyed **on audit fields, never on business data fields**, and that
   every audit field is UTC (reference §1, "Time zones"). A partition column or a "single date column"
   will usually be a business date: native source time zone, no conversion. That breaks the window
   arithmetic and can disagree with the `'H'` window by hours.
2. The heuristic "exactly one DATE/TIMESTAMP column" almost never holds. Zone1 tables carry
   `GRS_REFINED_TIMESTAMP`, the DMigrator landing column, `row_effective_date`, `row_expiration_date` and
   business dates. Most tables would fall through to the key-range path.
3. The reference says the job-load **watermark column varies by table** ("this keeps changing"). That
   argues for an *explicit, configured* column per table (in metadata), not runtime inference.
4. Partition-spec parsing (`source-id` → column name, spec evolution, `identity` vs time transforms) is the
   riskiest code in the design. It becomes unnecessary.

**Recommendation**: the chunk column is the column the `'H'` window filters on, which is
`GRS_REFINED_TIMESTAMP` or the DMigrator UTC landing column (Q4). Read it from ABC metadata or CONFIG
per table. Do not detect it. Two consequences to plan for:
- **Pruning is probably good**: DMigrator writes files in landing order, so Parquet min/max statistics on
  the landing timestamp should line up with files. Verify this with the query profile on one table
  (partitions scanned vs. total) before relying on it.
- **Granularity**: twenty years of history that *landed* over a few days is extremely dense per day.
  `PROFILE_GRAIN = MONTH` would put the whole table in one bucket. Profile at **hour or minute** grain,
  configurable per table.

### C3 — Critical: chunk boundaries must tile the `'H'` window exactly — half-open, anchored, NULL-checked

**What the design says**: `START_VALUE` / `END_VALUE` taken from the first and last observed bucket, with
the executor applying `BETWEEN`.

**Problems**:
- **`BETWEEN` on timestamps double-counts or drops rows at the boundaries.** If chunk *n* ends at
  `2019-01-01 00:00:00` and chunk *n+1* starts there, `BETWEEN` loads boundary rows twice. If ends are
  set to "`23:59:59.999`", sub-millisecond values fall into gaps.
- **Boundaries taken from observed data leave the window edges uncovered.** Rows below the first bucket
  or above the last bucket, as seen at planning time, are never loaded. The `'H'` window is
  `1900-01-01` → `MAX(GRS_REFINED_TIMESTAMP)`, and the chunks must cover that window exactly.
- **NULLs in the chunk column are silently excluded** by any range predicate.

**Recommendation**:
- Every chunk is `[start, end)`. Chunk *n*'s `end` is chunk *n+1*'s `start`, by construction.
- Chunk 1's `start` is the window start. The last chunk's `end` is the window end, and its comparison
  must match whatever ABC's window predicate does (inclusive or exclusive). Confirm against the source
  qualifier (Q5).
- Planning precondition: `COUNT_IF(chunk_col IS NULL) = 0`. Otherwise the table goes to `PLAN_FAILED` with
  a clear message. Do not silently plan around NULLs.
- Planning invariant, written to the plan header: `SUM(chunk est_rows) = COUNT(*) within window`.

### C4 — Critical: re-planning as designed can create overlaps, gaps and orphan chunks

**What the design says**: `MERGE` keyed on `(db, schema, table, CHUNK_SEQ)`. It replaces
`PENDING`/`FAILED`/`PLAN_FAILED` rows, never touches `IN_PROGRESS`/`DONE`, and re-plans when row count has
grown by more than `STALENESS_GROWTH_PCT`.

**Failure scenarios**:
1. Table planned as 10 chunks. Chunks 1–4 are `DONE`. The table grows and gets re-planned into 12 chunks
   with **different** boundaries. Rows 5–12 are replaced, rows 1–4 are kept. New chunk 5 starts where the
   *new* plan's chunk 4 ends, not where the *old* chunk 4 ended. The result is overlap (duplicates) or a
   gap (lost rows).
2. Re-plan yields **fewer** chunks (8). `MERGE` updates rows 1–8, and old `PENDING` rows 9–10 are never
   matched, so they survive as orphans and load again.
3. Growth-based staleness doesn't fit `'H'` semantics anyway. Rows that arrive after the window's end
   belong to the **catch-up** load (`'C'`), not to a re-plan of history. Re-planning `'H'` because the
   table grew would pull catch-up data into history and double-load it.
4. `INFORMATION_SCHEMA.TABLES.ROW_COUNT` is the input to the staleness test, and the design itself notes it
   can be stale for externally-managed tables.

**Recommendation**:
- A plan is **immutable once any chunk starts**. Give each plan a `PLAN_ID` (or version) and key chunks on
  `(PLAN_ID, CHUNK_SEQ)`.
- Re-plan is allowed only when **no chunk of the current plan is `IN_PROGRESS` or `DONE`**. It is one
  transaction that retires the old plan and inserts the new one. Do not `MERGE` per row.
- Drop `STALENESS_GROWTH_PCT`. The window is fixed per `'H'` batch, and anything after it is catch-up.
  `FORCE_REPLAN` stays, subject to the same "nothing started" guard.
- Wrap each table's write in an explicit `BEGIN TRANSACTION … COMMIT` so a failure mid-write never leaves
  half a plan.

### C5 — Critical: running time-range chunks in parallel is unsafe for SCD2/MERGE targets

**What the design says**: "chunks are independent, non-overlapping period ranges, so multiple chunks —
even from different tables — can run concurrently … with zero coordination."

That holds only for an **append-only** target. Zone2 targets are SCD2, loaded by `MERGE`. The job-load
source qualifier derives `row_expiration_date` from the **next version of the same business key**
(reference §9, 4.1). If a key's versions fall into different time chunks:
- **Sequential, in time order**: works. It is exactly what daily incrementals already do: the next chunk's
  `MERGE` expires the version the previous chunk left open.
- **Parallel or out of order**: two `MERGE`s race on the same key's timeline. You get two open versions,
  or an expiry computed against a version that is not there yet. This is the same class of defect the W3
  POC found (W3 §17).

**Recommendation**: make the execution contract explicit in the control table.
- Within one table, chunks run **strictly in `CHUNK_SEQ` order**, and chunk *n+1* is eligible only after
  chunk *n* is `DONE`. Parallelism comes from **across tables**, which is plenty when there are many tables.
- If one huge table dominates wall-clock time and needs *intra-table* parallelism, the right tool is the
  option the design rejected: **hash buckets on the business key**
  (`MOD(ABS(HASH(<business_key>)), n)`). Each bucket holds a key's entire history, so buckets are truly
  independent. The cost is that each bucket scans the whole source with no pruning, so use few buckets
  (4–16), not hundreds. Treat it as an opt-in per table (`CHUNK_TYPE = 'KEY_HASH'`).
- The atomic-claim `UPDATE` in the design is only needed if several workers compete. If Stonebranch/IDMC
  drives each table's chunks sequentially, a simple "next `PENDING` by `CHUNK_SEQ` after the last
  `DONE`" lookup is enough.

### C6 — Critical: the Task-plus-session-variable mechanism doesn't work as described, and probably isn't allowed

1. **Session variables don't reach a Task.** `SET v_database = …` is scoped to the caller's session.
   A Task runs in its own session, so `$v_database` inside a Task body is undefined. The design's
   "same block for Task and ad-hoc" therefore needs two parameter mechanisms, not one.
2. **A Snowflake Task is a second scheduler.** Stonebranch owns scheduling and dependencies (reference §2).
   A Snowflake-side Task for "scheduled whole-schema runs" sits outside that and outside ABC's monitoring.
   It is also unclear why a one-time historical plan needs a schedule at all.
3. **The constraint may be stricter than recorded.** W3 records the client's rule as *"No stored
   procedures. SQL is embedded in the IDMC pipeline."* This design recorded "anonymous block / Task body
   acceptable". These are different readings, and the second needs written confirmation (Q6).

**Better option, now that C2 holds**: the chunk column is a *known, named* column, so the only dynamic
part is the **table name**. IDMC already substitutes table names through parameter files (reference §6).
Planning therefore becomes **one static, set-based SQL statement per table**, run by an IDMC
mapping/SQL task in a taskflow loop over the table list, with the table name as an IDMC parameter (sketch
in §5). No Scripting block, no Task, no session variables, no procedure. It also fits the stricter reading
of the constraint, and it puts planning under the same scheduler, monitoring and lineage as everything else.

Keep the Scripting anonymous block only as a fallback if the client confirms Snowflake-side procedural
code is acceptable *and* IDMC looping proves impractical. If you do keep it, drive it from a request table
(`INSERT` a request row, then the block processes open requests), not session variables. That is one
code path for both ad-hoc and scheduled runs.

### I1 — Important: replace the month→day recursion with one fine-grain pass plus a window-function cut

The greedy "walk buckets, cut when the running total crosses the target, recurse on oversized buckets"
needs procedural code and a second scan per oversized bucket. A set-based equivalent:

1. Profile **once** at the finest grain you will need (hour or minute, per C2).
2. `rows_before = SUM(rows) OVER (ORDER BY bucket ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)`.
3. `chunk_no = FLOOR(rows_before / target_rows)`.

Each chunk is ≤ `target + one bucket`, which is fine-grained enough that `MAX_BUCKET_OVERAGE_MULTIPLE` and
the recursion both go away. Sketch in §5.

### I2 — Important: split the control table by grain, and type the boundaries

- **Two grains are mixed in CONTROL.** `PLAN_FAILED` is a *table-level* outcome stored as a fake chunk row.
  Use a **plan header** (one row per table per plan: plan id, window, chunk column, row count, chunk
  count, plan status, error, invariant check) and a **chunk table** (one row per chunk). Re-plan guards,
  failure reporting and reconciliation all get simpler.
- **`VARIANT` for start/end is a poor fit for IDMC.** It brings timestamp/time-zone round-tripping
  surprises, needs a cast on every read, and adds friction with IDMC parameter binding. With C2, the
  boundaries are **always UTC timestamps**, so use `CHUNK_START_TS` / `CHUNK_END_TS TIMESTAMP_NTZ`. If
  the `KEY_HASH` option (C5) is used, add `HASH_BUCKET` / `HASH_MODULUS NUMBER`. These are typed, nullable
  and self-describing.
- Add `PLAN_ID`, `BATCH_RUN_ID` / `EXECUTION_RUN_ID` (link to ABC), and `ACTUAL_SOURCE_ROWS` next to
  `ROWS_LOADED` so per-chunk reconciliation has both sides.

### I3 — Important: the chunk-size defaults are probably far too small, and the size model is inconsistent

- **Inconsistency**: the Recommendation section says "rows **or bytes**, whichever binds first", but
  CONFIG only has `TARGET_ROWS_PER_CHUNK`. Pick one. Bytes (via `avg_row_bytes`) normalises wide vs.
  narrow tables, which is what the column-count discussion was trying to achieve. A row cap can stay as a
  secondary guard.
- **Drop the "bytes ÷ rows ÷ columns" proxy.** Bytes per row is the useful number. Dividing by column count
  doesn't feed any decision.
- **`MIN_ROWS_TO_CHUNK = 1M` and `TARGET = 10M` will over-chunk badly.** A 1M-row table is trivial for
  Snowflake. If every chunk carries ABC per-run overhead (C1) *and* a `MERGE` against an ever-growing
  target, then a 5B-row table at 10M per chunk means **500 sequential ABC runs**. Expect the right numbers
  to be an order of magnitude or more higher. Let calibration decide, but start the calibration higher.
- **Calibrate the real thing**: time a full ABC job run per chunk (preload → SQ → stage → `MERGE` → post
  load), not a bare `INSERT … SELECT`. Measure at two sizes and on the **largest target table late in its
  load**. `MERGE` cost grows with target size, so the first chunks are the fastest and the least
  representative.
- **Choose the right objective.** The `'H'` run took about 10 days in both KT timelines, and every day it
  runs is a day the catch-up load must cover. Optimise **total wall-clock time of the `'H'` batch**, under a
  ceiling on **blast radius** (how much is redone on a failed chunk). A per-chunk runtime target of
  "10–20 minutes" is a means, not the objective.

### I4 — Important: profiling inputs — use the density scan as the source of truth

- `ICEBERG_TABLE_FILES.ROW_COUNT` is per data file and does **not** subtract row-level deletes. Snowflake
  reads positional deletes / deletion vectors on Iceberg tables. Treat it as an estimate only.
- For any table that gets a density scan, `SUM(bucket_rows)` **is** the exact in-window row count. Use that
  and skip the separate `INFORMATION_SCHEMA.TABLES` → `ICEBERG_TABLE_FILES` cross-check chain. Keep
  metadata counts only for the cheap small-table decision.
- Check whether Zone1 tables are **Snowflake-managed** Iceberg (reference §2 says so) or Glue/externally
  managed (reference §1 mentions Glue). Snowflake-managed tables don't have the
  refresh/stale-metadata problem the design spends effort on (Q7).

### I5 — Important: input validation details

- `SHOW … LIKE '<name>'` is **case-insensitive**, and `_` / `%` are wildcards. `SHOW TABLES LIKE 'POL_TXN'`
  also matches `POLXTXN`. Filter the result for an exact name afterwards, or validate with
  `INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = :t` instead.
- `INFORMATION_SCHEMA.TABLES` / `SHOW TABLES` carry an **`IS_ICEBERG`** column. One query answers "exists"
  and "is Iceberg" together, and still lets you give two separate error messages.
- Identifiers created by Spark/Glue are often **lower-case**, which means quoted, case-sensitive
  identifiers in Snowflake. Every dynamic reference needs `IDENTIFIER()` or correct quoting. Test one
  lower-case table explicitly.

### I6 — Important: reconciliation is missing as a first-class step

The design has `ESTIMATED_ROWS` and `ROWS_LOADED` but no completeness check. Add:
- **At plan time**: Σ chunk rows = in-window `COUNT(*)` (C3 invariant).
- **Per chunk**: source rows in `[start, end)` vs. rows staged vs. rows merged. Hook this into ABC's
  `job_run_stats` counts and balance reconciliation, not a parallel mechanism.
- **Per table, at the end**: all chunks `DONE` and Σ `ROWS_LOADED` agrees with the plan, before the table
  is declared complete and catch-up may start.

### I7 — Important: consider read consistency

If anything can rewrite Zone1 rows *inside* the `'H'` window while history runs, chunk counts drift between
plan and execution. Example: a Zone1 rerun changes `GRS_REFINED_TIMESTAMP` (reference §11.4). Two options:
confirm that Zone1 is frozen for in-window data during `'H'` (simplest), or pin reads with
`AT(TIMESTAMP => plan_ts)`. Iceberg tables support Time Travel; for externally-managed tables, this needs
periodic refresh and only reaches snapshots that still exist. Q8.

### M1 — Minor

- The rationale for rejecting hash bucketing ("ordered historical backfill, not parallel") is wrong in
  this context. It is the *only* parallel-safe option for SCD2 targets (C5).
- `NTILE` / `ROW_NUMBER` key-range fallback needs a full sort of the table. If it is kept at all, use the
  same cumulative-count trick (I1) over a numeric key's distinct values or approximate percentiles. With C2
  it should be rarely or never reached, since every Zone1 table has the audit column.
- Load chunks in chunk-column order. Native micro-partitions then come out naturally clustered on the
  load timestamp, at no automatic-clustering cost. Decide the target's clustering key (if any) before the
  load, not after.
- Set the session `TIMEZONE = 'UTC'` explicitly in planning and execution connections. The account is UTC
  per the reference, but IDMC runs in EST, so don't rely on defaults.
- The **Status** line ("No open questions left") overstates readiness. The design's own PDO action items
  (connector type, full-PDO proof on an Iceberg source, no-upsert check) are still open, and the
  `MERGE`-based ABC stage→target is already documented as **not** full PDO (reference §3).

---

## 4. Proposed revised flow

```
ABC 'H' batch_run_stats row (window: 1900-01-01 → MAX(GRS_REFINED_TIMESTAMP))
        │
        ▼
IDMC taskflow — PLAN (once per table, table name as IDMC parameter)
  validate → NULL check on chunk col → fine-grain density scan (one pass)
  → window-function cut → write PLAN_HEADER + CHUNK rows in one transaction
        │
        ▼
Snowflake: PLAN_HEADER, CHUNK  (Snowflake-resident so the PDO source qualifier can join them)
        │
        ▼
IDMC/ABC job load — EXECUTE (per table: chunks strictly in CHUNK_SEQ order; tables in parallel)
  SQ filters chunk_col ∈ [chunk_start, chunk_end) → stage → MERGE → counts/recon → mark chunk DONE
        │
        ▼
Per-table completion check (Σ rows) → table DONE → catch-up 'C' may start
```

---

## 5. Sketch — set-based chunk planning for one table

Illustrative only, not run. `<src_table>`, `:win_start`, `:win_end`, `:target_rows` would be IDMC
parameters. The grain and chunk column come from CONFIG/ABC metadata. It assumes the last chunk is closed
at `:win_end`, so match this to ABC's window predicate (Q5).

```sql
WITH density AS (
    SELECT DATE_TRUNC('HOUR', grs_refined_timestamp) AS bucket_start,
           COUNT(*)                                  AS bucket_rows
    FROM   <src_table>
    WHERE  grs_refined_timestamp >= :win_start
      AND  grs_refined_timestamp <= :win_end
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
           MIN(bucket_start)                 AS first_bucket,
           SUM(bucket_rows)                  AS est_rows
    FROM   cum
    GROUP  BY 1
)
SELECT ROW_NUMBER() OVER (ORDER BY chunk_no)                                   AS chunk_seq,
       IFF(ROW_NUMBER() OVER (ORDER BY chunk_no) = 1, :win_start, first_bucket) AS chunk_start_ts,
       COALESCE(LEAD(first_bucket) OVER (ORDER BY chunk_no), :win_end)          AS chunk_end_ts,
       est_rows
FROM   chunked;
```

The boundaries tile the window with no gaps: each `end` is the next `start`, the first chunk starts at the
window start, and the last ends at the window end. Empty hours between buckets are absorbed automatically.
A table at or below the small-table threshold produces exactly one chunk if you set
`:target_rows` ≥ its row count.

---

## 6. Changes to the CONFIG / CONTROL shapes (summary)

| Change | Reason |
|---|---|
| Split CONTROL into `PLAN_HEADER` (per table per plan) and `CHUNK` (per chunk) | C4, I2 |
| Add `PLAN_ID`; key chunks on `(PLAN_ID, CHUNK_SEQ)` | C4 |
| `START/END_VALUE VARIANT` → `CHUNK_START_TS / CHUNK_END_TS TIMESTAMP_NTZ` (+ optional `HASH_BUCKET`, `HASH_MODULUS`) | I2, C5 |
| `CHUNK_TYPE` values: `WINDOW` (default), `KEY_HASH` (opt-in), `SINGLE` | C5 |
| Add `BATCH_RUN_ID` / `EXECUTION_RUN_ID` links to ABC | C1 |
| Add `ACTUAL_SOURCE_ROWS` next to `ROWS_LOADED` | I6 |
| CONFIG: add `CHUNK_COLUMN` (or read from ABC metadata), `PROFILE_GRAIN` default `HOUR`, `TARGET_BYTES_PER_CHUNK` | C2, I3 |
| CONFIG: remove `STALENESS_GROWTH_PCT`, `MAX_BUCKET_OVERAGE_MULTIPLE` | C4, I1 |

---

## 7. What I would do next, in order

1. Get answers to Q1–Q6. Q1 and Q6 can each invalidate a build.
2. **Reconnaissance SQL** (read-only, like W3's `90_data_reconnaissance.sql`). For a sample of Zone1
   tables: `SHOW ICEBERG TABLES` (managed vs. external; partitioned or not), NULL count on the chunk
   column, rows per hour on the chunk column (see the real density shape), and pruning efficiency of a
   one-hour filter in the query profile.
3. Calibrate one real ABC job run per chunk at two sizes, on the largest target, with full-PDO evidence
   from the session log.
4. Then write DDL and the planning SQL.

---

## 8. Clarifying questions

Ordered by how much the answer changes the design.

| # | Question | Why it matters |
|---|---|---|
| Q1 | Does this historical load run **through ABC** as `batch_rerun_flag = 'H'`, or deliberately outside it? | Decides whether chunks are ABC runs/sub-windows (C1) or a standalone pipeline |
| Q2 | Is each chunk meant to be **its own ABC job run**, or a step inside one `'H'` job run? | Per-run overhead and restart semantics drive chunk size (I3) |
| Q3 | Who owns the ABC change for `'H'` (it's "not built") — and is chunk support in that scope? | Without it, there is no executor for the plan |
| Q4 | For history, which column is the window filtered on: `GRS_REFINED_TIMESTAMP`, or the DMigrator UTC landing column? Is it the same on every table? | It becomes the chunk column (C2) |
| Q5 | Is ABC's window predicate `>= start AND <= end`, or `< end`? | The last chunk's boundary has to match it exactly (C3) |
| Q6 | Exactly what does the client's "no stored procedure" cover? Are anonymous Scripting blocks and Snowflake Tasks allowed, or must SQL be embedded in IDMC (as W3 records)? | Decides the implementation mechanism (C6) |
| Q7 | Are the Zone1 Iceberg tables Snowflake-managed or Glue/externally managed? Partitioned? | Removes or keeps the refresh/staleness and partition-spec work (I4) |
| Q8 | Can in-window Zone1 data change while `'H'` runs (Zone1 reruns, DMigrator re-sends)? | Read consistency and re-plan rules (C4, I7) |
| Q9 | Are all Zone2 targets SCD2 via `MERGE`, or are some append-only? | Decides whether intra-table parallelism is ever safe (C5) |
| Q10 | Rough volumes: number of tables, largest table rows/TB, and the tolerable `'H'` duration? | Sets chunk size and whether `KEY_HASH` is needed at all (I3, C5) |

---

## 9. What was verified, and how

| Claim | Basis |
|---|---|
| ABC `'H'` window, audit-field/UTC rule, job-load shape, SCD2 `MERGE`, Stonebranch as scheduler, DMigrator column | `../w2-abc-framework/reference.md` §1–3, §9, §11 (from KT transcripts — itself second-hand) |
| W3 wording of the no-SP constraint | `../w3-scd-effective-date-split/solution_design.md` §1 |
| `SHOW … LIKE` is case-insensitive with `%`/`_` wildcards | Snowflake `SHOW ICEBERG TABLES` docs (via search result) |
| `IS_ICEBERG` column in `SHOW TABLES` / `TABLES` view | Snowflake BCR 2023_08 release note (via search result) |
| Positional deletes / deletion vectors are read on Iceberg tables | Snowflake release notes and "Manage Iceberg tables" docs (via search result) |
| Time Travel on Iceberg tables; externally-managed tables need refresh | Snowflake Iceberg tables docs (via search result) |
| Session variables don't reach a Task's session | Architectural reasoning: `SET` variables are session-scoped. **Not verified against a doc page.** Prove it with a one-line Task test before relying on it either way |
| Window-function chunking SQL (§5) | Written for this review, **not executed** |
| Chunk-size direction (I3) | Judgement from per-run overhead and `MERGE` cost. **The numbers must come from calibration** |

`docs.snowflake.com` was blocked to direct fetch from this environment, so the Snowflake items above rely
on search-result extracts of the official pages, not a full page read.
