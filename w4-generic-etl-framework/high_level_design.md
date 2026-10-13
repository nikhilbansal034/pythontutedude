# Generic ETL framework — high level design

> **High level only.** No column lists, no SQL, no thresholds, no watermark arithmetic. Where a mechanism
> is deliberately not decided here, it says so and names low-level design as its home.
>
> | | |
> |---|---|
> | [`high_level_design.xlsx`](high_level_design.xlsx) | the same content, structured — and the sheet we hang per-block detail off |
> | [`requirement_and_design.md`](requirement_and_design.md) · [`design_tracker.xlsx`](design_tracker.xlsx) | **PARKED.** See §6 |

---

## 1. The one acceptance test

**One taskflow serves every load type, and no block on the flow diagram branches on load type.**

A load type changes *parameter values*. It never changes the *path* through the flow. The moment a block
needs an *"if history, do this instead"*, the architecture has failed this test — and the fix is the design,
not the branch.

Everything below is built to be checkable against that one sentence.

---

## 2. Requirements settled with the design lead

Answered 13 October 2026. These are **facts the architecture must satisfy**, not options.

| # | The requirement | What it forces the architecture to do |
|---|---|---|
| **R-01** | Stonebranch triggers a **batch**, not a table | The taskflow has **two levels**. Batch-level reconciliation, one run identifier for audit, and one notification per business batch all need a batch scope that a per-table trigger cannot give |
| **R-02** | ABC holds batch membership. It holds **no lineage or dependency** between tables. A `group` column exists on `job_metadata` | Dependency edges are a **new** requirement with no ABC equivalent. The group column is the existing hook for parallelism and should be reused, not replaced — **HQ-01** |
| **R-03** | **One** taskflow, fully scalable, every scenario | No block may branch on load type. §1 |
| **R-04** | Runs **in parallel** with ABC; new development comes onto it once ready | No migration dependency, no backward-compatibility burden, own tables, ABC untouched. Nothing in production is put at risk |
| **R-05** | Source **and** target both in Snowflake | Full push-down is achievable for every load, so there is **no acquisition or staging block at all** — the framework is transform-and-load only. And every transformation must be push-down safe, because push-down is all-or-nothing |
| **R-06** | Control tables in Aurora · working copies in Snowflake · pushed back at post load | Two **named blocks** rather than an implementation detail: B6 and B10. Names a failure mode the architecture must make alertable — Aurora and Snowflake out of step |
| **R-07** | Stonebranch owns the **batch only**; table sequencing and parallelism belong to Aurora / Snowflake / IDMC | The framework builds its **own execution plan**. B7 — the largest new capability in the design |
| **R-08** | DQ failures handled **exactly as ABC** | Quality checking is **not a gate**. It is row routing *inside* the load plus a verdict *after* it |
| **R-09** | Reconciliation after the write, before the run is marked successful | No staging layer — which matters because push-down makes staging expensive. A failed recon fails the run with the data left **visible** |
| **R-10** | On a member failure the batch **continues**, as ABC does | Every member is attempted; Completed only with zero failures. Intra-batch dependency forces a **third** member outcome ABC has no concept of: **SKIPPED** |
| **R-11** | All transformation — joins, lookups, aggregation, dedup, derivation — is **parameterised SQL** executing on Snowflake, table by table | Transformation is **configuration, not framework code**. It also fixes the cleanest seam in the design: **team SQL** produces a prepared row set shaped like the target; **framework SQL** applies it. The team owns *what the rows are*, the framework owns *how they land* — so the write-strategy library is the only SQL the framework itself owns |
| **R-12** | Validating a team's SQL and mapping is **out of scope** — that is build's problem, not the design framework's | **B5 narrows** to *structural* validation: a cycle in the prerequisites, a member with no pipeline, a strategy illegal for its table type. It no longer implies anything about whether a query is correct or push-down safe |
| **R-13** | **Target → target prerequisite sequencing** is a missing feature, to be held in metadata. At load start a table reads its prerequisites, checks their load status, and starts only when all are complete | Two blocks, one metadata table. **B7** resolves the prerequisites into an **attempt order**; **T2** then *verifies* rather than schedules — so a prerequisite can never still be in progress when it is checked, and there is no waiting or polling. Exactly two outcomes at T2: completed → proceed, failed or skipped → **SKIPPED** |

### A correction to the record

I described `Partial` as an ABC *batch outcome* when asking R-10. That was imprecise.

**`Partial` is a Zone 1 batch status that Zone 2 only consumes** — Zone 2 may start when its source batch is
Completed *or* Partial. Zone 2's own batch status is `'C'` or `'F'` only: on a job failure the batch taskflow
increments `error_count` and continues to the next job, then zero errors → Completed, else Failed
(`reference.md:1469`, `:1757`). The flow follows the real ABC behaviour. Whether *this* framework's batch
should nevertheless gain a Partial outcome is **HQ-02**.

---

## 3. The flow

