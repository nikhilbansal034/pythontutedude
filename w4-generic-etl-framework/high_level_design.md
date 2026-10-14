# Generic ETL framework — high level design

> **High level only.** No column lists, no SQL, no thresholds, no watermark arithmetic. Where a mechanism
> is deliberately not decided here, it says so and names low-level design as its home.
>
> | | |
> |---|---|
> | [`high_level_design.xlsx`](high_level_design.xlsx) | the same content, structured — and the sheet we hang per-block detail off |
> | [`framework_flow.drawio`](framework_flow.drawio) | the flow as an editable diagram: three columns — configuration read · the flow and its checks · state written or the failure exit |
> | [`Zone2_OneTime_Loads.pptx`](Zone2_OneTime_Loads.pptx) | **background.** ABC's September 2026 design for Historical, Catchup and First-Time Incremental loads. Analysed in §10 |
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

**A conflict matters more than a gap**: a gap is something to add, a conflict means something already agreed has
to change. All three carry a recommendation below, all three are **PROPOSED** rather than settled, and each
names the one answer it needs.

### C-1 · The DQ-results merge — **PROPOSED**

> *"Critical DQ that scales — the merge references DQ results, not ever-longer conditions."*

**What is actually wrong today.** ABC evaluates DQ **inside** the load mapping, as an expression that builds
`error_description`, with **`rule_id` and the severity code hard-coded in that expression** (`1` = null check,
`'C'` = critical). Two separate problems in one: the expression **grows** with every rule, and adding a rule is
a **code change, not configuration**.

**The fix — split T7 in two.**

| | | |
|---|---|---|
| **T7a** | **evaluate** | run the configured rules over the run's scope · write one row per (record, rule, severity) |
| **T7b** | **write** | the load **anti-joins** the scope against the critical failures |

The predicate in the write becomes constant:

```sql
NOT EXISTS (SELECT 1 FROM <dq_result> d
            WHERE d.job_run_id = :run_id
              AND d.record_id  = s.record_id
              AND d.severity   = 'C')
```

**A hundred rules and it is still one `NOT EXISTS`.** That is the scaling property the requirement asks for.

**Why it is cheaper than it looks.** Two pieces of the ABC schema already fit:

- **`job_rule_error_detail`** already holds `source_record_identifier`, `rule_id`, severity and `job_run_id`
  — it *is* the result set. It is only written at the wrong *time* today: as a by-product of the load rather
  than before it.
- **`job_rule_assignment.pattern_available` / `pattern`** are unused and kept at `'N'`. The W2 reference records
  that an expression could be stored there and reused in the ETL, left explicitly unresolved. **That is exactly
  the configuration home a rule predicate needs** — the slot was anticipated and never filled.

**Four consequences.**

1. **The row identifier becomes mandatory configuration.** Joining results back to rows needs a stable per-row
   identifier in the scope. This makes **F-05 (keys)** load-bearing for quality as well as for the write — it
   *deepens* the biggest gap already found rather than adding a new one.
2. **One extra pass over the scope.** Evaluate, then write. Mitigation: materialise the scope once into a
   transient table and let both passes read it — which is also what T5's pass plan wants, so the cost buys
   something else.
3. **Informational behaviour is unchanged.** The anti-join filters `severity = 'C'` only. Informational rows are
   recorded and still load. **R-08 preserved exactly**, mechanism changed.
4. **A restart wrinkle.** Quarantine rows are now written *before* the load, so a failed load leaves quarantine
   records for a run that never completed. `job_run_id` is already on those rows so cleanup is scoped — but it
   needs stating rather than discovering.

> **Recommendation: adopt.** The predicate is constant, the result table exists, and the configuration slot for
> rule predicates exists and is empty.

**Open — HQ-10.** Does every target have a **stable record identifier** available in the source scope, or must
it be derived (a hash of the business key)?

---

### C-2 · "Waits only for the tables it needs" — **PROPOSED**

**What it costs as drawn.** B6 builds **static waves**: wave 3 starts when every table in waves 1–2 has been
*attempted*.

> 20 tables. 19 quick and independent. One slow table in wave 1 that exactly **one** table depends on.
> **Waves:** the 18 that need nothing from it still wait. **Ready-set:** they start immediately.

That cost lands directly on the batch window — **HQ-04**, still unanswered.

**Why waves were chosen, and why that reason survives.** Waves make *"prerequisite still in progress"*
**unreachable by construction**, which is what lets T2 be a pure check with exactly two outcomes and no polling.
That property is worth keeping.

**The middle path.** Keep the plan as a **dependency graph**, not as waves. B7's loop becomes:

> *Launch every table whose prerequisites are all **Completed** and which has not been attempted. When members
> finish, recompute the ready set.*

| | Static waves | **Dynamic ready-set** | True event-driven |
|---|---|---|---|
| Parallelism | loosest | **tight** | tightest |
| Can T2 see "in progress"? | no | **no** | no |
| Needs | compute once | **a loop** | per-task completion events |

**T2's guarantee is preserved** — B7 only ever launches a table whose prerequisites are *already* Completed. No
waiting, no polling, no idle concurrency slots, and barely more machinery than a wave iterator.

