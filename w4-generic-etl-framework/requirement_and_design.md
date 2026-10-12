# Generic ETL framework — requirement and design log

A single configuration-driven ETL framework in IDMC, serving every load type and every team, built on the
existing ABC metadata tables.

**Stage**: architecture design. **No build has started.**
**Design lead**: Nikhil.
**This file is a living design log.** Each aspect is worked to closure, then recorded here with its
rationale. Status markers are used throughout: **CLOSED** · **PROPOSED** · **OPEN**.

---

## 1. Requirement

One generic ETL framework, configured in IDMC, that caters for **all load types** across all teams:

- full load
- incremental load
- catchup load
- history load
- daily incremental
- static table loads
- truncate and load
- SCD1 table load
- SCD2 table load

The pipeline must include all cross-cutting functionality:

- **data quality checks**
- **reconciliation / balancing**
- **dependency checks**
- **parent-child relationships between tables**
- **tables that can run in parallel, via grouping**
- and other scenarios as they emerge

**It must be configuration-based**, so that one framework serves all teams and all requirements.

**It must use the ABC tables.** Existing ABC tables and columns are leveraged wherever they already serve;
otherwise new tables are created or new columns added to existing tables.

### Original proposal, now superseded
The requirement as first stated included: *"1 IDMC taskflow which will serve history load and static tables
load, and 1 IDMC taskflow to serve other types of load."*

This is recorded because it was the starting point, but it is **superseded** — see **D-07** and **OQ-02**.
Static and history are not siblings; their only commonality is that most optional modules are switched off
for static, which is gate configuration rather than a different control structure.

---

## 2. Scope and non-goals

| In scope | Out of scope |
|---|---|
| Architecture of the framework and its configuration model | Build / implementation |
| The load-type model, window derivation, write strategies | Computing chunk boundaries — see §4 |
| DQ, reconciliation, dependency, grouping, parallelism | Chunk-size tuning and warehouse sizing |
| Reuse and extension of the ABC metadata and runtime tables | Changing ABC's existing column semantics |
| How Stonebranch, IDMC, Aurora and Snowflake divide the work | Replacing Stonebranch or IDMC |
| **File-based sources — REMOVED from scope, see D-06** | |

---

## 3. Related workstreams

Cross-references use relative paths per the repository convention.

| Workstream | Relationship |
|---|---|
| [`../w2-abc-framework/reference.md`](../w2-abc-framework/reference.md) | **Foundation.** The ABC framework this design extends. Its metadata and runtime tables, phase sequence, flag semantics and known defects are the starting point. Read §4, §9 and §16 before reviewing this design |
| [`../history_load_chunking_design/solution_design.md`](../history_load_chunking_design/solution_design.md) | **Upstream producer.** Profiles Iceberg tables and writes a chunk plan. This framework is the consumer of that plan — see §4 |
| [`../w3-scd-effective-date-split/solution_design.md`](../w3-scd-effective-date-split/solution_design.md) | **Constrains the write-strategy axis.** Proves a single `MERGE` into an SCD2 target fails at runtime for multi-source effective-date splits. See D-11 |

---

## 4. The seam with the chunk planner

This matters enough to state before anything else, because it corrects an earlier assumption in this design.

The chunk planner workstream owns **how a large table should be cut**. Its scope note is explicit:

> *"The plan is written to a metadata table. Whatever performs the load reads it later."*

Its out-of-scope list includes loading data, building the per-chunk extraction or load SQL, reconciliation,
retries and orchestration. **All of those are this framework's job.** The seam is therefore clean:

```
  chunk planner  ──writes──▶  HIST_PLAN_TABLE          ──read by──▶  this framework
  (Snowflake                  HIST_PLAN_CHUNK                        (orchestrates and
   Scripting)                 (plan + per-chunk ranges)               executes each chunk)
```

**Consequences for this design:**

1. **This framework does not compute chunk boundaries, chunk counts, or chunk axes.** It iterates the active
   plan's `HIST_PLAN_CHUNK` rows in sequence.
2. **The chunking threshold is not our config.** The planner fixes it at 10 GB of Iceberg data and at most
   250M rows per chunk (its D8/D14), set as script variables. Our engine honours whatever chunk count the
   plan contains.
3. **Our config carries a reference to the plan, not chunk parameters.** This replaces the
   `chunk_size` / `chunk_column` / `chunk_threshold_rows` fields proposed earlier in the discussion.
4. **Plan status must be respected.** The planner holds status per table (`PLANNED` / `FAILED` / `SKIPPED` /
   `SUPERSEDED`) and never edits a plan — a re-plan supersedes the old one. Our engine must read only the
   **active** plan and must refuse to run a chunked load whose plan is `FAILED` or absent.