```
   LEVEL 1 · BATCH                                   LEVEL 2 · TABLE
   runs once per batch                               invoked once per member table, at B8

┌──────────────────────────────────────┐          ┌──────────────────────────────────────┐
│ B1  TRIGGER                          │          │ T1  REGISTER THE JOB RUN             │
│     Stonebranch starts the batch     │          │     inherit the batch run identifier │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B2  BATCH PREREQUISITE CHECK    GATE │          │ T2  DEPENDENCIES SATISFIED?     GATE │
│     allowed to start at all?         │          │     from metadata, for this run      │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B3  REGISTER THE BATCH RUN           │          │ T3  IS THE UPSTREAM DATA READY? GATE │
│     establish the run identifier     │          │     has the source landed?           │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B4  LOAD BATCH CONFIGURATION         │          │ T4  DETERMINE WHAT THIS RUN          │
│     members · groups · edges ·       │          │     PROCESSES                        │
│     each table's pipeline            │          │     mechanics = low level design     │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B5  VALIDATE CONFIGURATION      GATE │          │ T5  PLAN THE PASSES                  │
│     refuse an incoherent batch       │          │     fixed before anything is written │
│     before any data is touched       │          │                                      │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B6  MIRROR CONTROL TABLES            │          │ T6  REGISTER THE CHECKS              │
│     TO SNOWFLAKE                     │          │     which rules apply, from config   │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B7  BUILD THE EXECUTION PLAN    NEW  │          │ T7  EXECUTE THE LOAD                 │
│     prerequisites + groups →         │          │     write strategy from config,      │
│     an ATTEMPT ORDER, not a schedule │          │     pushed down. Rows failing a      │
│                                      │          │     rule are split out HERE          │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B8  RUN EACH WAVE IN ORDER           │─────────▶│ T8  RECORD THE CHECK VERDICT         │
│     within a wave, in parallel       │  for each│     critical → job fails             │
│     each table runs LEVEL 2  ────────│  table   │     informational → warning          │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B9  BATCH RECONCILIATION             │          │ T9  TABLE RECONCILIATION             │
│     totals across member tables      │          │     after write, before success      │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B10 PUSH STATE BACK TO AURORA        │          │ T10 POST-LOAD STEPS                  │
│     working copies → system of record│          │     as this table's config requires  │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B11 DETERMINE THE BATCH OUTCOME      │          │ T11 CLOSE THE JOB RUN                │
│     zero failures → Completed        │◀─────────│     advance stored state ONLY on     │
│     else Failed       (ABC rule)     │  return  │     success · return to B8           │
└──────────────────┬───────────────────┘          └──────────────────────────────────────┘
┌──────────────────▼───────────────────┐
│ B12 NOTIFY AND CLOSE                 │
└──────────────────────────────────────┘
```

**The branch that is not on this diagram.** `HISTORY`, `CATCHUP`, `INCREMENTAL`, `REPLAY` and
`FULL_REFRESH` all walk the same eleven table blocks. The load type changes the values B4 reads and T4, T5
and T7 act on — never the path.

---

## 4. Where each block exits

Every block, its owner, and both its exits, are on the **`flow_steps`** sheet. The three that carry the
design's weight:

