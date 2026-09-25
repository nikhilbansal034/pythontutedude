# POC v2 — test plan

Everything proved in POC v1 is treated as **unproven**. The rule changed after v1 ran, so its evidence
describes behaviour the design no longer specifies. Coverage is re-established from nothing.

Rules referenced below are the 18 in `../solution_design.md` §6.

## Coverage target

Every one of the 18 rules exercised at least once, plus the cross-cutting properties that are not
rule-specific: idempotence, atomicity, determinism, and behaviour on corrupt input.

| Code | Type | Proves |
|---|---|---|
| **P** | positive | the canonical case produces the expected target |
| **I** | idempotent | re-running the same input writes **zero** rows |
| **N** | negative | input that must produce no change at all |
| **E** | edge | zero-length rows, same eff and exp, high-end-date boundaries |
| **C** | corrupt | NULL key, duplicate (key, eff date), timestamp outside the window |
| **V** | volume | random keys at scale, compared row for row against `../tools/verify.py` |

## The grid

| Scenario | TC | Type | What it does | Rules |
|---|---|---|---|---|
| **S01** One source changes | TC01 | P | SRC_2 splits, SRC_1 untouched. The base case | 1, 3, 7, 13, 17 |
| | TC02 | I | run S01 twice, second run writes nothing | 1, 3 |
| | TC03 | E | SRC_2 changes exactly on an existing boundary — no new interval | **9** |
| | TC04 | C | SRC_2 carries a NULL business key — dropped **silently** | — |
| **S02** Both sources change | TC01 | P | both split in the same run; target row sat at 9999 | 5, 17 |
| | TC02 | I | re-run, zero writes | 1 |
| | TC03 | E | both sources close on the same date | 5, 17 |
| **S03** Non-target column | TC01 | P | only a column the target never carries changes | 1 |
| | TC02 | N | 0 rows written, stage is empty | — |
| | TC03 | E | the non-target column changes on every version at once | 1 |
| **S04** Value returns later | TC01 | P | A1 → A2 → A1; the two A1 runs must stay separate | 17 |
| | TC02 | E | three alternations in one key | 17 |
| **S05** Gap in cover | TC01 | P | uncovered interval carries a blank | 17 |
| | TC02 | E | gap at the start, and a gap ending at the high end date | 17 |
| **S06** Corrected, same dates | TC01 | P | value changes, both dates identical. Target at 9999 | 9, 17 |
| | TC02 | I | re-run, zero writes | 1 |
| | TC03 | E | correction to a value that is NULL on one side | 9 |
| **S07** Several runs one day | TC01 | P | two runs same day, run 2 sees what run 1 left | 5, 17 |
| | TC02 | P | both same-day rows inside ONE window — the Q1 case | 5, 17 |
| | TC03 | E | three runs in one day | 5, 17 |
| | TC04 | C | duplicate (key, eff date) with identical timestamps — no tie-break | — |
| **S08** Key not touched | TC01 | P | K1 impacted, K8 outside the window | 1, 3, 7, 13, 17 |
| | TC02 | N | K8 neither read nor written — prove by row count | — |
| | TC03 | E | a key impacted but whose content is identical — read, zero writes | 1, 3 |
| **S09** Brand new key | TC01 | P | empty target, everything inserts | 17 |
| | TC02 | E | new key whose first version already sits at the high end date | 17 |
| **S10** Back-dated correction | TC01 | P | hash changes on a closed row, expiry unchanged | **11** |
| | TC02 | P | hash and expiry both change on a closed row | **15** |
| | TC03 | I | re-run, zero writes | 1, 3 |
| | TC04 | E | correction to the oldest row in a long history | 11 |
| **S11** Stale / orphan row | TC01 | P | Zone1 loses history; orphan left live, untouched | **18** |
| | TC02 | I | re-run while degraded — orphan still untouched | 18 |
| | TC03 | P | Zone1 recovers; timeline self-heals, orphan falls to rule 1 | 1, 5 |
| | TC04 | E | two overlapping live rows — prove read-by-effective-date returns the right one | 18 |
| **S12** execution_type RERUN | TC01 | P | rerun, nothing changed, target at 9999 | **2** |
| | TC02 | P | rerun, nothing changed, target at a real date | **4** |
| | TC03 | P | rerun, expire in place, target at 9999 | **6** |
| | TC04 | P | rerun, retire, hash same, target at a real date | **8** |
| | TC05 | P | rerun, dead record, hash diff, expiry same, target at 9999 | **10** |
| | TC06 | P | rerun, retire, hash diff, expiry same, target at a real date | **12** |
| | TC07 | P | rerun, dead record, hash and expiry diff, target at 9999 | **14** |
| | TC08 | P | rerun, retire, hash and expiry diff, target at a real date | **16** |
| | TC09 | I | rerun twice — UUID restamped, nothing else moves | 2, 4 |
| **S13** execution_type RESTART | TC01 | P | MERGE commits, run marked failed, restart re-applies | — |
| | TC02 | I | restart writes zero rows | 1, 3 |
| | TC03 | E | restart when the stage is half-built | — |
| | TC04 | C | restart with the target read missing its dead-record filter — must fail loudly | — |
| **S14** Hash-definition change | TC01 | P | column added; an impacted key re-derives under rules 9–16 | 9, 11, 13, 15 |
| | TC02 | N | a quiet key is untouched and keeps the new column empty | — |
| | TC03 | E | surrogate-key churn measured and recorded | — |
| **S15** Volume / differential | TC01 | V | 1,000 random keys, one run, compared against `verify.py` | all |
| | TC02 | V | 10 consecutive runs with random mutations, compared each run | all |
| | TC03 | V | random data including corrupt rows | all |

**53 test cases across 15 scenarios.** All 18 rules are exercised at least once.

## Why S15 matters most

A hand-written case proves the rule you were thinking about. A differential test proves the rules you were
not. TC02 in particular — ten consecutive runs, random mutations, compared after every one — is the closest
thing to a proof that the design is stable under repeated application, which is what production actually is.

## Structure

One SQL script per scenario. Each test case is a self-contained section — truncate, seed, run, verify — so
it can be executed and screenshotted independently.

```
00_objects.sql   EVERYTHING that is not a test case: tables, sequence, the live
                 view, the Step 1 diff view, and the Step 2 MERGE. Run once.
                 The MERGE at the foot is a no-op there (CREATE OR REPLACE
                 leaves the stage empty), so running the file also syntax-checks
                 the statement without touching data
S01.sql … S15.sql one per scenario, TC sections within
evidence/        POC_v2_Evidence.xlsx
                 tab 1 the 18 rules, tab 2 this grid, tabs 3+ one per scenario as it is run
```

Step 1 is a **view**, since stored procedures are not allowed. Each test case section reads:

```
TRUNCATE stage  →  INSERT INTO stage SELECT FROM diff view  →  MERGE  →  verify
```
