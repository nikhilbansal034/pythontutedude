# Generic ETL framework — high level design

> **High level only.** No column lists, no SQL, no thresholds, no watermark arithmetic. Where a mechanism
> is deliberately not decided here, it says so and names low-level design as its home.
>
> | | |
> |---|---|
> | [`high_level_design.xlsx`](high_level_design.xlsx) | the same content, structured — and the sheet we hang per-block detail off |
> | [`framework_flow.drawio`](framework_flow.drawio) | the flow as an editable diagram: three columns — configuration read · the flow and its checks · state written or the failure exit |
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
| **R-06** | Control tables in Aurora · working copies in Snowflake · pushed back at post load | Two **named blocks** rather than an implementation detail: B5 and B8. Names a failure mode the architecture must make alertable — Aurora and Snowflake out of step |
| **R-07** | Stonebranch owns the **batch only**; table sequencing and parallelism belong to Aurora / Snowflake / IDMC | The framework builds its **own execution plan**. B6 — the largest new capability in the design |
| **R-08** | DQ failures handled **exactly as ABC** | Quality checking is **not a gate**. It is row routing *inside* the load plus a verdict *after* it |
| **R-09** | Reconciliation after the write, before the run is marked successful | No staging layer — which matters because push-down makes staging expensive. A failed recon fails the run with the data left **visible** |
| **R-10** | On a member failure the batch **continues**, as ABC does | Every member is attempted; Completed only with zero failures. Intra-batch dependency forces a **third** member outcome ABC has no concept of: **SKIPPED** |
| **R-11** | All transformation — joins, lookups, aggregation, dedup, derivation — is **parameterised SQL** executing on Snowflake, table by table | Transformation is **configuration, not framework code**. It also fixes the cleanest seam in the design: **team SQL** produces a prepared row set shaped like the target; **framework SQL** applies it. The team owns *what the rows are*, the framework owns *how they land* — so the write-strategy library is the only SQL the framework itself owns |
| **R-12** | Validating a team's SQL and mapping is **out of scope** — that is build's problem, not the design framework's. **Validating a target's structure is out of scope too**: no invariant assertion after the write | The configuration-validation block has been **removed from the flow entirely**. What survives is implicit: an unplaceable prerequisite makes B6's plan unbuildable |
| **R-13** | **Target → target prerequisite sequencing** is a missing feature, to be held in metadata. At load start a table reads its prerequisites, checks their load status, and starts only when all are complete | Two blocks, one metadata table. **B6** resolves the prerequisites into an **attempt order**; **T2** then *verifies* rather than schedules — so a prerequisite can never still be in progress when it is checked, and there is no waiting or polling. Exactly two outcomes at T2: completed → proceed, failed or skipped → **SKIPPED** |

| **R-14** | **Remove configuration validation and batch-level reconciliation** from the flow | The batch spine drops from twelve blocks to **ten**, renumbered B1–B10. Reconciliation is per table only, at T9. **HQ-03 becomes moot** |

### Assumptions taken to close the design

| # | Assumption | How it is defended | What breaks if it is wrong |
|---|---|---|---|
| **A-01** | **Prerequisites are always inside the same batch** (HQ-07) | **B6 cannot place** a declared prerequisite that is not a member of this batch, so the plan is unbuildable and the batch fails. Less explicit than a dedicated validation block, but not lost | Batch membership stops being a purely operational grouping: two tables in a prerequisite relationship **must** be co-batched, so the dependency graph now constrains how batches are composed. A genuine cross-batch need becomes a batch-level dependency for Stonebranch instead (F-22, now out of scope) |

---

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
   runs once per batch                               invoked once per member table, at B7

