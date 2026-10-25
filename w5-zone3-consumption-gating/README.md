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
| [`requirement_deck.html`](requirement_deck.html) | **The leadership deck**, 11 slides. Opens in a browser, no build step. Earlier versions are in `archive/` |
| [`poc/`](poc/) | The test pack — scripts, tracker, evidence |

## Layout

```
problem_statement.md        the requirement baseline — source of truth
solution_design.md          the solution proposal
requirement_deck.html       the leadership deck, 11 slides

poc/                        the proof-of-concept pack
├── 00_setup.sql            run first; everything else depends on it
├── 01_governance_survival.sql    TC-001 … TC-016
├── 02_atomicity_publication.sql  TC-020 … TC-032, TC-044 … TC-046
├── 03_views_shape_dependencies.sql
├── 04_gate_rollback_control.sql  TC-034 … TC-039, TC-042/043, TC-047
├── 05_sizing_performance.sql     TC-040/041 run against real metadata, read-only
├── 99_teardown.sql         one statement, nothing left behind
├── Zone3_Gating_Test_Tracker.xlsx
└── evidence/               screenshots land here; NAMING.md has the convention

sources/                    raw inputs, kept at their original filenames
archive/                    superseded, retained for history only
```

## Before running the POC

Four things that will waste a run if missed:

1. **Three roles are required.** `POC_DEPLOY_ROLE` owns the published tables; the batch role only
   holds DML on them. `00_setup.sql` ends with an assertion printing the owner of each published
   table — **if it says `POC_ROLE`, stop.** TC-003 and TC-006 will pass falsely, and the whole case
   for `INSERT OVERWRITE` over CTAS rests on them.
2. **Do not remove the `SYSTEM$WAIT` calls in TC-020 or TC-046.** They hold the publication open
   long enough for the reader to read across it. Without them the test passes without testing
   anything. Both need a second session, open first.
3. **TC-042 and TC-043 must both run, and in that order.** They are the same fixture with one
   difference, and each is meaningless without the other: TC-042 proves the gate *passes* a group
   whose weekly member is not due, TC-043 proves it *fails* when a daily member is missing. A gate
   that cannot tell them apart is unusable on a real group.
4. **`CTRL.GROUP_EXPECTATION` carries the per-cycle refresh schedule** (R22). It is seeded with
   `DIM_BROKER` weekly and `DIM_DATE` yearly, deliberately not due. Change those flags and the
   gate results change with them — that is the point, not a bug.

## Traceability

Every test case maps to a requirement. `Zone3_Gating_Test_Tracker.xlsx` carries a
**Requirement(s)** column and a **Requirement_Coverage** sheet. **25 scenarios, 50 test cases.**

One requirement has no test: **R13**, which is unreachable by design under assumption A5 (batches
strictly serialised). Everything else is covered.

### What the pack concludes, and what it cannot

Running every script answers the refresh question outright and the publication question for the two
mechanisms we would actually use. It leaves three things open that no script can close:

| Open | Who closes it |
|---|---|
| May the batch identity read sensitive data in the clear? | Security. It bounds how much of the estate can be gated at all |
| Is there a declared governance baseline to reconcile against? | Security / governance |
| Do the load mappings truncate staging at cycle start? | Whoever owns the IDMC mappings. If they do, `INSERT OVERWRITE` + transaction needs a carry-forward step too |

## Excluded as inputs

The earlier POC02 and POC05 decks in [`sources/`](sources/) are **background only**. No claim or
recommendation in this workstream derives from them; every Snowflake behaviour is sourced from
current documentation or marked as needing test.
