# Generic ETL framework — requirement and design log

A single configuration-driven ETL framework in IDMC, serving every load type and every team, built on the
ABC metadata tables in Aurora.

**Stage**: architecture design. **No build, no POC.**
**Design lead**: Nikhil.

**This is a fresh design.** It is not a continuation of, and does not inherit decisions from, any earlier
proof of concept in this repository. The ABC framework is referenced for **background and for its existing
Aurora table structure only** — so that this design can decide what to reuse, what to extend and what to
create. Nothing is treated as settled because an earlier POC settled it.

Status markers throughout: **CLOSED** · **PROPOSED** · **OPEN**.

---

## 1. Requirement

One generic ETL framework, configured in IDMC, catering for **all load types** across all teams:

full load · incremental load · catchup load · history load · daily incremental · static table loads ·
truncate and load · SCD1 table load · SCD2 table load

The pipeline must include all cross-cutting functionality:

- **data quality checks**
- **reconciliation / balancing**
- **dependency checks**
- **parent-child relationships between tables**
- **tables that can run in parallel, via grouping**
- and other scenarios as they emerge

**It must be configuration-based**, so one framework serves all teams and all requirements.

**It must use the ABC tables.** Existing ABC tables and columns are leveraged where they already serve;
otherwise new tables are created, or new columns added to existing tables.

---

## 2. Scope and non-goals

| In scope | Out of scope |
|---|---|
| Architecture of the framework and its configuration model | Build / implementation |
| The load-type model, window derivation, write strategies | Tuning: chunk sizes, warehouse sizing, thresholds |
| DQ, reconciliation, dependency, grouping, parallelism | Replacing Stonebranch or IDMC |
| Reuse, extension and creation of Aurora metadata tables | Restructuring tables Zone 1 depends on — see §5 |
| How Stonebranch, IDMC, Aurora and Snowflake divide the work | |
| **File-based sources — out of scope, see D-06** | |

---

## 3. Background reference

| Reference | Used for |
|---|---|
| [`../w2-abc-framework/reference.md`](../w2-abc-framework/reference.md) | **Background only.** The existing ABC framework: its Aurora metadata and runtime table structure, its phase sequence, and its known structural limits. §4 (metadata tables), §13 (table catalogue) and §16 (gaps) are the relevant parts |

Other workstreams in this repository are **not** inputs to this design.

---

## 4. Design principles

### 4.1 Load types are axes, not a list

The requirement names nine load types. Modelling them as nine things is a combinatorial trap: every new
requirement multiplies against every existing one, and the engine ends up knowing about specific load types.

The nine names sit on **three independent axes**:

| Axis | What it describes | Belongs to |
|---|---|---|
| **Window derivation** | how much source data this run reads | the run |
| **Target table type** | what shape the target keeps | the table |
| **Write strategy** | the mechanism that lands the data | the table (volume may override) |

A load type is a **named preset** — a row of axis values. The engine never learns the words "full load" or
"SCD2". Adding a tenth load type is a config insert, not a release.

### 4.2 The acceptance test for "configuration based"

> **No table name, column name, rule, threshold or SQL fragment may appear in any IDMC artifact.**

If one does, it is a design bug. This is the single test that separates a framework from a convention.

### 4.3 Placement

> Put each responsibility where it is purpose-built and cheapest to change.
>
> - *When, in what order, how many at once* → **the scheduler**
> - *What a table is, what rules apply to it* → **the config database**
> - *Which steps run for this table* → **the engine, as gates** — never as new branches
> - *Set-based data manipulation* → **push to the warehouse**; IDMC orchestrates, Snowflake computes
> - *What happened* → **the audit tables**

### 4.4 Config is declarative and validated

Config that can express nonsense eventually will. Every axis value is drawn from a registry, and valid
combinations are enforced before a pipeline can run — not discovered at 2am.

---

## 5. The constraint that shapes the data model

**`batch_metadata`, `job_metadata`, `batch_run_stats`, `job_run_stats` and `job_error_stats` are shared with
Zone 1**, which runs a *different* framework on the same physical tables.

This is the hardest constraint in the design, and it dictates a rule:

> **Add nullable columns to shared tables if unavoidable. Never restructure them. Put new concepts in new
> tables, FK'd to the existing ones.**

New tables have zero blast radius on Zone 1 and need no negotiation. That makes "create new" the default and
"modify existing" the exception, which is the opposite of the instinct but the right call here.

---

## 6. Architecture decomposition — seven categories

