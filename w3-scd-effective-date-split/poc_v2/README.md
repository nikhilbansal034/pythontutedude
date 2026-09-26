# POC v2 — MERGE-based, against the locked rule table

Everything for the POC lives here. **69 test cases across 15 scenarios, 69 passing, executed against Snowflake and evidenced.**

The first POC has been deleted. It was written before the 18-rule table existed and implemented a plain
hash-diff instead, so running it would have produced behaviour the design no longer specifies. Its scenario
catalogue survives as `../sources/Final_Scenarios_v2.xlsx`, kept for provenance only.

## Result — the POC is proven

**69 test cases across 15 scenarios, 69 passing**, executed against Snowflake and evidenced by 346
captioned screenshots in `evidence/POC_Evidence.xlsx`. Every screenshot was checked against
`evidence/expected_results.txt` field by field — `RULE_NO`, `ACTION_FLAG`, `DEL_IND`, business key, status
and tier codes, both dates, `IS_DEL`, `AUDIT_BATCH_ID`, row counts, and the MERGE inserted/updated counts.
No discrepancies.

### Rule coverage, measured rather than claimed

**15 of the 18 rules emit a stage row** and were observed directly in the evidence. **Rules 1, 3 and 18
emit nothing at all** — they are the do-nothing rules — so they are proved by **zero writes**, not by a
visible row. Calling them "covered" the same way as the others would be false.

| | Rules | Proved by |
|---|---|---|
| Observed directly | 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 | a stage row carrying that `RULE_NO` |
| Zero writes | 1, 3, 18 | 0 stage rows and 0 rows written, in the idempotent and orphan cases |

### What each scenario proved

| | Scenario | TCs | What the evidence establishes |
|---|---|---|---|
| S01 | One source changes, the other does not | 7 | The core case: SRC_1 is untouched, yet its target rows still have to move. Reaches 7, 13, 11, 9, 5, 17 |
| S02 | Both sources change in the same run | 4 | Two sources splitting in one run, including both closing on the **same** date |
| S03 | A change in a column the target never carries | 4 | `NOTE_TEXT` moving on every version at once writes **nothing** |
| S04 | A value comes back after a different one | 4 | Repeated values do not collapse — the two A1 stretches stay separate rows |
| S05 | A gap in cover, same value either side | 4 | Gaps survive, get their own NULL-status rows, and work at the start of a timeline and to the high end date |
| S06 | A value corrected with no change to its dates | 4 | **Dead records**: `ROW_EFF_DTE = ROW_EXP_DTE`, `IS_DEL` stays `'N'`. Also correction to NULL |
| S07 | Several runs in one day, same key | 5 | Run 3 sees what run 2 left; two deliveries inside one window; a duplicate `(key, eff date)` with identical timestamps resolves to the incumbent and writes nothing |
| S08 | A key no source touched this run | 4 | K8 stays at batch 101 throughout — impacted-key detection does not reach too far |
| S09 | A key appearing for the first time | 4 | A brand-new key mid-stream |
| S10 | Back-dated correction | 4 | **Delete-indicator** retirement: `IS_DEL = 'Y'`, both dates untouched, and **no row anywhere has `eff = exp`** — the two retirement mechanisms stay genuinely distinct |
| S11 | Stale / orphan row | 5 | The orphan stays live and untouched across five runs, same surrogate key, same batch id |
| S12 | `execution_type = Z1_RERUN` | 8 | All eight rerun variants, and the regression guard for the defect below |
| S13 | `execution_type = RESTART` | 4 | A failed run processes nothing; the restart applies exactly once |
| S14 | Hash-definition change | 5 | **Gradual migration**: a key re-derives only when its own source timestamp moves, not when the hash formula changes |
| S15 | Volume and invariants | 3 | Many keys at once; no NULL business key reaches the target, no key overlaps itself, one live row per `(key, eff date)` |

### A real defect, found and fixed

S12 exposed a genuine product bug, not a test bug. On a `Z1_RERUN` the classifier added 1 to **every** rule
including 17, so a genuinely new interval classified as **18** — which means "this target row is gone from
the timeline, do nothing" and is not selected by the `'I'` branch. **The insert was silently dropped and the
target lost all cover from that date onward.** The `+1` now applies only to rules 1–16, and **S12 TC03 is
the regression guard**: the evidence shows `RULE_NO = 18` appearing nowhere, the rule-17 insert reaching
`9999-12-31`, and cover unbroken.

### Known evidence gaps

Neither changes a verdict, and both are recorded rather than papered over:

- Snowflake's floating Copilot button partly covers `AUDIT_BATCH_ID` on several target-AFTER shots; **batch
  104 is never legible anywhere in S01.** Every other row in those grids reads cleanly.
- Empty-stage screenshots are cropped just below the header row, so the grid is visibly empty but the
  "0 rows" badge is out of frame. The paired MERGE shots (0 inserted / 0 updated) corroborate it.

---

## Why the rule changed

