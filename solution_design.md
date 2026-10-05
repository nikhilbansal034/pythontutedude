# Iceberg → Native Historical Load — Chunking Design

## Requirement

Historical data migration path: source system → Snowflake Iceberg tables → Snowflake native tables.

This workstream covers a planning script that:
1. Takes a database + schema as required input, plus an optional single table name.
2. If a table name is given, scopes the entire run to just that table; otherwise iterates every Iceberg table in that schema.
3. For each table in scope, measures size (bytes), row count, and column count.
4. Decides a chunking strategy per table based on that profile.
5. Writes chunk descriptors to a metadata table — parent table, which column the chunk is built on, chunk size/row count, start and end of the chunk, plus status/audit fields. **Building the actual per-chunk extraction query is explicitly out of scope** — that's the execution layer's job, not this script's.
6. Validates its own inputs up front and isolates per-table failures, rather than letting a bad parameter or one broken table take down the whole run.

This metadata table is the control structure that a later extraction process (not yet designed, and not responsible for query construction either) will read to move each table from Iceberg to native in bounded pieces.

## Status

Design discussion held 2026-10-05: chunking approach, IDMC/PDO mechanics, and full architecture (flow, inputs, dynamism, scalability, exception handling, table shapes) all agreed. **Correction, later same day:** client requirement is no Snowflake stored procedure — this is unrelated to PDO (see new section below) and invalidates the "write a stored procedure" plan. CONTROL + CONFIG table shapes are unaffected; only the implementation mechanism for the planning logic is open again, pending user/client clarification.

## Chunking approaches evaluated

1. **Calendar/period range chunking** — fixed boundaries (day/week/month/quarter/year) on a date/timestamp driver column. Deterministic, business-readable, matches the stated start/end-period metadata shape directly.
2. **Adaptive/volume-aware period chunking (recommended primary)** — same as #1, but period length varies so each chunk hits a target row/byte budget. Needed because historical volume is rarely flat over time (recent years almost always denser than old ones); flat calendar chunking would make old chunks tiny and recent ones oversized.
3. **Equi-row bucketing (`NTILE(n)`)** — fallback for tables with no usable date/timestamp column. Produces n roughly-equal-row buckets with no period semantics — "start/end" would have to mean a key range, not a date range, so it's a fallback, not primary.
4. **Equi-width bucketing (`WIDTH_BUCKET`)** — divides min–max range into N equal-width intervals regardless of row distribution. Simple but skews badly on non-uniform historical data. Not recommended as primary.
5. **Hash/modulo bucketing** — even parallelism, no period meaning. Not a fit here (one-time ordered historical backfill, not a steady-state parallel load).
6. **Partition-spec-aligned chunking (refinement, not a replacement)** — align chunk boundaries to the Iceberg table's actual partition transform (e.g. `month(effective_date)`) so each chunk reads whole partitions. Layer this on top of #2 once a driver column is known.

## Recommendation