**Platform constraint learned from that workstream:** **stored procedures are not allowed** in that
environment (planner scope table). This removes "write strategies as Snowflake stored procedures" from the
options for the write-strategy library.

**OQ-05** tracks the remaining question on this seam: whether row-count drift between `PROFILED_AT` and
actual load time needs handling in our engine. The planner explicitly leaves it to the loader.

---

## 5. Core modelling principle

The requirement lists nine load types. **Modelling them as nine things is a combinatorial trap** — every new
requirement multiplies against every existing one, and the engine ends up knowing about specific load types.
That is how ABC ended up with metadata tables whose code still hard-codes per-table behaviour.

The nine names are **not nine things**. They sit on **three independent axes**:

| Axis | What it describes | Belongs to |
|---|---|---|
| **Window derivation** | how much source data this run reads | the run |
| **Target table type** | what shape the target keeps | the table |
| **Write strategy** | the mechanism that lands the data | the table (volume may override) |

A "load type" is therefore nothing more than a **named preset** — a row of axis values. The engine never
learns the words "full load" or "SCD2". Adding a tenth load type is a config insert, not a release.

### The acceptance test for "configuration based"

> **No table name, column name, rule, threshold or SQL fragment may appear in any IDMC artifact.**

If one does, it is a design bug. ABC fails this test in exactly two places — hand-coded DQ predicates in the
stage mappings, and raw SQL in parameter files — and that is precisely why its configuration-driven promise
only half works.

---

## 6. Architecture decomposition — seven categories

