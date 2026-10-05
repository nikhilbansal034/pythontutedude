# Iceberg historical load — chunk planner: solution design

**Version 2 — 2026-10-05. Design of record.** It replaces version 1 (the original discussion document,
kept in git history at commit `903e5c2`). The reasoning behind every change, and the decisions taken
along the way, are in `design_review.md` (revision 9). The runnable script and its test kit are in `sql/`.

---

## 1. Problem statement

Historical data is migrated from the source systems into **Zone1 Snowflake Iceberg tables**, and from there
into **native Snowflake tables**. Some of these tables hold years of history, much of it landed by a bulk
backfill in a few days. Loading a table like that in one statement is risky: a failure redoes everything,
and one statement can run for hours.

What's needed is a **plan** for each table that says how to load it in bounded pieces:
- **How many chunks** the table should be loaded in.
- **How big each chunk is**, in rows and bytes.
- **Which column divides the chunks.**
- **The range of each chunk** on that column.

The plan is written to a metadata table. Whatever performs the load reads it later.

## 2. Scope

| In scope | Out of scope |
|---|---|
| A planner script that reads Iceberg tables and writes chunk metadata | Loading data; creating or changing target tables |
| Any database and schema, CURRENT or HISTORY layer | Building the per-chunk extraction or load SQL |
| One table, a list of tables, or a whole schema per run | Which warehouse runs the loads |
| Validating inputs; isolating per-table failures | Load reconciliation, retries, orchestration |
| Runs as an **anonymous Snowflake Scripting block from a Snowflake Workspace** | Stored procedures (not allowed); Tasks; IDMC (deferred) |

## 3. Decisions

| # | Decision |
|---|---|
| D1 | Works on **any database and schema**. Decisions come from each table's partition spec and columns, never from database or schema names |
| D2 | Time Travel retention is not a planner concern. `PROFILED_AT` is recorded for information |
| D3 | Metadata location set by variables at the top of the script: `metadata_database = 'test_db'`, `metadata_schema = 'test_schema'` for now |
| D4 | A split day is always "this day **and** a timestamp range / hash bucket". It doesn't depend on how `GRS_PROCESS_DATE` is derived |
| D5 | Append-only vs updated-in-place doesn't change the plan. All data is loaded either way |
| D6 | A table whose chunking can't be decided is marked **`FAILED`** with the reason. The run continues with the next table |
| D8 / D14 | **Chunk size is fixed:** 10 GB of Iceberg data and at most 250M rows per chunk, reasoned from a Medium-warehouse assumption |
| D9 / D10 | **Two metadata tables only.** No run-log table and no config table; settings are variables at the top of the script |
| D11 | **Status is held per table** in `HIST_PLAN_TABLE`: `PLANNED` / `FAILED` / `SKIPPED` / `SUPERSEDED`, with a reason |
| D12 | **Any wrong name in the input table list → report every problem and exit; nothing is written** |
| D13 / D15 | With no table list, **non-Iceberg objects are skipped**, reported (how many, which, why), and kept in `HIST_PLAN_TABLE` as `SKIPPED` |

## 4. The source tables

Reference DDL for one table in both layers: `reference_ddl.sql` (screenshots in `sources/`). All other
tables follow the same structure; only their business columns differ.

| Group | Columns | Role in the plan |
|---|---|---|
| Partition, CURRENT | `GRS_PROCESS_DATE DATE` | Primary chunk axis |
| Partition, HISTORY | `GRS_PROCESS_YEAR`, `GRS_PROCESS_MONTH`, `GRS_PROCESS_DAY` | Primary chunk axis (combined into one date) |
| Watermark | `GRS_REFINED_TIMESTAMP TIMESTAMP_LTZ(6)` | Splits a day that is too big; fallback axis for unpartitioned tables |
| Record id | `GRS_UNIQUE_ID STRING` (UUID) | Hash buckets when a timestamp can't split |
| Everything else | CDC headers (`OP`, `AR_H_TIMESTAMP`, `CHANGE_SEQ_NUM`), other `GRS_*` audit columns, business columns | Never used. Strings, per-run values, or table-specific names that may change in place |