| Block | Why it matters |
|---|---|
| **B5 — validate configuration** | The only place a bad configuration is caught **before data is touched**: a cycle in the dependencies, a member with no pipeline, a write strategy illegal for its table type. A framework that validates config at run time instead has already read the data when it finds out |
| **B7 — build the execution plan** | **New, and the largest new capability.** R-07 put the intra-batch DAG here rather than in Stonebranch. Its job is **ordering only** (R-13): it guarantees that by the time a table is attempted, every prerequisite has already been attempted — which is what lets T2 be a check rather than a scheduler |
| **B8 — run each wave** | Carries three behaviours at once: parallel within a wave, continue-on-failure across members (ABC's rule), and **SKIPPED** for a table whose parent failed |

### The three member outcomes

| Outcome | Meaning | Batch effect |
|---|---|---|
| **Completed** | loaded and reconciled | — |
| **Failed** | something went wrong with *this* table | batch → Failed |
| **SKIPPED** | its parent failed, so **its data was never touched** | **HQ-02** — currently also → Failed |

`SKIPPED` is new. ABC cannot express it because ABC has no intra-batch dependency at all.

---

## 5. The feature register

The register is the requirement phase's main output: **one row per capability the framework must have**,
with whether ABC already provides it, where, and what breaks without it. It lives on the
**`feature_register`** sheet — 54 features across 10 categories, every row tied to a flow block so the
register and the diagram cannot drift into two documents.

| | | |
|---|---|---|
| **19 PRESENT** | 35% | quality, reconciliation, run-state and error recording are **largely reusable as they stand** |
| **7 PARTIAL** | 13% | right idea, wrong grain — batch-level where the framework needs table-level |
| **27 MISSING** | 50% | |
| **1 UNCONFIRMED** | | the `group` column — HQ-01 |

### The headline

**ABC holds the *where*. It holds almost none of the *what* or *how*.**

The missing half is not spread evenly. It clusters in two categories:

**Keys and table structure — ABC holds nothing at all.** No primary key, no business key, no surrogate key
and no SCD2 date columns, anywhere. SCD2 needs the business key to group a timeline, SCD1 to merge,
reconciliation to compare, chunking to cut — and none of it is recorded. ABC works today precisely because
every one of those lives inside hand-written mapping SQL. **The moment the framework becomes
configuration-driven, keys become configuration**, and that is the single largest gap between what exists and
what this needs.

**Sequencing and scope.** Prerequisite edges (R-13), the load type, the window strategy, the write strategy,
the watermark column, pass planning — none of it exists, because none of it ever had to.

### What the register confirms about `target_load_type`

`job_metadata.target_load_type` holds *type 0 / type 1 / type 2 / append only* — a **table type wearing a
load type's name**, with no slot for the real load type. That conflation is why ABC could never express
history versus catchup versus incremental as configuration. Inferred earlier from behaviour; now confirmed
from the column list.

---

## 6. What is deliberately not here

| Not decided here | Where it belongs |
|---|---|
| How T4 derives a run's scope — watermarks, ranges, key sets | low level design |
| How T5 sizes and persists a pass plan | low level design |
| The SQL behind each write strategy at T7 | low level design |
| Physical model, column names, DDL | low level design |
| Rule thresholds, chunk sizes, warehouse sizing | low level design |

The previous iteration of this design went into all five before the flow existed. That was the mistake this
document corrects.

---

## 7. The parked work

`requirement_and_design.md` and `design_tracker.xlsx` are **parked at the point they reached**, not deleted.
Honest classification of what is in them:

| Content | Classification | Fate |
|---|---|---|
| Load type model — nine names → three axes plus presets | **requirement clarification** | stands; feeds B4 and T4 |
| Four target table types and their invariants | **requirement / conceptual model** | stands; feeds T7 |
| The *set* of six write strategies | **architecture** | stands; feeds T7 |
| `SCD2_REBUILD_TIMELINE`'s five steps and three statements | **low level design** | parked |
| Aspect 4 — all sixteen window questions | **low level design** | parked |
| §6 seven categories | architecture, but thin — a placement diagram with no interfaces, contracts or lifecycle | **superseded by this document** |

Nothing is wasted. Three of those rows are Stage 0 inputs we would have had to produce anyway.

---

## 8. Open questions

**`HQ-04` is the largest gap in the whole design** and it is the one only leadership can close.

| # | Question | Blocks |
|---|---|---|
| **HQ-01** | Confirm the `group` column on `job_metadata` — exact name, and what it means today. Parallel-group label, sequence number, or something else? The ABC reference documents no such column, so this needs the live DDL | B7 |
| **HQ-02** | Should this framework's batch gain a **Partial** outcome, or stay with ABC's two states? *"12 of 15 loaded, 3 skipped because their parent failed"* is materially different from a flat Failed, and it is what a morning operations call needs | B11 |
| **HQ-03** | What are the batch-level control totals at B9? Cross-table totals only mean something where members share a measure. If none does, B9 collapses to an aggregate of the per-table recons and should be drawn that way | B9 |
| **HQ-04** | **Non-functional requirements** — volume per table and per batch, the batch window, recovery time objective, concurrent pipeline count, audit retention period | the whole architecture |
| **HQ-05** | Does `SKIPPED` propagate transitively to a skipped table's own dependents, and does a skipped table block the next batch run? | B7, T2 |
| **HQ-06** | Who owns the dependency edges — derived from existing lineage metadata, or declared by hand per table? Hand-declared is simpler to build and harder to keep honest; derived is the reverse | B4, B7 |
| **HQ-07** | **Are prerequisites always inside the same batch?** If table B's prerequisite A sits in another batch, T2 cannot resolve it within the run and it has to become a batch-level dependency for Stonebranch instead. The one thing needed to finish F-18 and F-22 | B2, B7, T2 |
| **HQ-08** | **Declared by hand, or derived?** — supersedes HQ-06 with a better option. A prerequisite is usually *created by* a lookup in the team SQL: if B's SQL resolves A's surrogate key, B depends on A. So the edges could be **derived from the SQL**, which makes them more trustworthy, not less. Hand-declared is simpler to build and drifts the moment someone edits a query | B4, B7 |
| **HQ-09** | If the team SQL does the joins, **the framework no longer knows what its sources are** — but it needs them for the readiness check at T3. So sources must *also* be declared, and the two can drift: someone adds a join, forgets the config row, and the framework waits on the wrong upstream or does not wait at all | T3 |

---

## 9. What comes next

The flow is the spine. Each block now gets its own detail, **one block at a time**, in diagram order —
what it reads, what it writes, what it decides, what it must guarantee, and what it needs from configuration.
Still no low-level design: a block's detail stops at the contract, not the mechanism.

**HQ-04 is worth starting in parallel**, because it is the only item here that needs someone other than us.