What remains is the **recompute grain**: after each parallel group drains (a loop — always possible), or on each
individual completion (tightest — needs event-driven launch, which is **OQ-03**).

> **Recommendation: specify the semantics as ready-set** — a table waits only for its own prerequisites — **and
> implement as recompute-per-group if IDMC cannot launch on individual completion events.** The requirement is
> about semantics; the grain is an IDMC capability question. **B6 changes from "resolve into waves" to "resolve
> into a dependency graph".**

---

### C-3 · Helix owns SCD Type 1 — **PROPOSED**

**The history, plainly.** Static, reference and mapping tables were **collapsed into SCD1** earlier in this
design, on the argument that the invariant is identical — *exactly one row per business key holding the latest
source state* — and that truncate-versus-merge is a **write strategy** difference. The design lead pushed back
at the time; that push-back was defended rather than accepted.

**What the new requirement does to it.** *"SCD1 is Helix's"* and *"static tables are ours"* cannot both be
expressed while they share a type. **The type is being asked to do organisational work it cannot do.** The
collapse did create a problem — but on reflection the problem is not a missing type.

| | Fix | Cost |
|---|---|---|
| **A** | Split `STATIC` back out as its own table type | Re-introduces two types with one invariant, and risks a genuine SCD1 dimension being typed STATIC and getting truncate-and-load onto a surrogate-key-referenced table |
| **B** | Keep one type; express ownership as **scope** | Nothing changes in the type model |

> **Recommendation: B.** Ownership is not a property of a table's *shape* — it is a property of *which pipeline
> loads it*. A table this framework does not load simply **has no pipeline row here**. Encoding ownership as a
> table type would conflate what a table **is** with how it is **loaded**, which is the exact original sin in
> `job_metadata.target_load_type`. Splitting `STATIC` out repeats that mistake in a new costume.
>
> **With one caveat, because habit beats documentation.** If teams and leadership *talk* about "static tables"
> as a category, give them the word — as a **label with no behavioural effect**: a `table_category` column
> (DIMENSION · REFERENCE · MAPPING · FACT) used for reporting and navigation only, which **cannot** influence
> the write strategy and therefore cannot cause a wrong one. Vocabulary without power over behaviour.

**Open — HQ-12, and the most consequential of the three.** Is Helix owning SCD1 **permanent**, or a current
state this framework eventually absorbs?

| | |
|---|---|
| **Permanent** | SCD1 may be dead weight. `MERGE_SCD1` serves nothing and the table-type set shrinks |
| **Transitional** | everything stays; scope is simply narrow on day one |

---

### Also new

**Sequencing within a group** contradicts what a group means here — in this design a group is *by definition*
parallel-safe. A stage-before-target pair is a **prerequisite edge**, not an intra-group sequence. And **stage
tables as batch members is new**: the flow assumes every member is a final target. A stage table that is a
member needs a table type and a write strategy of its own.

### What these three need from the design lead

| | Question | Why it matters |
|---|---|---|
| **HQ-10** | Is there a stable record identifier per row, or is it derived? | Decides whether C-1 needs a derived key before it can work |
| **HQ-11** | Confirm ready-set semantics — B6 resolves a graph, not waves | Nothing blocking; confirmation only |
| **HQ-12** | **Is Helix owning SCD1 permanent or transitional?** | **Answer this first** — it is the only one of the three that can *shrink* the design rather than extend it |
| **HQ-13** | Slide 14 of the one-time loads deck says *"use History / Catchup as the job run ID"*. A fixed identifier, a derived one, or something else? Flagged rather than guessed | §10 |

---

## 10. What the Zone 2 one-time loads design confirms

[`Zone2_OneTime_Loads.pptx`](Zone2_OneTime_Loads.pptx) — September 2026, 15 slides — is ABC's design for
Historical, Catchup and First-Time Incremental loads. The W2 reference records all three flag values as
**never built**; they are now designed, finalized, and specified down to four Informatica objects.

**Verdict: nothing structural changes in this design.** It is the strongest validation the design has had, and
it supplies the business case's clearest number. Four things get added, none of them to the flow.

### 10.1 The restart conflict is this design's thesis, proven in ABC's own words

ABC resolves execution type from the rerun flag first, then from the previous batch status. So:

> Flag `'N'` → restart works, **but loses the H/C/I windowing.**
> Flag `'H'`/`'C'`/`'I'` → **never enters the restart step, so cleanup never happens.**

The cause is that **load type and run disposition are encoded in one field.** `batch_rerun_flag` can say
*"this is a history load"* or *"this is a restart"* — never both. *"Restart of a history load"* is
inexpressible.

ABC's finalized fix (Option 1 of four evaluated) **doubles the vocabulary**: `H → HR`, `C → CR`, `I → IR`,
with execution type resolving to Restart whenever the flag is in `{N, HR, CR, IR}`. That is **2N flags for N
load types**, growing with every load type added.