The **CURRENT** layer mirrors the source and changes in place; the **HISTORY** layer is append-only. Both are
Snowflake-managed Iceberg v3. The layer is recorded for information. It never drives a decision.

## 5. Architecture

```
 Inputs (top of script)          Snowflake metadata (read only)                 Metadata tables (written)
 ─────────────────────           ──────────────────────────────                 ─────────────────────────
 p_database   ──┐                SHOW DATABASES / INFORMATION_SCHEMA.SCHEMATA
 p_schema     ──┼─► 1 VALIDATE ──► any problem: report + EXIT (nothing written)
 p_tables     ──┘        │
                         ▼
                   2 DISCOVER ◄── INFORMATION_SCHEMA.TABLES + COLUMNS
                         │       ◄── SHOW ICEBERG TABLES (partition_specs)
                         ▼
                   3 SCOPE: listed tables, or every object in the schema
                         │
          ┌──────────────┴───────────────── per table ────────────────────────────────┐
          │ non-Iceberg ─────────────────────────────────────────► SKIPPED row ──────────┼─► HIST_PLAN_TABLE
          │ already planned (not forced) ───────────────────────► reported only          │
          │ 4 READ STRUCTURE  partition spec, GRS_* columns, size (ICEBERG_TABLE_FILES)  │
          │ 5 CHOOSE AXIS     partition day → y/m/d → naming fallback → refined ts →     │
          │                   unique-id hash → none                                      │
          │ 6 PROFILE         rows per axis day (one scan of the axis column)            │
          │ 7 CUT             group whole days up to the target; split oversized days    │
          │ 8 CHECK           Σ chunk rows = table rows                                  │
          │ 9 WRITE           one transaction: supersede old plan, insert plan + chunks ─┼─► HIST_PLAN_TABLE
          │                                                                              │   HIST_PLAN_CHUNK
          │ any error in 4–9 ─────────────────────────────────────► FAILED row + reason ─┼─► HIST_PLAN_TABLE
          └──────────────────────────────────────────────────────────────────────────────┘
                         ▼
                   10 RESULT GRID in the Workspace: one row per table + summary counts
```

## 6. How the chunking technique is chosen

**One procedure, applied the same way to every table.** The result differs per table because it is driven
by that table's own structure and data.

### 6.1 Chunk axis: the first rule that matches wins

| # | Table information | Axis | File skipping |
|---|---|---|---|
| 1 | Partition spec: one identity partition on a DATE column | `PARTITION_DAY` | Guaranteed |
| 2 | Partition spec: identity partitions on year/month/day INT columns | `PARTITION_YMD` | Guaranteed |
| 3 | Spec not readable or not confirming, but `GRS_PROCESS_DATE` exists | `PARTITION_DAY` (`PARTITION_VERIFIED = FALSE`) | Likely |
| 4 | Same, with `GRS_PROCESS_YEAR/MONTH/DAY` | `PARTITION_YMD` (`PARTITION_VERIFIED = FALSE`) | Likely |
| 5 | Not date-partitioned, has `GRS_REFINED_TIMESTAMP` | `REFINED_TS_DAY` (its UTC date) | Depends on file layout |
| 6 | Only `GRS_UNIQUE_ID` | `UNIQUE_ID_HASH` | None |
| 7 | None of these, and bigger than one chunk | — | Table → `FAILED` |

### 6.2 Size target

`TARGET_ROWS = 10 GB ÷ the table's average row size`, capped at 250M rows. Wide tables get fewer rows per
chunk, so chunks come out similar in size. A table no bigger than the target is **one chunk**.

### 6.3 Cutting

1. Count rows per axis day.
2. Walk the days in order, grouping whole days into a chunk until the next day would push it over the
   target.
3. A day that alone exceeds the target is split. First by minute ranges of `GRS_REFINED_TIMESTAMP` within
   the day. If NULLs or a single minute prevent that, by even hash buckets on `GRS_UNIQUE_ID` within the
   day.
4. NULL axis values get their own chunk.
5. Check that Σ chunk rows equals the table's rows, or the table is `FAILED`.