```
┌──────────────────────────────────────────────────────────────────┐
│  A  ORCHESTRATION & DEPENDENCY            ← Stonebranch          │
│     DAG · parallel groups · triggers · calendars · SLA           │
└───────────────────────────┬──────────────────────────────────────┘
                            │ invokes, one table at a time
┌───────────────────────────▼──────────────────────────────────────┐
│  C  EXECUTION ENGINE                      ← IDMC                 │
│     invariant taskflow skeleton · gates · phase sequence         │
└──────┬──────────────────────────────────┬────────────────────────┘
       │ reads                            │ delegates
┌──────▼─────────────────────┐  ┌─────────▼────────────────────────┐
│  B  CONFIGURATION MODEL    │  │  D  LOAD STRATEGY LIBRARY        │
│     ← Aurora (ABC)         │  │     ← Snowflake                  │
│  single source of truth    │  │  window resolution · write        │
│  axes & presets            │  │  patterns · set-based SQL         │
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

### The placement principle

> **Put each responsibility where it is purpose-built and cheapest to change.**
>
> - *When, in what order, how many at once* → **the scheduler**
> - *What a table is, what rules apply to it* → **the config database**
> - *Which steps run for this table* → **the engine, as gates** — never as new branches
> - *Set-based data manipulation* → **push to the warehouse**; IDMC orchestrates, Snowflake computes
> - *What happened* → **the audit tables**

| # | Category | Owns | Lives in | Status |
|---|---|---|---|---|
| A | Orchestration & dependency | triggering, the DAG, parallel groups, concurrency limits, calendars, SLA, job retry | Stonebranch | PROPOSED |
| B | Configuration model | the declarative definition of every table, rule, metric, edge, strategy, preset | Aurora (ABC) | PROPOSED |
| C | Execution engine | the invariant config-driven runtime; the skeleton and its gates | IDMC | PROPOSED |
| D | Load strategy library | window resolution and the pluggable write patterns | Snowflake | PROPOSED |
| E | Quality & reconciliation | rule execution, severity routing, metric computation, thresholds, verdict | Snowflake + config | PROPOSED |
| F | State, restart & observability | run state machine, idempotency, audit trail, notifications, dashboards | Aurora + IDMC | PROPOSED |
| G | Governance & lifecycle | onboarding, config validation, promotion, versioning, ownership | process + Liquibase | PROPOSED |

---

## 7. Aspect 1 — Load type strategies · **CLOSED**

Closed on the basis of the analysis in §8 and the decisions in §9.

### 7.1 Window strategies — the engine implements three

| # | Strategy | How the window is derived |
|---|---|---|
| **W1** | `DERIVED_WATERMARK` | from the last successful run's high-water mark |
| **W2** | `EXPLICIT_RANGE` | from a supplied start and end |
| **W3** | `ALL_ROWS` | no filter — read everything |

~~W4 `FILE_DISCOVERY`~~ — **removed from scope**, see **D-06**.

### 7.2 Pass mode — an attribute, not a load type

`SINGLE` · `CHUNKED` — available to **every** window strategy.

Chunked execution iterates the active chunk plan from the chunk planner workstream (§4). It is not
history-specific: a very large full refresh needs it, and so does a wide incremental window after an outage.

### 7.3 Named load types — presets

| Load type | Window | Pass | Cleanup first | Notes |
|---|---|---|---|---|
| `INCREMENTAL` | W1 | either | no | frequency (daily/weekly/monthly) lives on the **schedule**, not here |
| `HISTORY` | W2 | usually chunked | no | one-time; target is empty |
| `CATCHUP` | W2 | either | no | **same pattern as `HISTORY`**; separate name kept for audit and governance |
| `REPLAY` | W2 | either | **yes** | reload of a corrected range over existing data |
| `FULL_REFRESH` | W3 | either | yes (implicit) | renamed from "static table load" — see D-04 |
| `SNAPSHOT_APPEND` | W3 | either | no | **OPEN — see OQ-01**; included provisionally |

**Five confirmed load types, three window strategies, one pending.**

### 7.4 What was eliminated, and why that is the point

| Eliminated | Became |
|---|---|
| "Daily incremental" as distinct from "incremental" | One `INCREMENTAL`. Frequency is schedule metadata — D-03 |
| "History chunked" vs "history unchunked" as two types | One `HISTORY`; pass mode is an attribute — D-05 |
| "Truncate and load" as a load type | A **write strategy** value — D-02 |
| "Static table load" as a load type | `FULL_REFRESH`, a window strategy — D-04 |
| "SCD1 / SCD2 table load" as load types | **Target table types** — D-10 |
| ABC's "first-time incremental" (`batch_rerun_flag='I'`) | **Not a load type at all** — just `INCREMENTAL` with a seeded watermark — D-09 |
| File-based load | Out of scope — D-06 |

D-09 is worth noting on its own: ABC made first-time incremental a whole execution type, with its own flag,
its own code path and its own never-built backlog item. Modelled as "seed one watermark row", it disappears
entirely. **One of ABC's three unbuilt load types is removed rather than implemented.**

---

## 8. Analysis record

The reasoning behind §7, kept because reviewers will ask.

### 8.1 Static table vs truncate-and-load vs full load

They feel overlapping because they sit on **three different axes**:

| Name | What it actually is | Axis |
|---|---|---|
| Static table | a table classification — volatility and role | target table type |
| Truncate and load | a mechanism | write strategy |
| Full load | an extract scope | window derivation |

They co-occur often but vary independently:

- **A full load does not imply truncate.** You can read every source row and land it via MERGE, preserving
  surrogate keys and the target's audit history. For a dimension, truncate-and-reload **destroys surrogate
  keys and audit history** — usually unacceptable.
- **A static table should not always be truncated.** A static reference table that is an **RI parent** must
  not be truncated: truncate+insert momentarily empties it, and a concurrent child load orphans every row.
  Such tables use `MERGE_SCD1`, or the truncate is wrapped so the empty window is never visible.
- **"Full load" hides a fourth operation** — full refresh **with delete detection**. If the source can lose
  rows and the target must reflect it, Snowflake's missing `WHEN NOT MATCHED BY SOURCE` means an explicit
  anti-join sweep is required. That is a distinct post-step.

### 8.2 Daily incremental vs incremental

No difference. "Daily" is a **frequency**, and frequency is a scheduling attribute belonging to Category A.
Window-derivation logic is identical for hourly, daily, weekly and monthly — take the last successful
watermark, take the upstream end time, read between them. Only the resulting interval differs, and that is
data.

The one case that could justify a second value is **intra-day micro-batch where runs may overlap** — but
that is a concurrency-control requirement (a mutex in Category A), not a different derivation.

### 8.3 Why `FULL_REFRESH` and not `STATIC_LOAD`

Staticness is a property of the *table*; full refresh is a property of the *load*. Naming the strategy
"static" would hide its most important other use: **it is the fallback for any table whose source has no
reliable watermark or CDC column.** That is a common real case. Teams reading "static load" would reach for
incremental on tables that cannot support it.

### 8.4 Why write strategy is not simply MERGE everywhere

MERGE **is** right for the common case — single-source SCD1 and SCD2 dimensions — and `INCREMENTAL` and
`CATCHUP` should use **the same strategy as each other** for a given table. If they differ, two code paths
can produce subtly different results for the same table.

Six cases where MERGE is not the answer:

| # | Case | Why MERGE fails or is wrong |
|---|---|---|
| a | **Multi-source SCD2 effective-date split** | Fails **at runtime**. The live target row matches both the `D` row and an `I` row on `(key, eff_dte)`, and `ERROR_ON_NONDETERMINISTIC_MERGE` is on by default. Adding `exp_dte` to the key fixes one case and not the one where a source corrects a value without moving its dates. Proven in W3 with 26 passing assertions |
| b | **Append-only fact / event tables** | You never update a past transaction. Upserting a ledger is semantically wrong and needlessly expensive |
| c | **Delete detection** | Snowflake has no `WHEN NOT MATCHED BY SOURCE`; a MERGE cannot soft-delete vanished rows |
| d | **Backdated / out-of-order SCD2 arrivals** | ABC computes `change_flag` separately for forward-dated and back-dated records and UNIONs them. A plain upsert on business key corrupts the timeline instead of splicing into it |
| e | **ABC's own "MERGE" is not an upsert** | Broker's stage→target MERGE has **four** match branches — update non-key columns, update expiration date only, update `zone1_uuid` only, insert — and one record can hit two. The `zone1_uuid`-only branch is the entire mechanism by which Zone 1 reruns are absorbed without target cleanup |
| f | **Volume** | At history or large-catchup scale a MERGE over a huge delta can lose badly to rebuild-and-swap. This is the one case where strategy varies by **run** rather than by table |

### 8.5 Gaps found in the stated requirement

| Gap | Resolution |
|---|---|
| **Replay / rerun was missing** — the most operationally common range reload | Added as `REPLAY`. It reuses W2 but has a precondition the others lack: the target already holds data for that range and must be cleaned first. ABC treats it as first-class (`batch_rerun_flag='Y'`) and its cleanup is entirely manual today |
| **Snapshot append was missing** | Added provisionally as `SNAPSHOT_APPEND`; **OQ-01** |

---

## 9. Decisions log

| # | Decision | Status |
|---|---|---|
| D-01 | Nine load types are modelled as **three orthogonal axes plus named presets**, not as nine entities | CLOSED |
| D-02 | "Truncate and load" is a **write strategy**, not a load type | CLOSED |
| D-03 | Frequency (daily/weekly/monthly) lives on the **schedule**, not in the load model. One `INCREMENTAL` | CLOSED |
| D-04 | "Static table load" becomes **`FULL_REFRESH`**, a window strategy, reusable beyond static tables | CLOSED |
| D-05 | **Chunking is an attribute of any load**, available to every window strategy — not a variant of history | CLOSED |
| D-06 | **File-based sources are out of scope.** Re-entry cost if added later: a fourth window strategy (`FILE_DISCOVERY`), a file registry, format validation ahead of row-level DQ, and trailer/control-total reconciliation. ABC has unused file-related tables that would serve as the registry | CLOSED |
| D-07 | `HISTORY` and `CATCHUP` share **one execution pattern** but keep **two names**, for audit and governance clarity. Two names over one pattern cost nothing | CLOSED |
| D-08 | `REPLAY` is a distinct named load type because of its **cleanup precondition** | CLOSED |
| D-09 | ABC's "first-time incremental" is **eliminated** — it is `INCREMENTAL` with a seeded watermark | CLOSED |
| D-10 | SCD1 / SCD2 are **target table types**, not load types. A third level is needed: table type + window → eligible write strategy | CLOSED |
| D-11 | **At least five write strategies, two of them for SCD2** (`MERGE_SCD2` single-source, `DIFF_SCD2` multi-source/backdated), because a single MERGE provably fails. Write strategy is selected by config, never by an IDMC branch | PROPOSED |
| D-12 | **This framework consumes the chunk plan; it does not compute it.** Chunk boundaries, counts, axes and the size threshold belong to the chunk planner workstream | CLOSED |
| D-13 | **Write strategies cannot be Snowflake stored procedures** — not permitted in this environment | CLOSED |
| D-14 | **One taskflow invocation = one target table.** Parallelism becomes entirely a scheduler concern and the data-driven fan-out problem inside IDMC disappears | PROPOSED |
| D-15 | **Stonebranch executes the DAG; config declares it.** Dependency in IDMC would mean editing a taskflow to add a table, which breaks the configuration-driven promise. Stonebranch workflows are generated from, or reconciled against, the declared DAG so dependency is never GUI-only | PROPOSED |
| D-16 | The engine additionally performs a **cheap defensive dependency gate** — is my parent's run complete for this `execution_run_id`? Not the primary mechanism; a guard, so a scheduler misconfiguration cannot silently corrupt data | PROPOSED |
| D-17 | **Extend ABC additively** — new config tables, existing runtime tables reused as-is. New tables have zero blast radius on Zone 1, removing the hardest negotiation | PROPOSED |
| D-18 | **Aurora config is the single source of truth.** IDMC parameter files hold environment-scoped values only (connections, config schema, service account). Nothing table-specific | PROPOSED |
| D-19 | **DQ predicates are generated from config**, via parameterized expression templates in `rule_master`. ABC's DQ metadata is decorative because `rule_id` and severity are typed into each mapping by hand — so deactivating a rule in config does nothing | PROPOSED |
| D-20 | **One reconciliation metric definition generates both the source and target aggregate.** ABC hand-builds the source side in the mapping and takes the target side as raw SQL from a parameter file, requiring the same column name to match in three places | PROPOSED |
| D-21 | **Prefer idempotent recompute over compensating cleanup.** W3 demonstrates it: recompute the diff against whatever the target holds now, and restart needs no unwind. Design restart out of existence where the strategy allows | PROPOSED |
| D-22 | **Parent-child is two problems, not one.** Orchestration dependency (load parent table before child table) is a DAG in Stonebranch. Row-level RI fallback (child row before parent row) is ABC's existing RA mechanism with its daily `process_flag` loop. Different mechanisms, different tables | PROPOSED |
| D-23 | **Config is schema-validated before it can run**, including a table-type × write-strategy **compatibility matrix**. `APPEND_ONLY` + `MERGE_SCD2` is nonsense; `SCD2` + `TRUNCATE_INSERT` silently destroys history | PROPOSED |
| D-24 | **Notifications are config-driven and severity-tiered.** ABC emits 11 notifications for a 10-job batch on every successful run, which trains people to ignore them | PROPOSED |

---

## 10. Open questions

| # | Question | Blocks | Owner |
|---|---|---|---|
| **OQ-01** | **Are there month-end snapshot tables** — policy-in-force, reserves — where every snapshot is retained rather than overwritten? If yes, `SNAPSHOT_APPEND` stays and needs its own write strategy. If no, the load-type list is five, not six | closing §7 fully | Nikhil — **confirming** |
| **OQ-02** | **How many taskflows?** D-05 made chunking an attribute available everywhere. If the chunk loop degenerates to a single iteration when chunking is off, **one** taskflow suffices rather than two. Settle in Category C | Category C | design |
| **OQ-03** | Does IDMC support **data-driven parallel fan-out** — N parallel sub-taskflows where N comes from a config query — or are parallel paths fixed-width? Determines whether grouping can live in IDMC at all. D-14 and D-15 are chosen so that the answer does not block the design | Category A | research |
| **OQ-04** | Can a mapping task take a **fully dynamic SQL override** from a runtime variable? With D-13 ruling out stored procedures, this is the remaining mechanism for a config-generated write strategy | Category D | research |
| **OQ-05** | The chunk planner records exact row counts at `PROFILED_AT` and notes that counts drift if a CURRENT table changes before loading, leaving handling to the loader. **Does our engine need to detect and handle that drift?** | Category D | design |
| **OQ-06** | The **Create Temporary View vs pushdown vs update/upsert** tension: W3 states it is mandatory before configuring update/upsert/delete; ABC had to untick it because a MERGE broke pushdown. Both cannot hold for a framework that does both | Category D | research |
| **OQ-07** | Is **CDC / stream-based acquisition** ever in scope for Zone 2 — Snowflake streams, Kafka? Zone 1 uses DMS/CDC upstream. Not added speculatively | scope | Nikhil |
| **OQ-08** | Does the **delete-detection** sweep (§8.1) apply to any current table, or is it hypothetical? | Category D | Nikhil |

---

## 11. Aspect order

Aspects are worked one at a time to closure.

| Order | Aspect | Category | Status |
|---|---|---|---|
| 1 | **Load type strategies** | B | **CLOSED** (pending OQ-01) |
| 2 | **Window derivation mechanics** — W1 in particular | B / D | next |
| 3 | Execution engine skeleton, gates, phase sequence | C | |
| 4 | Write strategy library and the compatibility matrix | D | |
| 5 | DQ and reconciliation from config | E | |
| 6 | Full configuration schema and DDL deltas against ABC | B | |
| 7 | Orchestration, DAG declaration and grouping | A | |
| 8 | State, restart and observability | F | |
| 9 | Governance and lifecycle | G | |

**Aspect 2 is next** because W1 is where ABC's existing sourcing-window machinery
(`etl_data_ingestion_metadata`, `etl_data_ingestion_source_window`, and the per-source-table window
derivation) either fits this model or has to be replaced. That is the single largest reuse-or-rebuild
decision in the design, and D-17 depends on its answer.