**This is the second instance of one root cause.** We already found `job_metadata.target_load_type` to be a
*table* type wearing a *load* type's name. `batch_rerun_flag` is a *load* type wearing a *run disposition's*
name. ABC encodes orthogonal concepts in single flag fields and pays for it each time.

In this design they are separate axes already — **load type is configuration on the pipeline, disposition is
run state** — so *"restart of a history load"* needs no new flag value at all. That is **D-01's
orthogonal-axes decision validated from outside this conversation.**

### 10.2 The number for leadership

| | |
|---|---|
| Adding one load-type variant **to ABC** | four Informatica mapping changes, plus the pre-load workflow |
| Adding one **to this framework** | **one configuration row** |

The clearest quantified contrast the business case has had — and it comes from ABC's own document, not from us.

### 10.3 Four additions — none structural

**1 · The framework registers its own runs.** ABC's one-time loads require **manual DML into two runtime
tables** (`batch_run_stats` and `batch_sourcing_stats`) before a run can start, which is exactly why the batch
prerequisite and pre-load steps are skipped for all three. F-17 said the explicit range is supplied "through
the static parameter file today, by hand" — it is worse than that. In this design **B2 and B3 run for every
load type** and the range comes from configuration, which removes the manual step rather than documenting it.

**2 · T3 stays, as configurable readiness — not a bypass.** Slide 14's new direction is to *"drop source-table
dependency checks"* for History and Catchup. This design must **not** grow a load-type branch at T3. The right
expression is **F-29**: a configurable readiness rule, which may be *"the upstream batch covering this range is
complete"*, or nothing at all. Same check, different configuration — the acceptance test survives.

**3 · The 3-day lookback is evidence for OQ-12.** First-Time Incremental starts at *"Catchup end − 3 days
(Yet to be decided)"*. That is a **late-arrival grace window**, introduced precisely because the boundary is a
GRS/business timestamp rather than arrival-ordered. It is the problem W-02 predicted, appearing in the wild —
and it strengthens the case for answering **OQ-12** (does Zone 1 expose an arrival-ordered column).

**4 · Per-source window granularity is confirmed.** *"For first time incremental load… for each source batch,
there will be one manual entry in the `batch_sourcing_stats` table."* That is **W-05** — watermark per
(pipeline × source table), not per pipeline — validated by a real requirement.

### 10.4 Two corrections to the audit

| | |
|---|---|
| **`batch_sourcing_stats` is a second window source** | ABC now derives the window from `batch_sourcing_stats` for H and C, and from `etl_data_ingestion_source_window` for everything else, with I taking its start from the former and its entry in the latter. **F-15 describes only the second.** |
| **H and C share one Batch ID, Job ID and mapping** | In this design they are two `load_pipeline` rows, because a generic mapping has no reason to share. Not a contradiction — but migrating an existing H/C pair means **splitting one ID into two pipeline rows**, which belongs in the coexistence story (R-04) |

### 10.5 Open

| | |
|---|---|
| **HQ-13** | Slide 14 says *"use History / Catchup as the job run ID"*. Reads ambiguously — a fixed identifier, a derived one, or something else? Flagged rather than guessed |
| **Reference** | The W2 `reference.md` states H/C/I were never built. That is now **out of date**. It is a factual correction to a background document rather than design discussion, but W2 was declared off-limits for this work — **say the word and I will correct it** |

---

## 11. Open questions

**`HQ-04` is the largest gap in the whole design** and it is the one only leadership can close.
**`HQ-12` is the one to answer first**, because it is the only question here that can make the design *smaller*.

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
| **HQ-10** | Is there a **stable record identifier** per row available in the source scope, or must it be derived (a hash of the business key)? C-1's anti-join has to join quality results back to rows, so without one the design needs a derived key first | C-1 · T7a, T7b |
| **HQ-11** | Confirm **ready-set semantics** — B6 resolves a *dependency graph* rather than static waves, so a table waits only for its own prerequisites. Nothing blocking; confirmation only. The recompute *grain* (per group, or per individual completion) is OQ-03, an IDMC capability question | C-2 · B6, B7 |
| **HQ-12** | **Is Helix owning SCD Type 1 permanent, or a current state this framework eventually absorbs?** **Answer this one first** — it is the only open question that can *shrink* the design rather than extend it. Permanent means `MERGE_SCD1` may serve nothing and the table-type set contracts; transitional means everything stays and scope is simply narrow on day one | C-3 · table types, write strategies |

---

## 12. What comes next

**Per-block detail is on hold until the three conflicts in §9 are settled**, because two of them change the
flow rather than describe it: C-1 splits T7 into evaluate-then-write, and C-2 changes what B6 produces. Writing
block detail against a spine that is about to move would be work done twice.

Once they are settled, each block gets its own detail, **one block at a time**, in diagram order — what it
reads, what it writes, what it decides, what it must guarantee, and what it needs from configuration. Still no
low-level design: a block's detail stops at the contract, not the mechanism.

**Two things are worth starting in parallel**, because both need someone other than us:

| | |
|---|---|
| **HQ-04** | the non-functional requirements — leadership |
| **HQ-12** | whether Helix owning SCD1 is permanent — and it may *shrink* the design |