### 6.4 Technique ranking (best first; chosen day by day)

| Rank | Technique | What each chunk reads |
|---|---|---|
| 1 | Whole partition days (`DAY_RANGE`) | Only its own days' files |
| 2 | Day + `GRS_REFINED_TIMESTAMP` range (`DAY_SUBRANGE`) | Only that day's files |
| 3 | Day + hash bucket (`DAY_HASH`) | That day's files, once per bucket |
| 4 | Refined-timestamp days on an unpartitioned table | Depends on file layout |
| 5 | Whole-table hash (`HASH`) | The whole table, every chunk |

### 6.5 Ranges

- **Half-open.** A row is in a chunk when `start ≤ value < end`; each chunk ends where the next begins.
- **Open ends.** The very first and very last day ranges are open-ended (`NULL`).
- **Typed boundaries.** Dates for days; `TIMESTAMP_TZ` (UTC) for in-day ranges, because every source
  timestamp is `TIMESTAMP_LTZ` and NTZ boundaries would shift with the reader's session time zone.

Worked examples are in `design_review.md` §4.7.

## 7. Metadata tables

DDL: `sql/01_metadata_ddl.sql`.

- **`HIST_PLAN_TABLE`** — one row per table per plan. Holds:
  - identity, object type, layer;
  - chunk axis and its columns, and whether the partition spec confirmed them;
  - chunk method and chunk count;
  - total rows and bytes, average row and file size;
  - the size target used;
  - **status** (`PLANNED` / `FAILED` / `SKIPPED` / `SUPERSEDED`), the reason, and the active flag.
- **`HIST_PLAN_CHUNK`** — one row per chunk. Holds:
  - plan and sequence;
  - chunk type;
  - `DAY_START` / `DAY_END`;
  - `SUB_COLUMN` with `SUB_START_TS` / `SUB_END_TS`, or `HASH_BUCKET` / `HASH_MODULUS`;
  - estimated rows and bytes.
- **Plans are never edited.** A re-plan (`p_force_replan = TRUE`) marks the old plan `SUPERSEDED` and inserts
  a new one, in one transaction.

## 8. Behaviour summary

| Situation | Result |
|---|---|
| Database or schema missing, or any listed table not found / ambiguous / not Iceberg | Every problem listed, run exits, **nothing written** |
| No table list | Every object in the schema; non-Iceberg ones `SKIPPED` with the reason (one current row each) |
| Table already planned | `SKIPPED` in the result grid unless `p_force_replan = TRUE` |
| Chunking can't be decided, or any error on a table | That table `FAILED` with the reason; the run continues |
| Run cancelled half-way | Finished tables keep their plans; a re-run continues with the rest |

## 9. Implementation and test kit (`sql/`)

| File | Purpose |
|---|---|
| `01_metadata_ddl.sql` | Creates the two metadata tables |
| `02_test_setup.sql` | Builds 11 synthetic objects, one per decision branch |
| `03_smoke_test.sql` | Proves every scripting construct the planner relies on works in the account |
| `04_chunk_planner.sql` | **The planner** |
| `05_validate.sql` | Expected-vs-actual checks, tiling and sum checks, and an exactly-once coverage proof against the source data |
| `06_reset_test_metadata.sql` | Clears the test schema's metadata rows |
| `TEST_PLAN.md` | Run sequence R0–R9, expected results, evidence checklist E01–E17 |
| `CLIENT_RUNBOOK.md` | Running against real tables in a client environment: `01` once, then `04`; privileges, checks, re-runs |

## 10. Assumptions and limitations

- Identity partitions only, as in the reference DDL. Other transforms (`day(ts)`, `bucket[N]`, …) fall back to
  rules 5–6. That is still correct, but file skipping is not guaranteed.
- The size target (10 GB / 250M rows) is reasoned, not measured. It is a variable if the load team wants
  something else.
- Row counts are exact at `PROFILED_AT`. If a CURRENT table changes before it is loaded, the counts drift.
  How the loader handles that is out of scope.
- The script has not yet been run against Snowflake. `TEST_PLAN.md` is the verification.
