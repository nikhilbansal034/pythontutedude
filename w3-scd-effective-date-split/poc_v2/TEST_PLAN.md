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
| **S01** One source changes | TC01 (D1R1) | P | initial load into an EMPTY target — the day-1 build, run not asserted | 17 |
| | TC02 (D1R2) | P | SRC_2 splits one version into three. SRC_1 untouched. The base case | 3, 7, 13, 17 |
| | TC03 (D1R3) | I | re-run of the SAME window — key still impacted, nothing changed | 1, 3 |
| | TC04 (D2R1) | E | SRC_2 splits on a boundary SRC_1 already uses — no new interval | **11** |
| | TC05 (D2R2) | E | a value corrected in place, both dates unchanged | **9** |
| | TC06 (D2R3) | C | a NULL business key arrives — dropped **silently** | — |
| | TC07 (D3R1) | P | new version ahead of the open row — EXPIRE IN PLACE, key survives | **5**, 17 |
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

**56 test cases across 15 scenarios.** All 18 rules are exercised at least once.

## Two clocks, and the seed rules that follow from them

| | Column | Meaning |
|---|---|---|
| **Business time** | `ROW_EFF_DTE` / `ROW_EXP_DTE` | when the fact was true |
| **Process time** | `GRS_REFINED_TIMESTAMP`, `AUDIT_*` | when the row was loaded |

Process time runs forward across runs and every seed value is a **fixed literal**:

```
run 101  "day 1"  loaded 2026-09-21 08:00
run 102  "day 2"  window 2026-09-21 08:00 (EXCLUSIVE) -> 2026-09-22 10:00
```

Two rules hold for every scenario, both enforced by `../tools/check_sql_lint.py`:

1. **Never `CURRENT_TIMESTAMP()` in a seed.** A day-1 row stamped "now" is dated *later* than the day-2
   window meant to follow it. The MERGE is exempt — stamping the audit columns at apply time is what
   production does, so rows a run touches carry today's date and rows it does not keep the seeded one.
2. **Never a function call inside `VALUES`.** Snowflake rejects it outright
   (`Invalid expression [SHA2(...)] in VALUES clause`); DuckDB accepts it, so the harness cannot see this.
   Seeds use `INSERT .. SELECT .. UNION ALL`.

## Surrogate keys are never reset

`SEQ_BROKER_PARTY_DIM_SK` is **not** restarted between runs or test cases — production never reuses a
surrogate key, and the POC replicates that. Re-running a scenario therefore allocates fresh keys: TC01
produced `1-4`, then `6-9`, then `11-14` across three consecutive runs.

Two consequences:

1. **No assertion may reference a generated surrogate key.** Assertions check row counts, date continuity,
   `IS_DEL` and the live-view shape — never a key the sequence produced. Seeded keys (`101`, `102`, `103`)
   are fixed and safe to name. Verified by running S01 three times against one advancing sequence: 5/5 every
   time, with different keys each run.
2. **Screenshots of the same test case will show different keys on a re-run.** That is expected. Record what
   the run produced rather than expecting a fixed value.

## Why S15 matters most

A hand-written case proves the rule you were thinking about. A differential test proves the rules you were
not. TC02 in particular — ten consecutive runs, random mutations, compared after every one — is the closest
thing to a proof that the design is stable under repeated application, which is what production actually is.

## Structure — chained runs, not reset-per-test-case

One SQL script per scenario. **The target is never hand-seeded.** TC01 loads an empty target through the
real pipeline, and every later test case is the **next run** against whatever the previous one left behind.

| | |
|---|---|
| **Reset** | Once, at the top of the scenario file. Test cases do not reset |
| **Order** | Test cases run top to bottom. Each is still a section you can execute and screenshot on its own |
| **Isolation** | Scenarios stay fully independent of each other |
| **Labels** | `TC02 (D1R2)` — test case 2, day 1 run 2. Three runs a day, 08:00 / 12:00 / 16:00 |

Why: the thing under test is **incremental** SCD2 loading. Truncating before every test case never tests an
increment — it tests 53 single loads against hand-placed targets, and hand-placing the target means the
expected day-1 state is asserted rather than derived. The bugs this design actually risks — older rows
touched when they should not be, impacted-key detection reaching too far, windows overlapping at the
boundary — only appear across consecutive runs. Every test case from TC02 on therefore carries an explicit
**older rows untouched** assertion, keyed on `AUDIT_BATCH_ID`.

A scenario whose premise needs a clean slate (S09's brand-new key, S11's degraded Zone1) resets explicitly
and says so in the file.

Source changes are written the way Zone1 writes them — `UPDATE` the previous version's `ROW_EXP_DTE` and
`INSERT` the new one, both carrying a fresh `GRS_REFINED_TIMESTAMP` — not as a reseed.

**The two clocks are kept in different months** so they cannot be confused: business time
(`ROW_EFF_DTE`/`ROW_EXP_DTE`) in **August**, process time (`GRS_REFINED_TIMESTAMP`, windows, `AUDIT_*`) in
**September**.

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