| | v1 | v2 |
|---|---|---|
| The rule | hash decided the action | **the target row's current expiry decides first**, hash only inside the high-end-date branch — `../solution_design.md` §6, 18 rows |
| Retirement | blanket `IS_DEL = 'Y'` | **dead record** (expiry was 9999 — pull it back to the row's own effective date, `IS_DEL` stays `'N'`) vs **delete indicator** (expiry was a real date — set `IS_DEL = 'Y'`, leave both dates alone) |
| Apply | separate `UPDATE` then `INSERT` | **one `MERGE`** — separate statements are not approved by the client |

Also new: the `'U'` expire-in-place branch — the only rule where the surrogate key survives and no
replacement row appears — and the target read must exclude dead records, which keep `IS_DEL = 'N'`:
`is_del = 'N' AND row_eff_dte < row_exp_dte`.

## Layout

| | |
|---|---|
| `00_objects.sql` | every object, the Step 1 diff view, and the Step 2 MERGE. **Run once, first.** The MERGE at its foot is a no-op there (`CREATE OR REPLACE` leaves the stage empty), so running the file also syntax-checks the statement without touching data |
| `scenarios/S01.sql` … `S15.sql` | one file per scenario. Run top to bottom |
| `TEST_PLAN.md` | the grid — 15 scenarios, 69 test cases, the rules each one reaches, and its result |
| `evidence/` | `POC_Evidence.xlsx` — tab 1 the rules, tab 2 the grid with its Result column, then one tab per scenario holding **346 captioned screenshots** of the real run. Alongside it: `expected_results.txt` (the expected result for all 69 test cases), `verdicts.json` (the verdict per test case), `caption_ledger.json` (every caption, reviewable without opening Excel) |

## How the scenarios are built

**The target is never hand-seeded.** TC01 loads an empty target through the real pipeline and every later
test case is the **next run** against whatever the previous one left — which is what the ETL schedule
actually does, and the only way to test that rows a run should not touch stay untouched. Every test case
from TC02 on asserts that explicitly, keyed on `AUDIT_BATCH_ID`.

There is **one reset**, at the top of each file. Test cases must run in order; each is still a section you
can execute and screenshot on its own, and scenarios are independent of each other.

`TC02 (D1R2)` means test case 2, day 1 run 2. Three runs a day, 08:00 / 12:00 / 16:00. Source changes are
written the way Zone1 writes them — `UPDATE` the previous version's `ROW_EXP_DTE`, `INSERT` the new one, both
with a fresh `GRS_REFINED_TIMESTAMP` — not a reseed.

The surrogate-key sequence is **never restarted**: production does not reuse a key, so neither does this.

## Do not edit the .sql files by hand

They are generated. Edit the spec and regenerate:

```
python3 ../tools/mk_scenarios.py            # all 15, or name them: mk_scenarios.py S03 S07
python3 ../tools/refresh_docs.py            # rebuilds TEST_PLAN grid + workbook tabs 1-2 from a real run
```

The apply MERGE is lifted verbatim from `00_objects.sql` into every scenario, so all 70 copies stay
byte-identical.

## Checks — run all three after any SQL change

```
python3 ../tools/check_sql_lint.py          # no function call inside VALUES; no CURRENT_TIMESTAMP in seeds
python3 ../tools/check_merge_drift.py       # every copy of the apply MERGE is byte-identical
python3 ../tools/run_scenario_duckdb.py S07.sql
```

## Re-annotating the evidence workbook

```
python3 ../tools/annotate_evidence.py --xlsx evidence/POC_Evidence.xlsx \
    --expected evidence/expected_results.txt --verdicts evidence/verdicts.json \
    --out evidence/POC_Evidence.xlsx
```

Captions are generated from the expected results, so they state what each shot proves rather than
restating the SQL. The tool edits the OOXML directly: **openpyxl drops every embedded image on
load/save**, and the screenshots are the whole point of the file.

Each screenshot is matched to its test case using the header block the workbook itself carries above each
test case's shots, not by assuming five shots per case. A capture whose shot count does not match its
expected layout **fails the tool** rather than shifting every later caption by one — which is how the two
irregular captures were found (S01 TC03's MERGE pane was never captured; S14 has two extra shots of the
Step 1 view being redefined).

**Never run `mk_evidence_workbook.py` at the populated workbook.** It refuses, by design — regenerating
tabs 1–2 through openpyxl would delete all 346 images.

`check_sql_lint.py` exists because Snowflake rejects `SHA2()` inside a `VALUES` clause and DuckDB does not —
the harness ran green on a file Snowflake would not parse. Both rules it enforces were real defects.

## Scope

- Snowflake only. **No stored procedures.**
- IDMC is deferred. Objects are shaped to fold into the existing ETL pipeline afterwards.
- Source of truth for the rules: `../Requirement.xlsx` and `../solution_design.md` §6.

## Open

The POC's own coverage is complete. **Turning it into the delivered pipeline is not** — the items below are
outstanding, and this list is not closed.

- Does the real stage table already have an operation / CDC indicator column? If so `ACTION_FLAG` takes that
  name and the apply adds **no column at all**. If not, it is the one genuine `ALTER`. **Still open.**
- IDMC is deferred. The objects are shaped to fold into the existing ETL pipeline, but the mapping,
  task and workflow build has not been done.
- The evidence workbook has not had a visual pass in Excel itself — the caption layout is verified by
  geometry and by Excel's cell model, not by eye.