```
┌──────────────────────────────────────────────────────────────────┐
│  A  ORCHESTRATION & DEPENDENCY            ← Stonebranch          │
│     DAG · parallel groups · triggers · calendars · SLA           │
└───────────────────────────┬──────────────────────────────────────┘
                            │ invokes, one pipeline at a time
┌───────────────────────────▼──────────────────────────────────────┐
│  C  EXECUTION ENGINE                      ← IDMC                 │
│     invariant taskflow skeleton · gates · phase sequence         │
└──────┬──────────────────────────────────┬────────────────────────┘
       │ reads                            │ delegates
┌──────▼─────────────────────┐  ┌─────────▼────────────────────────┐
│  B  CONFIGURATION MODEL    │  │  D  LOAD STRATEGY LIBRARY        │
│     ← Aurora               │  │     ← Snowflake                  │
│  single source of truth    │  │  window resolution · write        │
│  axes · presets · registry │  │  patterns · set-based SQL         │
└────────────────────────────┘  └──────────────────────────────────┘
       ▲                                  ▲
       │              ┌───────────────────┴──────────────┐
       │              │  E  QUALITY & RECONCILIATION     │
       │              │     rules from config · verdicts │
       │              └──────────────────────────────────┘
┌──────┴───────────────────────────────────────────────────────────┐
│  F  STATE, RESTART & OBSERVABILITY   │  G  GOVERNANCE & LIFECYCLE│
│     run state · idempotency · audit  │     onboarding · validation│
│     notifications · dashboards       │     promotion · versioning │
└──────────────────────────────────────┴───────────────────────────┘
```

| # | Category | Owns | Lives in |
|---|---|---|---|
| A | Orchestration & dependency | triggering, the DAG, parallel groups, concurrency limits, calendars, SLA, retry |Stonebranch |
| B | Configuration model | the declarative definition of every pipeline, rule, metric, edge, strategy, preset | Aurora |
| C | Execution engine | the invariant config-driven runtime; the skeleton and its gates | IDMC |
| D | Load strategy library | window resolution and the pluggable write patterns | Snowflake |
| E | Quality & reconciliation | rule execution, severity routing, metrics, thresholds, verdict | Snowflake + config |
| F | State, restart & observability | run state machine, idempotency, audit trail, notifications, dashboards | Aurora + IDMC |
| G | Governance & lifecycle | onboarding, config validation, promotion, versioning, ownership | process |

---

## 7. Aspect 1 — Load type model · **CLOSED**

### 7.1 Window strategies — the engine implements three

| # | Strategy | How the window is derived |
|---|---|---|
| **W1** | `DERIVED_WATERMARK` | from the stored high-water mark for this pipeline |
| **W2** | `EXPLICIT_RANGE` | from a supplied start and end |
| **W3** | `ALL_ROWS` | no filter — read everything |

### 7.2 Pass mode — an attribute of any load

`SINGLE` · `CHUNKED`, available to **every** window strategy. Not history-specific: a very large full refresh
needs it, and so does a wide incremental window after an outage.

**Chunk boundaries are derived at run start from config, and persisted per run.** See D-05 and D-12.

### 7.3 Named load types — presets

| Load type | Window | Pass | Notes |
|---|---|---|---|
| `INCREMENTAL` | W1 | either | frequency (daily/weekly/monthly) lives on the **schedule**, not here |
| `HISTORY` | W2 | usually chunked | bulk range |
| `CATCHUP` | W2 | either | same pattern as `HISTORY`; separate name for audit and governance |
| `REPLAY` | W2 | either | reload of a corrected range over existing data |
| `FULL_REFRESH` | W3 | either | the "static table" case, and the fallback for any source with no reliable watermark |
| `SNAPSHOT_APPEND` | W3 | either | **OPEN — OQ-01**; provisional |

### 7.4 What was eliminated

| Eliminated | Became |
|---|---|
| "Daily incremental" vs "incremental" | One `INCREMENTAL`; frequency is schedule metadata — D-03 |
| "History chunked" vs "history unchunked" | One `HISTORY`; pass mode is an attribute — D-05 |
| "Truncate and load" as a load type | A **write strategy** value — D-02 |
| "Static table load" as a load type | `FULL_REFRESH`, a window strategy — D-04 |
| "SCD1 / SCD2 table load" as load types | **Target table types** — D-10 |
| File-based load | Out of scope — D-06 |

---

## 8. Aspect 2 — Configuration data model · **IN PROGRESS**

### 8.1 What config must express

For any pipeline, the framework must know: **identity and ownership · batch membership · execution group ·
source binding · window strategy · target binding · target table type · write strategy · pass mode and
chunking · dependencies · quality rules · reconciliation metrics · operational attributes** — and,
separately from config, **what happened** at runtime.

### 8.2 The existing ABC metadata tables, assessed