Adaptive period chunking (#2) per table:
- Driver column: if the Iceberg table's partition spec uses a date/timestamp transform (`year`/`month`/`day` on some source column), use that column — it's already the system's own notion of time partitioning. Otherwise fall back to a heuristic (single DATE/TIMESTAMP column on the table) or a user-supplied mapping (see open question 1).
- Chunk cut rule: walk time-ordered period buckets (e.g. month buckets) and cut a new chunk when cumulative rows or cumulative estimated bytes — whichever binds first — crosses a configurable threshold (open question 2).
- Column count's role: not an independent chunking axis. It feeds average row byte-width (bytes ÷ rows ÷ columns as a rough proxy, or bytes ÷ rows directly), which converts a byte budget into a row-count budget per chunk for wide vs. narrow tables.

## Snowflake facts verified against current docs (2026-10-05)

- `TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(TABLE_NAME => 'db.schema.table'))` returns one row per registered Parquet file: `REGISTERED_ON`, `FILE_NAME`, `FILE_SIZE`, `ROW_COUNT`, `ROW_COUNT_GROUP`. No partition value per file. Good for a cheap, Iceberg-native aggregate size/row check. — [docs](https://docs.snowflake.com/en/sql-reference/functions/iceberg_table_files)
- `SHOW ICEBERG TABLES` returns `partition_specs` (array of `{spec-id, fields: [{name, transform, source-id, field-id}]}`) and `current_partition_spec_id` — the partition *schema* (which column, which transform), not materialized per-partition row counts or boundary values. Useful to auto-detect a sensible driver column per table. — [docs](https://docs.snowflake.com/en/sql-reference/sql/show-iceberg-tables)
- `INFORMATION_SCHEMA.TABLES` still exposes `ROW_COUNT` / `BYTES` generally, but for externally-managed Iceberg tables freshness depends on catalog sync / `ALTER ICEBERG TABLE ... REFRESH`. Treat as a fast first pass; cross-check against an `ICEBERG_TABLE_FILES` aggregate if a value looks stale or null.
- `INFORMATION_SCHEMA.COLUMNS` — reliable column count per table regardless of table type.
- **Gap:** no built-in Snowflake function returns per-partition row counts/boundaries for an Iceberg table. Getting rows-per-month (or whatever period granularity) requires an actual `GROUP BY DATE_TRUNC(period, driver_col)` scan against the live table — a real one-time read, not pure metadata. Needs to be budgeted as planning-phase compute cost, done once per table.
- General Snowflake load-sizing guidance: target ~100–250 MB compressed per file for `COPY INTO` parallelism, avoid files ≥100 GB, parallelism is capped by file count. This is about the native-table load step, not Iceberg-side chunk sizing directly — useful as a sanity anchor for the final chunk-size default, not a rule to copy verbatim. — [docs](https://docs.snowflake.com/en/user-guide/data-load-considerations-prepare)

## Open questions (pending user answers)

1. ~~Driver/period column per table~~ — **answered 2026-10-05:** auto-detect from Iceberg partition spec, fall back to heuristic single DATE/TIMESTAMP column.
2. ~~Chunk size threshold~~ — **answered 2026-10-05:** rows/runtime-based (PDO confirmed, see below), via the calibration procedure in the Architecture section. CONFIG defaults given there are provisional placeholders pending that calibration run, not a blocker to writing SQL.
3. ~~Metadata table schema~~ — **answered 2026-10-05:** extend beyond the 4 stated columns with status/progress tracking (state, rows_loaded, run id, timestamps).
4. ~~Run model~~ — **answered 2026-10-05:** repeatable/idempotent — safe to re-run as new tables/schemas get onboarded, skip tables already planned.
5. ~~Schema scope~~ — **answered 2026-10-05:** Discovery uses `SHOW ICEBERG TABLES`, which only ever returns Iceberg tables — no separate type filter needed. Narrowed further 2026-10-05: an optional single-table input scopes a run to one table instead of the whole schema (see Architecture → Inputs).
6. ~~IDMC load mode~~ — **answered 2026-10-05:** PDO (pushdown). See PDO analysis section.

No open questions are blocking SQL at this point. Three refinements added 2026-10-05 — optional table-name input, input/exception validation, and confirmed no-query-building scope — are folded into the Architecture section below.

## IDMC load-side chunk sizing (research, 2026-10-05)

User asked what the ideal chunk size should be for loading via IDMC (Informatica Intelligent Data Management Cloud), rather than picking a number unprompted. Researched against Informatica + Snowflake docs.

**The fork that has to be resolved first:** how does the Iceberg→native leg actually move data in IDMC?

- **Pushdown / SQL-ELT mapping** — source and target are both Snowflake (Iceberg table, native table), so IDMC can push the whole mapping down as SQL executed inside Snowflake (e.g. `INSERT`/`MERGE ... SELECT ... FROM iceberg_table WHERE <period_col> BETWEEN :start AND :end`). No file staging, no COPY. This is the natural choice for a same-platform move and is almost certainly more efficient than routing data out through files. Confirmed from Informatica's own Snowflake connector docs: SQL-ELT optimization and bulk processing are mutually exclusive settings on the same mapping — they are two different mechanisms, not two tuning knobs on one mechanism.
- **Staged/bulk mapping** — IDMC caches rows, writes compressed files (CSV/Parquet) to internal/external stage, then issues Snowflake `COPY INTO`. This is what Mass Ingestion tasks and the connector's "bulk processing" option do. Relevant when the mapping can't be pushed down, or a generic ingestion task template is reused instead of a native Snowflake-to-Snowflake mapping.

**"Ideal chunk size" is a different question in each mode:**

- *Staged/bulk mode* — a file-size question:
  - Snowflake's own docs (confirmed, primary source): target **~100–250 MB compressed per file** for `COPY INTO` parallelism; avoid files ≥100 GB; parallelism is capped by file count, not warehouse size.
  - Informatica mass-ingestion docs (via search-result snippets only — docs.informatica.com returned HTTP 403 to direct fetch on two separate attempts, so this is **not independently re-verified against the primary page**): default batch size = 5 files per `COPY` batch; up to 1000 files per batch for a Snowflake target; a worked example for a 100 GB initial load uses 500 MB per file at batch size 20. A separate Informatica source cited a 500 MB–1 GB per-file sweet spot, which is notably higher than Snowflake's own 100–250 MB guidance. **This gap is unresolved** — Informatica also appears to have recently restructured this doc set (URLs moved from `cloud-mass-ingestion` to `data-ingestion-and-replication`), so the number may be version-dependent. Recommend cross-checking against whatever your IDMC tenant's current docs or Informatica COE actually say before locking a default.
  - [Snowflake: Preparing your data files](https://docs.snowflake.com/en/user-guide/data-load-considerations-prepare) · [Informatica: Configure bulk processing (Snowflake connector)](https://onlinehelp.informatica.com/IICS/dev/CDI/en/cloud-data-integration-snowflake-data-cloud-connector/Configure_bulk_processing.html) · batch-size/file-size figures from Informatica mass ingestion docs via search snippets (primary pages blocked automated fetch: `docs.informatica.com/.../tune-the-task/batch-size.html`, `.../tune-the-database/file-size.html`)

- *Pushdown/ELT mode* — not a file-size question at all. There's no COPY, no staged file. "Chunk size" means: how many rows (or how much estimated warehouse runtime) is safe per `INSERT`/`MERGE` statement — bounded by transaction duration risk, warehouse size/concurrency, and how many chunks should run in parallel across warehouses. No Informatica or Snowflake file-size doc applies here; this is pure warehouse-sizing/workload-management judgment, tunable empirically (start with a target like "X minutes of warehouse-time per chunk" or "N million rows," measure, adjust).

**Working assumption until answered:** pushdown/ELT is architecturally the right fit for a Snowflake Iceberg → Snowflake native move, which would mean the metadata table's chunk-size threshold should be rows-based (or runtime-based) rather than byte/file-based. Still need the user to confirm which mode the actual IDMC task uses or is planned to use.

**Answered 2026-10-05:** Liberty Mutual's IDMC setup uses PDO (Pushdown Optimization). Confirms the pushdown/ELT branch above.

## PDO analysis (research, 2026-10-05)

User confirmed their IDMC task uses PDO and asked for (a) a precise read on what PDO means and (b) an honest check on whether something else could be better — not just confirmation of the existing choice.

**What PDO/APDO is, confirmed:** Informatica calls the current version "Advanced Pushdown Optimization" (APDO). It translates the mapping into a native SQL statement (or native Snowflake command) and hands it to Snowflake to execute — no data passes through the Secure Agent. Informatica's own guidance explicitly recommends ELT/APDO once data already resides in Snowflake, specifically for "loading and transforming data from data lakes to data warehouses" — Iceberg (lake format) → native table (warehouse) is exactly this pattern. Confirms the architecture, not just by inference this time.

**Mechanics / fallback hierarchy (general IDMC pattern — confirmed structure on the Databricks Delta connector docs; Snowflake's own PDO fallback-option docs weren't directly accessible to re-verify this applies identically, treat as "very likely the same UI pattern" not "confirmed identical"):**
- **Full PDO** — whole mapping pushed as one SQL statement, preferring target-side; if not 100% compatible, splits into source-side push + target-side push.
- **Partial PDO** (fallback default) — pushes what it can, runs the rest through the Informatica engine.
- **Non-PDO** — mapping runs entirely through the engine, no pushdown at all.
- **Fail Task** — errors out rather than silently degrading.
A mapping landing in "Partial" or "Non-PDO" instead of "Full" silently reintroduces the Secure Agent as a bottleneck — at which point the staged/bulk file-size numbers from the section above become relevant again, for whatever slice of rows didn't get pushed down.

**Confirmed Snowflake-connector-specific facts:**
- "Snowflake Connector supports Full and Source pushdown optimization **with an ODBC connection that uses Snowflake ODBC drivers**" — the ODBC connection subtype is what's documented as required for Full/Source PDO, not just picking "Snowflake" as a generic connector. Worth confirming Liberty Mutual's actual connection object is configured this way (or, if using the newer Snowflake Data Cloud Connector + its separate "SQL ELT optimization" toggle instead of the classic ODBC-based PDO path, that's a different mechanism reaching the same goal — worth knowing which one is actually in play).
- "Snowflake Connector does not support upsert operation in full pushdown optimization" — operation-type-driven, not object-type-driven. A plain append/INSERT per chunk (which fits a historical backfill) stays eligible for full PDO; if the mapping uses UPDATE/MERGE/upsert (e.g., for safe re-runs of a chunk), that specifically can knock it out of full PDO. Ties back to the idempotent/repeatable run-model decision already made — worth checking whether re-running a chunk is implemented as upsert (risk) or as delete-then-insert / insert-only-if-not-already-loaded (stays full-PDO-eligible).
- **Not confirmed either way:** whether a Snowflake **Iceberg table object** specifically is a fully pushdown-eligible source type in Informatica's current Snowflake connector. Docs describe object support only generically ("a source transformation to represent a Snowflake object") and don't enumerate Iceberg vs. native table as distinct eligibility cases. Informatica does market dedicated Iceberg/Polaris connectivity as of 2025, so this is likely fine, but it's the one real unknown — cheap to settle empirically (see action item below) rather than assume.

**Is something else better than PDO here?** Considered bypassing IDMC entirely for this one leg — since full PDO is *already* just "Informatica generates a SQL statement, Snowflake runs it," a Snowflake Task calling a stored procedure that reads the chunk metadata table and issues `INSERT INTO native ... SELECT ... FROM iceberg WHERE period BETWEEN :start AND :end` directly would have strictly fewer moving parts: no fallback risk, no ODBC/connector-config dependency, no Iceberg-pushdown-eligibility unknown, no per-task orchestration overhead. That's real and worth naming honestly. But it's not a better *overall* answer unless Liberty Mutual's governance allows a same-platform exception to the standard integration tool — centralized lineage, monitoring, scheduling, and access control through IDMC are typically non-negotiable in an enterprise/regulated setting regardless of which engine does the compute. **Recommendation: keep PDO.** It's already the standard, and it's literally what Informatica's own guidance recommends for this exact lake→warehouse-within-Snowflake pattern. Treat native Snowflake Task/SP orchestration as a fallback worth raising only if full PDO can't be made to trigger reliably in practice.

**Action items this surfaces (not yet done):**
1. Confirm which Snowflake connector generation/connection type the actual mapping uses (ODBC-based classic PDO vs. newer Snowflake Data Cloud Connector's SQL-ELT toggle).
2. Run one trial chunk and check the session/task log explicitly states full pushdown — not partial — before trusting the design at scale.
3. Confirm the chunk re-run/idempotency mechanism doesn't rely on upsert (would break full-PDO eligibility for that operation).
4. New second-order factor for the chunk-size number (in addition to transaction-duration/warehouse-concurrency from the section above): each chunk also carries a fixed IDMC task-orchestration overhead (task start, API calls, logging) on top of Snowflake compute time. Chunks should be sized large enough that this overhead is a rounding error relative to per-chunk runtime — i.e. don't over-chunk into hundreds of tiny, fast pieces just because the rows/warehouse-runtime math allows it.

[Sources: search-result synthesis — Informatica's "Why You Should Use Informatica's ELT or Advanced Pushdown Optimization for Snowflake" blog, the Snowflake Connector Guide's "Snowflake Objects in Mappings" and PDO pages, and the general Databricks Delta connector's pushdown-optimization-types page for the fallback hierarchy pattern. Several primary Informatica doc pages 403'd direct fetch attempts (same bot-blocking as the batch/file-size research above) — findings here come from WebFetch summaries of search snippets, not a fully re-verified primary-page read.]

## Architecture (discussed 2026-10-05, pre-SQL)

Full end-to-end design, discussed before writing any code per user's request. Covers flow, inputs, processing, dynamism, scalability, chunk derivation, ideal chunk size, and the control/config table shapes.

### Scope boundary

Two legs exist in the overall migration. This workstream owns the **planning layer only** for the second leg:

1. Source system → Iceberg tables — out of scope here.
2. Iceberg tables → native tables — **this workstream plans it** (produces the chunk list); **IDMC/PDO executes it** (reads the plan, runs the actual pushdown `INSERT`/`MERGE` per chunk). The planner and the executor are two separate things connected only by the control table.

### Components and flow

```
CONFIG table ──► feeds thresholds into Decide

[Input] → [Validate] → [Discovery] → [Profile] → [Decide] → [Write] → CONTROL table → [Execution: IDMC/PDO]
```

- **Input** — database + schema (required), optional single table name.
- **Validate** — fail fast on missing/blank required params, or a database/schema/table that doesn't exist (or isn't Iceberg, for a named table). Nothing is written if this step fails. *(new 2026-10-05)*
- **Discovery** — the named table only if one was given, otherwise every Iceberg table in the schema; diffed against CONTROL to skip what's already planned and not stale.
- **Profile** — rows, bytes, columns, driver column, period density.
- **Decide** — pick chunk type and boundaries.
- **Write** — idempotent MERGE into CONTROL; isolated per table, so one table's failure doesn't block the rest. *(failure isolation detail new 2026-10-05)*
- **Execution (IDMC/PDO)** — separate workstream, reads CONTROL, not built here.

The diagram sent earlier in chat shows this same flow visually — it pre-dates the Validate step and optional table-name input added below, the rest of the shape is unchanged.

### 1. Inputs

**Required, passed to the planning call:**
- `DATABASE_NAME`, `SCHEMA_NAME` — the Iceberg schema to scan.

**Optional, passed to the planning call:**
- `TABLE_NAME` — single-table override, added 2026-10-05. If provided, the entire run (profile → decide → write) scopes to just that one table — Discovery's schema-wide enumeration is skipped entirely. If omitted, falls back to the default: discover and plan every Iceberg table in the given database/schema.
- `FORCE_REPLAN` flag — bypasses the idempotency skip (for the named table, or every table in scope if `TABLE_NAME` is also omitted). Manual override, e.g. after a source schema change.

**Standing input, not passed per-call — lives in the CONFIG table (see schema below):**
- Chunk-size thresholds, profiling grain, staleness-growth threshold, small-table short-circuit. Tunable by an operator without touching code. Supports a global default row plus per-table overrides (some tables may legitimately need a different target than the rest of the schema).

This split (call-time params vs. standing config) is what makes the script reusable across runs and across schemas rather than a one-shot script with hardcoded numbers.

### 2. Processing pipeline

0. **Validate inputs** *(new 2026-10-05)* — runs before touching any table data; fails the whole call immediately with a clear, operator-facing message rather than letting a raw Snowflake system error surface deep inside profiling:
   - `DATABASE_NAME` or `SCHEMA_NAME` missing/blank → fail: these are required. (`TABLE_NAME` is allowed to be blank — see Inputs.)
   - `DATABASE_NAME` doesn't exist (`SHOW DATABASES LIKE :db` returns nothing) → fail, naming the database.
   - `SCHEMA_NAME` doesn't exist in that database (`SHOW SCHEMAS LIKE :schema IN DATABASE :db`) → fail, naming the schema. Checked only after the database itself is confirmed, so the two failures can't be conflated.
   - If `TABLE_NAME` is given: check it exists at all (`SHOW TABLES LIKE :table IN SCHEMA :db.:schema`), then check it's specifically an Iceberg table (`SHOW ICEBERG TABLES LIKE :table IN SCHEMA :db.:schema`) — two separate checks so the error can say "doesn't exist" vs. "exists but isn't an Iceberg table" instead of one generic not-found message.
   - This step is about the call's own parameters, not any table's data — a bad parameter aborts the whole call before anything is written. Contrast with per-table failures below, which don't abort the run.

1. **Discovery** — if `TABLE_NAME` was given, scope is exactly that one table (already validated in step 0). Otherwise, enumerate Iceberg tables in the given database/schema (`SHOW ICEBERG TABLES IN SCHEMA`). Left-join against the CONTROL table: a table is **skipped** if it already has chunk rows and isn't stale; it's **(re)planned** if it's new, or if its current row count has grown past the configured staleness-growth threshold since it was last planned, or if it previously failed to plan (see `PLAN_FAILED` below). This is the idempotency mechanism — safe to re-run the whole thing anytime; only the delta gets (re)processed.

2. **Profiling** (per table that needs planning) —
   - Row count + byte size: `INFORMATION_SCHEMA.TABLES` first (fast, metadata-only); cross-check against an aggregate over `TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_FILES(...))` if the first value is null/stale (externally-managed Iceberg tables can lag here — see facts section above).
   - Column count: `INFORMATION_SCHEMA.COLUMNS`.
   - Driver column candidate: parse `SHOW ICEBERG TABLES`'s `partition_specs` for a field using a `year`/`month`/`day`/`hour` transform → that's the table's own notion of time partitioning, so it's the first-choice driver column. If no such transform exists (or the spec's field doesn't cleanly resolve to a real column — flagged as an implementation risk below), fall back to: exactly one DATE/TIMESTAMP column found via `INFORMATION_SCHEMA.COLUMNS` on that table. If neither resolves, the table has no period semantics — falls through to the key-range path (see Decision step 3).
   - Period-density scan — **only for tables above the small-table threshold** (see Config). One `GROUP BY DATE_TRUNC(<grain>, driver_col)` query gets rows-per-bucket for the whole table in a single pass. This is the one step that's a real scan, not metadata — see scalability notes below for why it's still cheap in aggregate.

3. **Decision** — per table, in order:
   - **Small table** (row count ≤ `MIN_ROWS_TO_CHUNK`): one chunk, no splitting. Covers reference/dimension tables that might share the schema with the real fact-sized tables — the script doesn't need separate handling for them, the threshold does it automatically.
   - **Has a driver column, above threshold:** adaptive period chunking — walk the time-ordered buckets from the density scan, accumulate rows, cut a chunk when the running total crosses `TARGET_ROWS_PER_CHUNK`. If a *single* bucket alone exceeds the target by more than `MAX_BUCKET_OVERAGE_MULTIPLE` (default 1.5×), recursively re-profile just that bucket at the next finer grain (month → day) and split within it; otherwise accept the oversized bucket as one chunk rather than over-engineer the split. In practice this recursion bottoms out after one level almost always.
   - **No usable driver column:** fall back to equi-row chunking (`NTILE` or windowed `ROW_NUMBER` over a stable key). These rows are tagged `CHUNK_TYPE = 'KEY_RANGE'` instead of `'PERIOD'` — the control table has to carry this distinction since start/end means something different in each case (see schema below).
   - Column count isn't an independent branch — it's folded into the row/byte math (`avg_row_bytes = BYTES / ROW_COUNT`), which is what turns a byte budget into a row-count budget for wide vs. narrow tables. No separate "if wide table, do X" rule is needed.

4. **Write** — `MERGE` the computed chunks into the CONTROL table, keyed on `(DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, CHUNK_SEQ)`. **Safety rule:** never overwrite a row whose `STATUS` is `IN_PROGRESS` or `DONE` — only insert new chunk rows for a table, or replace rows that are `PENDING` / `FAILED` / `PLAN_FAILED`. This is what makes "repeatable/idempotent" actually safe instead of just repeatable — a re-plan can't clobber work that's already succeeded or is actively running.

**Per-table failure isolation** *(new 2026-10-05, answers the exception-handling ask)* — once step 0 passes, a problem with one specific table (a permission gap, a malformed or unexpected partition spec, a profiling query that errors) must not abort planning for every other table in a schema-wide run. Each table's profile → decide → write sequence runs inside its own exception handler; on failure, write a single row for that table with `STATUS = 'PLAN_FAILED'` and `ERROR_MESSAGE` populated, then move on to the next table. A `PLAN_FAILED` row is retry-eligible on the next run — same as `PENDING`/`FAILED` — never a terminal dead end.

### 3. Dynamism — what's config-driven vs. hardcoded

- No table names, driver columns, or thresholds are hardcoded. Driver column is resolved per table at runtime from the table's own Iceberg metadata, with a defined fallback chain.
- Thresholds live in CONFIG (global default + optional per-table override), so retuning doesn't touch code.
- New tables added to the schema later are picked up automatically on the next run — no onboarding step beyond "run the planner again."
- The small-table short-circuit and the bucket-overage recursion mean one script handles a schema that mixes huge fact tables and tiny reference tables without manual triage per table.

### 4. Scalability

- **Planning-phase cost** is dominated by the per-table `GROUP BY` density scan (the one real read in the pipeline). Contained by: (a) idempotent skip of already-planned/non-stale tables, so a re-run only pays for the delta; (b) running the planner on its own right-sized warehouse, separate from whatever warehouse(s) execute the actual chunk loads, so planning and loading don't compete for compute; (c) optionally batching tables through the profiling step rather than firing all of them at once if a schema has hundreds of large tables.
- **Execution-phase parallelism** (downstream of this script, but enabled by it): chunks are independent, non-overlapping period ranges, so multiple chunks — even from different tables — can run concurrently on separate warehouses with zero coordination needed beyond claiming a row. Claiming should be a single atomic statement (e.g. `UPDATE CONTROL SET STATUS='IN_PROGRESS' WHERE CHUNK_ID = <next PENDING, ordered> `) so two concurrent workers can't grab the same chunk — a detail for whoever builds the execution layer, flagged now so it isn't a surprise later.
- **The control table itself stays small** — one row per chunk, not per source row — so it never becomes the bottleneck regardless of how large the underlying tables get.
- Horizontal scale beyond this is just Snowflake's own multi-cluster warehouse scaling for concurrent chunk execution — nothing this design needs to build.

### 5. Ideal chunk size — concrete answer

No single number can be trusted without the empirical check flagged last turn (PDO validation), but here's a principled way to land on one instead of guessing:

- **Target the thing that actually matters: runtime, not row count.** Row count is only a proxy. What's really being protected is (a) transaction/session duration risk, (b) blast radius of a failed chunk (how much gets redone), (c) amortizing IDMC's per-task orchestration overhead, (d) having enough chunks to parallelize across warehouses without so many that overhead dominates. A runtime target (e.g., **10–20 minutes of warehouse time per chunk**, as a starting proposal) maps directly to all four; a row count doesn't, because it varies with table width and mapping complexity.
- **Calibration procedure** (cheap, concrete, does not require guessing a generic industry number): pick one representative mid-size table, run a single test chunk at a provisional size (start at 10M rows) through the real PDO mapping, confirm the session log says full pushdown (ties to validation action item from last turn), and measure wall-clock runtime. Scale the row target up or down to converge on the chosen runtime window; one more test run confirms whether scaling is roughly linear. This produces a number that's actually correct for Liberty Mutual's warehouse size and mapping, instead of a borrowed industry figure.
- **Starting defaults for the CONFIG table** (explicitly provisional — placeholders to be replaced by the calibration run, not final numbers): `TARGET_ROWS_PER_CHUNK` = 10,000,000; `MIN_ROWS_TO_CHUNK` = 1,000,000 (below this, one chunk, no split); `MAX_BUCKET_OVERAGE_MULTIPLE` = 1.5.

### 6. Other details — table shapes

Shapes only (no DDL yet, per your ask to discuss architecture before SQL).

**CONTROL table** (the metadata table from the original requirement, extended per your decision to add status/progress tracking):

| Column | Purpose |
|---|---|
| `DATABASE_NAME`, `SCHEMA_NAME`, `TABLE_NAME` | source table identity |
| `CHUNK_SEQ` | order of this chunk within the table |
| `CHUNK_TYPE` | `PERIOD` or `KEY_RANGE` — tells the executor how to interpret start/end |
| `DRIVER_COLUMN` | which column the start/end values bind to (period column, or key column for the fallback case) |
| `START_VALUE`, `END_VALUE` | chunk boundaries — recommend `VARIANT` rather than a fixed type, since driver columns differ in type across tables (DATE/TIMESTAMP for periods, NUMBER for key-range fallback); trade-off is the executor must cast at consumption time |
| `ESTIMATED_ROWS`, `ESTIMATED_BYTES` | from profiling, for visibility/audit |
| `STATUS` | `PENDING` / `IN_PROGRESS` / `DONE` / `FAILED` / `PLAN_FAILED` (planning itself errored on this table — distinct from an execution failure; retry-eligible like `PENDING`/`FAILED`) |
| `ROWS_LOADED` | actual, filled by the execution layer |
| `RUN_ID` | groups chunks produced by one planning execution, for audit |
| `PLANNED_AT`, `STARTED_AT`, `COMPLETED_AT` | timestamps |
| `ERROR_MESSAGE` | filled on `FAILED` or `PLAN_FAILED` |
| `SOURCE_ROWCOUNT_AT_PLAN` | snapshot used by the staleness/re-plan rule |

**CONFIG table** (tunables, global default + per-table override):

| Column | Purpose |
|---|---|
| `SCOPE` | `*` for global default, or a specific `database.schema.table` override |
| `TARGET_ROWS_PER_CHUNK` | primary chunk-size threshold |
| `MIN_ROWS_TO_CHUNK` | small-table short-circuit |
| `PROFILE_GRAIN` | default `MONTH` |
| `MAX_BUCKET_OVERAGE_MULTIPLE` | default `1.5` |
| `STALENESS_GROWTH_PCT` | triggers re-plan when a table's row count grows past this since last planned |

### Explicitly out of scope for this workstream

- The execution layer (whatever reads `PENDING` rows and actually triggers the IDMC/PDO mapping per chunk, then writes back status) is a separate piece of work. This design only commits to the **contract** it needs from the control table (status enum, timestamps, rows_loaded, atomic-claim-friendly) — not its implementation.
- **Confirmed 2026-10-05:** the control table stores chunk *descriptors* only, never the chunk's extraction SQL. Mapped directly to the original ask: chunk column → `DRIVER_COLUMN`; size of chunk → `ESTIMATED_ROWS` / `ESTIMATED_BYTES`; start/end of chunk → `START_VALUE` / `END_VALUE`; parent table → `DATABASE_NAME` + `SCHEMA_NAME` + `TABLE_NAME`; related information → `CHUNK_TYPE`, `STATUS`, `RUN_ID`, timestamps, `ERROR_MESSAGE`. Building the actual `WHERE <driver_col> BETWEEN ... AND ...` (or equivalent) that the execution layer runs per chunk is entirely out of scope here — that's the execution layer's concern, not something this script produces.

## No-stored-procedure constraint (research, 2026-10-05)

Client requirement surfaced: no Snowflake stored procedure. User asked whether this is what PDO means.

**It isn't — the two are unrelated:**
- **PDO** governs how IDMC executes its *mapping* for the Iceberg→native data-movement leg (push the transformation down as SQL vs. route rows through the Secure Agent). It's an Informatica/IDMC concept, scoped entirely to the execution layer already marked "separate workstream" above.
- **No stored procedure** constrains how *this* planning script (the one that profiles tables and writes chunk rows) gets implemented inside Snowflake. It has nothing to do with IDMC or PDO — it's a restriction on Snowflake-side object types.

Conflating them would be a mistake: tightening PDO further doesn't loosen the stored-procedure constraint, and this constraint doesn't change the PDO decision already made.

**Why this actually bites:** most of the planning pipeline (discovery via `SHOW ICEBERG TABLES`, row/byte/column counts via `INFORMATION_SCHEMA`) is plain set-based SQL — no procedure needed there regardless. The problem is narrower but real: the per-table period-density scan (`GROUP BY DATE_TRUNC(grain, driver_col)`) has to run once per table, against a different table and a different driver column each time. Static SQL can't parameterize a table name or column name inside one query — that needs either dynamic SQL generation or a different approach entirely, and "loop over N tables, generate and run dynamic SQL per table" is exactly the shape of logic stored procedures exist for.

**Two ways to get that capability without a stored procedure, both confirmed against current Snowflake docs:**

1. **Snowflake Scripting as an anonymous block, not a named object.** Snowflake Scripting (`BEGIN...END`, loops, cursors, `EXECUTE IMMEDIATE` for dynamic SQL, exception handling) does not require `CREATE PROCEDURE` — the same block can be submitted ad hoc via `EXECUTE IMMEDIATE $$ BEGIN ... END; $$`, or used directly as a Snowflake Task's body (`CREATE TASK ... AS BEGIN ... END;`). Either way, **no stored-procedure object ever exists** in the database — same procedural capability, nothing to grant/own/version as a callable proc. — [Understanding blocks in Snowflake Scripting](https://docs.snowflake.com/en/developer-guide/snowflake-scripting/blocks)
2. **Push the per-table loop into IDMC itself.** If the client's actual principle is broader than "no named proc objects" — i.e., "no procedural logic in Snowflake at all, orchestration belongs in IDMC" — then the per-table looping moves to IDMC's own mapping/workflow engine: IDMC runs Discovery once (plain SQL), loops over the returned table list itself, and calls a parameterized (possibly PDO-pushed) SQL statement per table for profiling and per-chunk writes. Snowflake then only ever executes plain, static, parameterized SQL — never a script, never a proc.

These lead to materially different builds, so which one the client means matters:

**Answered 2026-10-05:** no persistent `CREATE PROCEDURE` object specifically — an anonymous Snowflake Scripting block or a Task body is acceptable. Planning logic stays in Snowflake, just never saved as a named callable procedure.

**How parameters get in without a `CALL proc(args)` signature** (confirmed against Snowflake's own docs on Scripting variables): session variables, dereferenced with `$` inside the block's `DECLARE` section.
```
SET v_database = 'MY_DB';
SET v_schema   = 'MY_SCHEMA';
SET v_table    = NULL;              -- omitted/NULL = whole-schema scan; a name = single-table scope
EXECUTE IMMEDIATE $$
DECLARE
  v_db  STRING DEFAULT $v_database;
  v_sch STRING DEFAULT $v_schema;
  v_tbl STRING DEFAULT $v_table;
BEGIN
  ...
END;
$$;
```
Same effective call-with-arguments experience as a stored procedure, without the object. — [Working with variables (Snowflake Scripting)](https://docs.snowflake.com/en/developer-guide/snowflake-scripting/variables)

**Real tradeoff worth naming, not hiding:** a stored procedure would let both a scheduled run and an ad-hoc single-table run share one object via `CALL`. Without one, the same block logic has to live in two invocation paths — a Task (`CREATE TASK ... AS BEGIN...END`) for the scheduled/whole-schema run, and an `EXECUTE IMMEDIATE` of the same block text for an on-demand/single-table run. Both paths run from the same source script (kept in sync via source control at deploy time), but there's no shared callable object underneath — that's the actual cost of the constraint, not a gap in the design.

[Sources: Snowflake docs, directly fetched — anonymous block, Task-body, and session-variable behavior all confirmed, not inferred.]

## Next step

No open questions left. Write the CONTROL + CONFIG table DDL, then the planning logic as a Snowflake Scripting block — deployed once as a Task body for scheduled/whole-schema runs, and runnable ad hoc via `EXECUTE IMMEDIATE` with session variables for a single-table/on-demand run — covering `TABLE_NAME` as optional, the threshold parameters, and the validation + per-table exception handling already designed above.