┌──────────────────────────────────────┐          ┌──────────────────────────────────────┐
│ B1  TRIGGER                          │          │ T1  REGISTER THE JOB RUN             │
│     Stonebranch starts the batch     │          │     inherit the batch run identifier │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B2  BATCH PREREQUISITE CHECK   CHECK │          │ T2  PREREQUISITES SATISFIED?   CHECK │
│     allowed to start at all?         │          │     from metadata, for this run      │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B3  REGISTER THE BATCH RUN           │          │ T3  IS THE UPSTREAM DATA READY?CHECK │
│     establish the run identifier     │          │     has the source landed?           │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B4  LOAD BATCH CONFIGURATION         │          │ T4  DETERMINE WHAT THIS RUN          │
│     members · groups · prerequisites │          │     PROCESSES                        │
│     load type · table type · write   │          │     mechanics = low level design     │
│     strategy · keys · the team SQL   │          │                                      │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B5  MIRROR CONTROL TABLES            │          │ T5  PLAN THE PASSES                  │
│     TO SNOWFLAKE                     │          │     fixed before anything is written │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B6  BUILD THE EXECUTION PLAN    NEW  │          │ T6  REGISTER THE CHECKS              │
│     prerequisites + groups →         │          │     which rules apply, from config   │
│     an ATTEMPT ORDER, not a schedule │          │                                      │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B7  RUN EACH WAVE IN ORDER           │─────────▶│ T7  EXECUTE THE LOAD                 │
│     within a wave, in parallel       │  for each│     write strategy from config,      │
│     each table runs LEVEL 2  ────────│  table   │     pushed down. Rows failing a      │
│                                      │          │     rule are split out HERE          │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B8  PUSH STATE BACK TO AURORA        │          │ T8  ANY CRITICAL FAILURE?      CHECK │
│     working copies → system of record│          │     critical → fail · info → warn    │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B9  DETERMINE THE BATCH OUTCOME      │          │ T9  RECONCILIATION BALANCES?   CHECK │
│     zero member failures → Completed │          │     after write, before success      │
│     else Failed       (ABC rule)     │          │                                      │
└──────────────────┬───────────────────┘          └──────────────────┬───────────────────┘
┌──────────────────▼───────────────────┐          ┌──────────────────▼───────────────────┐
│ B10 NOTIFY AND CLOSE                 │          │ T10 POST-LOAD STEPS                  │
│                                      │          │     as this table's config requires  │
└──────────────────────────────────────┘          └──────────────────┬───────────────────┘
                                                  ┌──────────────────▼───────────────────┐
                                                  │ T11 CLOSE THE JOB RUN                │
                                                  │     advance stored state ONLY on     │
                                                  │     success                          │
                                                  └──────────────────┬───────────────────┘
                                                                     │
                     ◀───────────────────────────────────────────────┘
                     return to B7 — next table, then the next wave
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
| **B6 — build the execution plan** | **New, and the largest new capability.** R-07 put the intra-batch DAG here rather than in Stonebranch. Its job is **ordering only** (R-13): it guarantees that by the time a table is attempted, every prerequisite has already been attempted — which is what lets T2 be a check rather than a scheduler. It is also now what **defends A-01**: a prerequisite outside this batch cannot be placed, so the plan is unbuildable and the batch fails here |
| **B7 — run each wave** | Carries three behaviours at once: parallel within a wave, continue-on-failure across members (ABC's rule), and **SKIPPED** for a table whose parent failed |

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
| **26 MISSING** | 48% | |
| **1 OUT OF SCOPE** | | cross-batch prerequisites — closed by A-01 |
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

## 6. The checks

Seven checks, and nothing else stops a run. Every one is a diamond on the drawIO diagram.

| | Check | How it is evaluated | On failure |
|---|---|---|---|
| **B2** | is this batch allowed to start | calendar · prior run of this batch still in flight · upstream batch status | abort — **no run state is created at all** |
| **B6** | is the plan buildable | every declared prerequisite can be placed in an attempt order | batch Failed. Also **defends A-01** |
| **B9** | batch outcome | zero member failures? | batch Failed (HQ-02 asks whether *Partial* is wanted) |
| **T2** | prerequisites satisfied | per prerequisite, its load status **for this run** | **SKIPPED** — distinct from Failed, because no data was touched |
| **T3** | upstream data ready | the readiness rule against the declared source list | job Failed |
| **T8** | quality verdict | any CRITICAL → fail; INFORMATIONAL alone → complete with a warning | job Failed, rows already quarantined |
| **T9** | reconciliation balances | counts, and amounts where the table has a measure | job Failed, **data left visible** for investigation |

**Row-level quality evaluation happens inside T7**, not as a gate: rows failing a rule are split out as the
load runs — CRITICAL quarantined and not loaded, INFORMATIONAL quarantined and loaded. T8 only reads the verdict.

---

## 7. What is deliberately not here

| Not decided here | Where it belongs |
|---|---|
| How T4 derives a run's scope — watermarks, ranges, key sets | low level design |
| How T5 sizes and persists a pass plan | low level design |
| The SQL behind each write strategy at T7 | low level design |
| Physical model, column names, DDL | low level design |
| Rule thresholds, chunk sizes, warehouse sizing | low level design |
| **Whether a team's SQL is correct or push-down safe** | **build** (R-12) |
| **Whether the target is still structurally valid after a write** — no invariant assertion | **out of scope** (R-12) |

The previous iteration of this design went into all five before the flow existed. That was the mistake this
document corrects.

---

## 8. The parked work

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

## 9. Requirement coverage review

Sixteen requirements arrived on the **`Requirement summary`** sheet. Reviewed against the design as drawn:

| | | |
|---|---|---|
| **7 COVERED** | | one base framework · all table types · job-error table · CDE recon · post-load reuse · the Snowflake config copy (already decided at R-06) · groups (as a known gap) |
| **1 PARTIAL** | | RI routing |
| **5 GAP** | | group-level restart status · ABC table completeness · Snowflake copy granularity · **Aurora connection architecture** · *(see conflicts)* |
| **3 CONFLICT** | | the three below |

**A conflict matters more than a gap**: a gap is something to add, a conflict means something already agreed has to change.

### C-1 · The DQ-results merge *(most consequential)*

> *"Critical DQ that scales — the merge references DQ results, not ever-longer conditions."*

**T7 currently splits failing rows out inline as the load runs**, which is ABC's model — and inline conditions
are exactly what makes the merge grow with every new rule. For the merge to *reference* DQ results, quality
evaluation has to produce a **result set the write joins**. That changes T7's shape, not just its configuration.

### C-2 · "Waits only for the tables it needs"

Stricter than what B6 does. B6 resolves prerequisites into **waves**, so a table in wave 3 waits for every
table in waves 1 and 2 to be *attempted* — more than its own prerequisites. Per-table readiness gives maximal
parallelism, but then a prerequisite **can** still be in progress when checked, which is precisely what the
wave model was chosen to prevent (HQ-07). A real trade-off:

| | Waves (as drawn) | Per-table readiness |
|---|---|---|
| Parallelism | over-serialises | maximal |
| In-progress prerequisite | unreachable by construction | reachable — needs a wait or a poll at T2 |

### C-3 · Helix owns SCD Type 1

The design assumes SCD1 is **in** scope: `table_type` lists it first and two write strategies serve it. But
note the deeper issue — **static / mapping / truncate tables were collapsed into SCD1** earlier in this design.
*"SCD1 is Helix's"* and *"static tables are ours"* cannot both be true while they share one type.

You pushed back on that collapse at the time. This requirement is evidence you were right, and **`STATIC` may
need to be its own table type again.**

### Also new

**Sequencing within a group** contradicts what a group means here — in this design a group is *by definition*
parallel-safe. A stage-before-target pair is a **prerequisite edge**, not an intra-group sequence. And **stage
tables as batch members is new**: the flow assumes every member is a final target. A stage table that is a
member needs a table type and a write strategy of its own.

---

## 10. Open questions

**`HQ-04` is the largest gap in the whole design** and it is the one only leadership can close.

| # | Question | Blocks |
|---|---|---|
| **HQ-01** | Confirm the `group` column on `job_metadata` — exact name, and what it means today. Parallel-group label, sequence number, or something else? The ABC reference documents no such column, so this needs the live DDL | B6 |
| **HQ-02** | Should this framework's batch gain a **Partial** outcome, or stay with ABC's two states? *"12 of 15 loaded, 3 skipped because their parent failed"* is materially different from a flat Failed, and it is what a morning operations call needs | B9 |
| ~~**HQ-03**~~ | **CLOSED — moot.** Batch-level reconciliation has been removed from the flow, so there are no cross-member totals to define. Reconciliation is per table, at T9 | — |
| **HQ-04** | **Non-functional requirements** — volume per table and per batch, the batch window, recovery time objective, concurrent pipeline count, audit retention period | the whole architecture |
| **HQ-05** | Does `SKIPPED` propagate transitively to a skipped table's own dependents, and does a skipped table block the next batch run? | B6, T2 |
| ~~**HQ-06**~~ | **Superseded by HQ-08**, which offers a better option than either side of this question. | — |
| ~~**HQ-07**~~ | **CLOSED — yes, by assumption A-01.** Taken to close the design rather than verified, and defended at B6 by plan-buildability | — |
| **HQ-08** | **PROPOSED: declared by hand, validated by the framework** — which *reverses* the lean toward derived stated when this question was raised. **A join is not a prerequisite:** a lookup against a static reference table needs no ordering, and only the author knows which joins must be sequenced. Derived edges must still be stored and refreshed when the SQL changes, so the drift exposure does not go away; and deriving them needs SQL parsing, which is machinery for a problem declaration plus B6's plan-buildability already solves | B4, B6 — **awaiting confirmation** |
| **HQ-09** | **PROPOSED: dissolved** by reframing what the declared source list is *for*. It is a **readiness list** — the tables whose completion gates this load — not a lineage list, and it was never meant to equal the set of tables the SQL touches. A static reference table the SQL joins gates nothing and does not belong on it. So the two diverging is not drift; they were never the same set. The residual risk — a join added to a table that *does* gate, undeclared — is a build and review concern, where R-12 already puts it | T3 — **awaiting confirmation** |

---

## 11. What comes next

The flow is the spine. Each block now gets its own detail, **one block at a time**, in diagram order —
what it reads, what it writes, what it decides, what it must guarantee, and what it needs from configuration.
Still no low-level design: a block's detail stops at the contract, not the mechanism.

**HQ-04 is worth starting in parallel**, because it is the only item here that needs someone other than us.