| ABC table | Grain | Serves this design? |
|---|---|---|
| `batch_metadata` | source + domain + layer + zone | **Yes, as-is.** Batch identity. Shared with Zone 1 |
| `job_metadata` | one target table | **Partly** — see 8.3. Shared with Zone 1 |
| `etl_data_ingestion_metadata` | one source table per job | **Yes** — the target↔source map, already multi-row for multi-source |
| `job_rule_master` | one rule, globally | **Structurally yes**, but not executable — no expression template |
| `job_rule_assignment` | one rule per column per job | **Structurally yes**, but no rule parameters |
| `balance_reconciliation_metadata` | one metric | **Yes, close** — metric type, column, threshold type and value all present |
| batch-prerequisite config table | one dependency | **No** — upstream-batch gating only, not a table-level DAG |

### 8.3 Two structural findings

**Finding 1 — `job_metadata` conflates *what the table is* with *how it is loaded*.**

One row = one table = one load behaviour. But the requirement needs the **same table** loaded by `HISTORY`
once, then `CATCHUP`, then `INCREMENTAL` daily. In ABC the load type lives on the *run*, not on config, which
is why its history/catchup/first-time-incremental variants were never expressible as configuration at all.

> **The fix: a new `load_pipeline` table, one row per (table × load type).** A table has as many pipelines as
> load types it supports. The run names a pipeline, not a load type. This is the keystone of the config model
> and it is a new table, not a change to `job_metadata` — which §5 requires anyway.

**Finding 2 — the watermark should be a first-class, writable entity.**

ABC derives the sourcing window from run history and a per-run source-window table. That makes three
operations awkward: seeding a brand-new pipeline, replaying a range, and auditing why a window was what it
was.

> **The fix: an explicit `pipeline_watermark` table**, one row per (pipeline, source object), holding the last
> successful high-water mark. Seeding becomes an insert. `REPLAY` becomes a scoped override. The derivation
> becomes auditable. And ABC's entire "first-time incremental" special case disappears — D-09.

### 8.4 Reuse / extend / create map · **PROPOSED**

**Reuse as-is — runtime and audit.** Shapes are sound and already carry the counts, flags and error grain
this design needs: `batch_run_stats`, `job_run_stats`, `job_error_stats`, `job_rule_execution_log`,
`job_rule_error_detail`, `balance_reconciliation_stats`.

**Reuse as-is — config:** `batch_metadata`, `etl_data_ingestion_metadata`.

**Extend with nullable columns:**

| Table | Add | Why |
|---|---|---|
| `job_rule_master` | `rule_expression_template`, `parameter_spec` | Makes DQ executable from config — D-19 |
| `job_rule_assignment` | `rule_parameters` | Per-binding parameters (length, format, allowed set) |
| `balance_reconciliation_metadata` | `metric_expression` | One definition generates both source and target aggregate — D-20 |

**Create new:**

| New table | Grain | Purpose |
|---|---|---|
| `load_pipeline` | table × load type | **The keystone.** Window strategy, write strategy, pass mode, chunk config, active flag, owner |
| `execution_group` | group | Parallel grouping and concurrency limit |
| `pipeline_dependency` | edge | The table-level DAG, declared as data — D-15 |
| `pipeline_watermark` | pipeline × source object | The high-water mark, first-class and writable |
| `strategy_registry` | strategy | The closed set of window and write strategies |
| `strategy_compatibility` | table type × write strategy | Validation matrix — D-23 |
| `pipeline_run_chunk` | run × chunk | *Runtime.* Derived chunk boundaries and per-chunk status, for chunk-level restart — D-12 |

---

## 9. Decisions log

