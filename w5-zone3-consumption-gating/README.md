# W5 — Zone 3 consumption publication gating

Stopping business and reporting users from reading a partially refreshed, internally inconsistent
consumption dataset while the upstream batch is still running.

> The visible state of a consumption object currently changes as a **side effect of upstream
> loading**. It must instead change only as an **explicit, controlled publication event**.

**Status** — requirement agreed and split into two parts; solution proposed, nothing concluded.
The POC has not been run.

---

## Where to start

| Read | For |
|---|---|
| [`problem_statement.md`](problem_statement.md) | **The baseline.** Part A, Part B, R1–R29, assumptions, open policy. If anything disagrees with it, it wins |
| [`solution_design.md`](solution_design.md) | The proposal: 22 options considered, `INSERT OVERWRITE` + transaction recommended, every claim sourced or marked untested |
| [`requirement_deck_v3.html`](requirement_deck_v3.html) | **Candidate deck**, 11 slides. v2 plus the flow corrections — prepare step, per-group gate, two staging sources, the physicalised-view line |
| [`requirement_deck_v2.html`](requirement_deck_v2.html) | The previous deck, 11 slides. Kept side by side until one is chosen |
| [`poc/`](poc/) | The test pack — scripts, tracker, evidence |

## Layout

```
problem_statement.md        the requirement baseline — source of truth
solution_design.md          the solution proposal
requirement_deck_v3.html    candidate leadership deck, 11 slides
requirement_deck_v2.html    previous deck, kept for comparison

poc/                        the proof-of-concept pack
├── 00_setup.sql            run first; everything else depends on it
├── 01_governance_survival.sql    TC-001 … TC-016
├── 02_atomicity_publication.sql  TC-020 … TC-026, TC-032
├── 03_views_shape_dependencies.sql
├── 04_gate_rollback_control.sql
├── 05_sizing_performance.sql     TC-040/041 run against real metadata, read-only
├── 99_teardown.sql         one statement, nothing left behind
├── Zone3_Gating_Test_Tracker.xlsx
└── evidence/               screenshots land here; NAMING.md has the convention

sources/                    raw inputs, kept at their original filenames
archive/                    superseded, retained for history only
```

## Before running the POC

Three things that will waste a run if missed:

1. **Three roles are required.** `POC_DEPLOY_ROLE` owns the published tables; the batch role only
   holds DML on them. `00_setup.sql` ends with an assertion printing the owner of each published
   table — **if it says `POC_ROLE`, stop.** TC-003 and TC-006 will pass falsely, and the whole case
   for `INSERT OVERWRITE` over CTAS rests on them.
2. **Do not remove the `SYSTEM$WAIT` calls in TC-020.** They hold the publish transaction open long
   enough for the reader to read inside it. Without them the test passes without testing anything.
3. **R26 has no test** because the POC fixture carries no row access policy. Either add one, or
   record that Zone 3 has none.

## Traceability

Every test case maps to a requirement. `Zone3_Gating_Test_Tracker.xlsx` carries a
**Requirement(s)** column and a **Requirement_Coverage** sheet naming the four requirements that
currently have no test — R12, R13, R24, R26. R13 is unreachable by design under assumption A5.

## Excluded as inputs

The earlier POC02 and POC05 decks in [`sources/`](sources/) are **background only**. No claim or
recommendation in this workstream derives from them; every Snowflake behaviour is sourced from
current documentation or marked as needing test.
