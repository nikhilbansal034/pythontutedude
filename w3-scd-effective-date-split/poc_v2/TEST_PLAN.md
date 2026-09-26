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
| **S01** One source changes, the other does not | TC01 (D1R1) | P | initial load into an empty target | 17 |
|  | TC02 (D1R2) | P | SRC_2 splits one version into three | 7, 13, 17 |
|  | TC03 (D1R3) | I | re-run of the same window, nothing changed | — (0 writes) |
|  | TC04 (D2R1) | E | SRC_2 splits on a boundary SRC_1 already uses | 11 |
|  | TC05 (D2R2) | E | a value corrected in place, dates unchanged | 9 |
|  | TC06 (D2R3) | C | a NULL business key arrives | — (0 writes) |
|  | TC07 (D3R1) | P | a new version arrives ahead of the open row | 5, 17 |
| **S02** Both sources change in the same run | TC01 (D1R1) | P | initial load into an empty target | 17 |
|  | TC02 (D1R2) | P | both sources split in the same run | 5, 17 |
|  | TC03 (D1R3) | I | re-run of the same window | — (0 writes) |
|  | TC04 (D2R1) | E | both sources close on the SAME date | 5, 17 |
| **S03** A change in a column the target never carries | TC01 (D1R1) | P | initial load into an empty target | 17 |
|  | TC02 (D1R2) | N | only NOTE_TEXT changes | — (0 writes) |
|  | TC03 (D1R3) | P | a real split, so there are several versions to test against | 5, 17 |
|  | TC04 (D2R1) | N | NOTE_TEXT changes on EVERY version at once | — (0 writes) |
| **S04** A value comes back after a different one | TC01 (D1R1) | P | initial load with a value that already repeats | 17 |
|  | TC02 (D1R2) | I | re-run -- the two A1 runs must still not collapse | — (0 writes) |
|  | TC03 (D1R3) | E | a third alternation | 5, 17 |
|  | TC04 (D2R1) | E | a fourth alternation, back to A1 again | 5, 17 |
| **S05** A gap in cover, with the same value either side | TC01 (D1R1) | P | initial load with a hole in SRC_1 | 17 |
|  | TC02 (D1R2) | I | re-run -- the gap must survive | — (0 writes) |
|  | TC03 (D1R3) | E | a gap at the START of the timeline | 17 |
|  | TC04 (D2R1) | E | a gap that runs to the high end date | 5, 17 |
| **S06** A value corrected with no change to its dates | TC01 (D1R1) | P | initial load into an empty target | 17 |
|  | TC02 (D1R2) | P | the value is corrected, both dates unchanged | 9 |
|  | TC03 (D1R3) | I | re-run of the same window | — (0 writes) |
|  | TC04 (D2R1) | E | corrected to NULL | 9 |
| **S07** Several runs in one day against the same key | TC01 (D1R1) | P | day 1 run 1 -- initial load | 17 |
|  | TC02 (D1R2) | P | day 1 run 2 -- SRC_2 moves | 5, 17 |
|  | TC03 (D1R3) | P | day 1 run 3 -- and it sees what run 2 left | 5, 17 |
|  | TC04 (D2R1) | P | TWO deliveries inside ONE window | 5, 17 |
|  | TC05 (D2R2) | C | duplicate (key, effective date) with IDENTICAL timestamps | — (0 writes) |
| **S08** A key no source touched this run | TC01 (D1R1) | P | initial load of TWO keys | 17 |
|  | TC02 (D1R2) | P | only K1 changes -- K8 is outside the window | 5, 17 |
|  | TC03 (D1R3) | I | re-run -- K8 still untouched | — (0 writes) |
|  | TC04 (D2R1) | E | K8 IS impacted, but its content is identical | — (0 writes) |
| **S09** A key appearing for the first time | TC01 (D1R1) | P | an empty target -- everything inserts | 17 |
|  | TC02 (D1R2) | P | a second brand-new key, alongside an existing one | 17 |
|  | TC03 (D1R3) | E | a new key arriving with SEVERAL versions at once | 17 |
|  | TC04 (D2R1) | I | re-run -- no key inserts twice | — (0 writes) |
| **S10** A back-dated correction to an already-closed interval | TC01 (D1R1) | P | initial load with closed intervals to correct later | 17 |
|  | TC02 (D1R2) | P | hash changes on a closed row, expiry unchanged | 11 |
|  | TC03 (D1R3) | I | re-run of the same window | — (0 writes) |
|  | TC04 (D2R1) | E | hash AND expiry both change on a closed row | 15, 17 |
| **S11** A stale / orphan row after Zone1 loses history | TC01 (D1R1) | P | initial load, three intervals | 17 |
|  | TC02 (D1R2) | P | Zone1 loses its early history | — (0 writes) |
|  | TC03 (D1R3) | I | re-run while still degraded | — (0 writes) |
|  | TC04 (D2R1) | E | PARTIAL recovery -- and this is where it costs | 17 |
|  | TC05 (D2R2) | E | FULL recovery -- the original orphan self-heals | — (0 writes) |
| **S12** execution_type = Z1_RERUN | TC01 (D1R1) | P | initial load, one closed row and one open row | 17 |
|  | TC02 (D1R2) | P | rerun, nothing changed -- rules 2 AND 4 | 2, 4 |
|  | TC03 (D1R3) | E | rerun with a genuinely NEW interval -- rule 6 and rule 17 | 4, 6, 17 |
|  | TC04 (D2R1) | P | rerun, dead record -- rule 10 | 4, 10 |
|  | TC05 (D2R2) | P | rerun, back-dated correction -- rule 12 | 2, 4, 12 |
|  | TC06 (D2R3) | P | rerun, expiry moves on a closed row -- rule 8 | 2, 4, 8, 17 |
|  | TC07 (D3R1) | P | rerun, hash AND expiry move at the high end date -- rule 14 | 4, 14, 17 |
|  | TC08 (D3R2) | P | rerun, hash AND expiry move on a closed row -- rule 16 | 2, 4, 16 |
| **S13** execution_type = RESTART | TC01 (D1R1) | P | initial load | 17 |
|  | TC02 (D1R2) | N | the run FAILS before it processes anything | — (0 writes) |
|  | TC03 (D1R3) | P | the RESTART picks it up | 5, 17 |
|  | TC04 (D2R1) | I | restarting twice applies it once | — (0 writes) |
| **S14** The hash definition itself changes | TC01 (D1R1) | P | initial load of two independent keys | 17 |
|  | TC02 (D1R2) | P | the hash definition changes -- and only K1 is impacted | 9, 11 |
|  | TC03 (D1R3) | I | re-run under the NEW definition | — (0 writes) |
|  | TC04 (D2R1) | P | K2 becomes impacted, and re-derives in its turn | 9, 11 |
|  | TC05 (D2R2) | P | restore the original hash definition | 9, 11 |
| **S15** Many keys at once, and the invariants that must always hold | TC01 (D1R1) | V | six keys of different shapes, loaded at once | 17 |
|  | TC02 (D1R2) | V | several keys change at once, in different ways | 5, 9, 17 |
|  | TC03 (D1R3) | C | corrupt rows arrive alongside good ones | — (0 writes) |

**69 test cases across 15 scenarios.** Every one of the 18 rules is reached.
Rules **1, 3 and 18 emit no stage row at all** -- they are the do-nothing rules -- so they are
proved by ZERO WRITES in the idempotent cases rather than by an observable row.
The Rules column is measured from a real run, not asserted.

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