| # | Decision | Status |
|---|---|---|
| D-01 | Nine load types are modelled as **three orthogonal axes plus named presets** | CLOSED |
| D-02 | "Truncate and load" is a **write strategy**, not a load type | CLOSED |
| D-03 | Frequency lives on the **schedule**, not in the load model. One `INCREMENTAL` | CLOSED |
| D-04 | "Static table load" becomes **`FULL_REFRESH`**, reusable beyond static tables | CLOSED |
| D-05 | **Chunking is an attribute of any load**, available to every window strategy | CLOSED |
| D-06 | **File-based sources out of scope.** Re-entry cost: a fourth window strategy, a file registry, format validation ahead of row-level DQ, trailer/control-total reconciliation | CLOSED |
| D-07 | `HISTORY` and `CATCHUP` share **one pattern**, keep **two names**, for audit and governance | CLOSED |
| D-08 | `REPLAY` is a distinct named load type | CLOSED |
| D-09 | "First-time incremental" is **eliminated** — it is `INCREMENTAL` with a seeded watermark | CLOSED |
| D-10 | SCD1 / SCD2 are **target table types**, not load types. Table type + window → eligible write strategy | CLOSED |
| D-11 | **Write strategy is a pluggable library selected by config, never by an IDMC branch.** The set, and whether SCD2 needs more than one implementation, is settled in Category D against our own target shapes | PROPOSED |
| D-12 | **Chunk boundaries are derived at run start from declared chunk config, and persisted per run** with per-chunk status, so a chunked load restarts at the failed chunk. Not static config — static boundaries go stale as data grows | PROPOSED |
| D-13 | **One taskflow invocation = one pipeline.** Parallelism becomes entirely a scheduler concern | PROPOSED |
| D-14 | **Stonebranch executes the DAG; config declares it.** Dependency in IDMC would mean editing a taskflow to add a table, which breaks the configuration-driven promise | PROPOSED |
| D-15 | The engine also performs a **cheap defensive dependency gate** — a guard, so a scheduler misconfiguration cannot silently corrupt data | PROPOSED |
| D-16 | **New concepts go in new tables, FK'd to existing ones.** Shared tables take nullable columns at most, never restructuring — §5 | CLOSED |
| D-17 | **Aurora config is the single source of truth.** IDMC parameter files hold environment-scoped values only: connections, config schema, service account | PROPOSED |
| D-18 | **A `load_pipeline` table, one row per (table × load type)**, so the same table can be loaded by several load types as configuration — 8.3 Finding 1 | PROPOSED |
| D-19 | **DQ predicates are generated from config**, via parameterized expression templates | PROPOSED |
| D-20 | **One reconciliation metric definition generates both the source and target aggregate** | PROPOSED |
| D-21 | **The watermark is a first-class writable entity**, not derived from run history — 8.3 Finding 2 | PROPOSED |
| D-22 | **Parent-child is two problems.** Orchestration dependency is a DAG; row-level referential-integrity fallback is a data-plane concern. Different mechanisms, different tables | PROPOSED |
| D-23 | **Config is schema-validated before it can run**, including a table-type × write-strategy compatibility matrix | PROPOSED |
| D-24 | **Prefer idempotent write strategies so restart and replay need no compensating cleanup.** Cleanup is then a property of (write strategy × load type), derivable — not a per-load-type flag | PROPOSED |
| D-25 | **Notifications are config-driven and severity-tiered** | PROPOSED |

---

## 10. Open questions

| # | Question | Blocks | Owner |
|---|---|---|---|
| **OQ-01** | **Are there month-end snapshot tables** where every snapshot is retained rather than overwritten? If yes `SNAPSHOT_APPEND` stays and needs its own write strategy; if no the load-type list is five | closing Aspect 1 | Nikhil — confirming |
| **OQ-02** | **How many taskflows?** If the chunk loop degenerates to a single iteration when chunking is off, one taskflow suffices rather than two | Category C | design |
| **OQ-03** | Does IDMC support **data-driven parallel fan-out** — N parallel branches where N comes from a config query? D-13 and D-14 are chosen so the answer does not block the design | Category A | research |
| **OQ-04** | What mechanism lets a mapping task run **config-generated SQL** — dynamic SQL override, a generated view, or something else? Determines how the write-strategy library is delivered | Category D | research |
| **OQ-05** | **What target table types exist across the teams?** SCD1, SCD2, append-only fact, snapshot, reference — and in what proportion. Drives the write-strategy set | Category D | Nikhil |
| **OQ-06** | Are there targets fed by **more than one source table** where both carry history? That case decides whether SCD2 needs a second write strategy | Category D | Nikhil |
| **OQ-07** | Is **delete detection** required — must the target reflect rows that disappear from the source? | Category D | Nikhil |
| **OQ-08** | Is **CDC / stream acquisition** ever in scope for this framework? | scope | Nikhil |
| **OQ-09** | Can new tables be created in the **shared Aurora ABC schema**, or does this design need its own schema? Affects D-16's blast-radius argument | Category B | Nikhil |

---

## 11. Aspect order

| Order | Aspect | Category | Status |
|---|---|---|---|
| 1 | Load type model | B | **CLOSED** (pending OQ-01) |
| 2 | **Configuration data model** — entities, reuse/extend/create, DDL deltas | B | **in progress** |
| 3 | Window derivation mechanics | B / D | |
| 4 | Execution engine skeleton, gates, phase sequence | C | |
| 5 | Write strategy library and the compatibility matrix | D | |
| 6 | DQ and reconciliation from config | E | |
| 7 | Orchestration, DAG declaration and grouping | A | |
| 8 | State, restart and observability | F | |
| 9 | Governance and lifecycle | G | |
