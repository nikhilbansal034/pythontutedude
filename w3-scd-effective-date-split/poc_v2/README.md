# POC v2 — MERGE-based, against the locked rule table

Everything for the POC lives here. **69 test cases across 15 scenarios, 69 passing.**

The first POC has been deleted. It was written before the 18-rule table existed and implemented a plain
hash-diff instead, so running it would have produced behaviour the design no longer specifies. Its scenario
catalogue survives as `../sources/Final_Scenarios_v2.xlsx`, kept for provenance only.

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
| `TEST_PLAN.md` | the grid — 15 scenarios, 69 test cases, with the rules each one reaches |
| `evidence/` | the workbook: tab 1 the rules, tab 2 the grid, tab 3 on for screenshots |

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

`check_sql_lint.py` exists because Snowflake rejects `SHA2()` inside a `VALUES` clause and DuckDB does not —
the harness ran green on a file Snowflake would not parse. Both rules it enforces were real defects.

## Scope

- Snowflake only. **No stored procedures.**
- IDMC is deferred. Objects are shaped to fold into the existing ETL pipeline afterwards.
- Source of truth for the rules: `../Requirement.xlsx` and `../solution_design.md` §6.

## Open

- Does the real stage table already have an operation / CDC indicator column? If so `ACTION_FLAG` takes that
  name and the apply adds **no column at all**. If not, it is the one genuine `ALTER`.
