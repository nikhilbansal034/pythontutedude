# Response to the independent test lead review

**Date**: 2026-09-26 · **Reviewing**: `TEST_LEAD_REVIEW.md`
**Method**: every substantive finding was independently re-executed before being accepted.
Nothing below is taken from the review's own claims.

> ## Position — the review is accurate. All seven substantive findings reproduce.
>
> One claim is imprecise in a way that makes the underlying problem sound smaller than it
> is (F5, below). One finding (D7) is a criticism of text written in this session, not
> inherited residue. No finding was rejected.

---

## 1. Verification results

Each mutation was applied to the real files, all 15 scenarios re-run, then the file restored.
A mutation that leaves 69/69 green is a coverage hole: the suite cannot detect that fault.

| # | Claim | Independently reproduced? | What was measured |
|---|---|---|---|
| **F1** | Overlapping source intervals fan out | **YES — and understated** | See §2 |
| **F2** | De-dup deletable from `s1_dedup` | **YES** | 69 pass / 0 fail |
| **F2** | De-dup deletable from `s2_dedup` | **YES** | 69 pass / 0 fail |
| **F3** | Tie-break `DESC`→`ASC` undetectable | **YES** | 69 pass / 0 fail |
| **F4** | Gap-guard removable from both island flags | **YES** | 69 pass / 0 fail |
| **F5** | UUID unasserted | **YES, with a correction** | See §3 |
| **F6** | The harness runs an unguarded 4th copy | **YES — decisively** | See §4 |
| **D1** | Doc says neither CTE filters `TARGET_TABLE_NAME` | **YES** | Both filter, `00_objects.sql:169` and `:176` |
| **D2** | POC v1 content still in `solution_design.md` §9 | **YES** | `BR001`–`BR007` at lines 107–135 under a §9 that now describes `poc_v2/` |
| **D4** | `TEST_PLAN.md` describes a test that does not exist | **YES** | Line 145: *"TC02 in particular — ten consecutive runs, random mutations"*. S15 has 3 test cases; TC01 is a single six-key load |
| **D5** | "Volume" is a misnomer | **YES** | Largest target row count asserted anywhere: **16**. Largest live count: **15** |
| **D7** | Root `README.md` overclaims | **YES — and it is ours** | See §5 |

---

## 2. F1 is worse than the review states

The review reports broken idempotence. Measured behaviour is **unbounded divergence**.

Two overlapping SRC_1 versions for one key (`A1` 08-01→08-20, `A2` 08-10→08-31):

| Run | Sources | Stage rows | Target rows | Live rows sharing one `(key, eff_dte)` |
|---|---|---|---|---|
| 1 | seeded | 5 | 5 | **2** — violates S15's own stated invariant |
| 2 | **unchanged** | 4 | 7 | 2 |
| 3 | **unchanged** | 4 | 9 | 2 |

The target grows by **two rows every run, forever**, with fresh surrogate keys each time. It
does not converge. A daily job would add ~730 rows a year per overlapping key while every
assertion in the suite still passes.

**Three-way overlap escalates it to a hard failure.** Adding `A3` 08-05→08-25:

| Run | Stage rows | Surrogate keys receiving >1 non-insert instruction |
|---|---|---|
| 1 | 10 | 0 |
| 2 | 20 | **3** (SKs 7, 8, 9 each get two) |

Two `D` instructions against one target row is exactly what
`ERROR_ON_NONDETERMINISTIC_MERGE = TRUE` rejects — the default the design explicitly relies
on. In Snowflake that run **aborts**.

So the failure mode is a function of overlap depth: 2-way corrupts silently and reports
success; 3-way stops the job. The silent case is the dangerous one.

This also falsifies, for this input class, two claims the design makes about itself:
`solution_design.md` §4 (*"Stage 6 cannot fan out, and this is structural"*) and §5 (*"the
diff emits at most one instruction per target row"*).

---

## 3. F5 — the review's wording understates it

The review says removing the UUID write from *every* MERGE branch passes 69/69. **It does
not.** Nulling `UUID_STRING()` in the view is caught by S12 TC02, which asserts:

```sql
-- every stage row carries a fresh UUID
AND (SELECT count(*) FROM STG_Z2_BROKER_PARTY_DIM WHERE UUID IS NOT NULL) = 2
```

The accurate statement is narrower and worse: that assertion checks the UUID is present **on
the stage row**, never that it **changed on the target row**. Removing the UUID write from the
`'U'` branch that actually executes passes **69/69**.

Since rules 2 and 4 exist *solely* to restamp the UUID — it is their only behavioural
difference from rules 1 and 3, which write nothing — the suite verifies that those rules emit
a row, and nothing about the one thing they are for.

---

## 4. F6 is the finding with the widest blast radius

Confirmed by direct measurement. The retirement mechanisms were swapped — dead record and
delete indicator inverted, a change that corrupts every retirement in the design:

| Where the same fault was injected | Result |
|---|---|
| `poc_v2/00_objects.sql` — **the MERGE that ships** | **69 pass, 0 fail. No effect whatsoever** |
| `tools/run_scenario_duckdb.py` — `MERGE_AS_THREE`, the emulation | **58 pass, 11 fail. Caught immediately** |

The shipped `MERGE` is never executed by the suite. `check_merge_drift.py` proves 70 copies
are byte-identical — 70 copies of a statement no test runs.

**This bounds what the other 68 results mean.** Step 1 (the diff view) is genuinely well
tested. Step 2 (the apply) is tested only as a hand-written emulation that happens to live
beside it. The shipped MERGE's only real execution was the manual Snowflake screenshot pass —
which is real evidence, but it is 69 single observations, not a regression suite.

The emulation also applies its branches **sequentially** (`U`, then `D`, then `I`), whereas a
real multi-clause `MERGE` evaluates every clause against one pre-statement snapshot. That is
safe only while the diff emits at most one instruction per target row — the exact property F1
breaks. The two findings compound.

---

## 5. D7 is our own error, made in this session

The root `README.md` wording criticised by D7 was written on 2026-09-26, in the commit that
brought the md files current — it is not v1 residue. It lists among cases *"all covered and
confirmed"*:

- *"a gap in cover with the same value either side"* — F4 shows S05 does not test this; its
  seed data uses **different** values either side, so the gap-guard never does any work
- *"the same version arriving twice in one window"* — F2 shows S07 TC05 is constructed so the
  fan-out is invisible to its own assertion

Both claims were inherited from `solution_design.md` §4's trap list and repeated without
checking whether v2's scenarios still exercised them. The review is right, and the mechanism
it identifies is right: **the v1→v2 transition ported the narrative and dropped the
assertions.**

---

## 6. Where we disagree with nothing, but would add one thing

The review's recommended method change — *"replace '18/18 rules reached' as the coverage gate
with a mutation score"* — is correct and this exercise demonstrates why: rule coverage is
**reachability**, and five separate faults leave all 69 cases green.

One addition. A mutation score is only as good as the code it mutates. Under F6, mutating
`00_objects.sql` scores **0%** — every mutant survives, because none of that file is executed.
So B4 (bring the harness under drift control) is not merely one of four blockers; it is a
**precondition for the mutation gate to mean anything**. It should be sequenced first.

---

## 7. Status

No code or test changes have been made in response to this review. Next steps are to be
agreed item by item. The findings are recorded here so that agreement starts from verified
facts rather than from claims.

The one item already actioned is nothing more than this document: the review's own exit
criteria (B1–B4) remain open, and `poc_v2/README.md`'s open list already states that the
POC's coverage is complete while delivery is not.
