# POC v2 — MERGE-based, against the locked rule table

Everything for the second POC lives here. The v1 files in the parent folder are left untouched as
a record of what was proved before the rule changed.

## Why a second POC

Three things changed after v1 was run and evidenced:

| | v1 | v2 |
|---|---|---|
| The rule | hash decided the action | **the target row's current expiry decides first**, hash only inside the high-end-date branch — `solution_design.md` §6, 18 rows |
| Retirement | blanket `IS_DEL = 'Y'` | dead record (expiry was 9999) vs delete indicator (expiry was a real date) |
| Apply | separate `UPDATE` then `INSERT` | **one `MERGE`** — separate statements are not approved by the client |

Also new: the `'U'` expire-in-place branch, and the target read must exclude dead records
(`is_del = 'N' AND row_eff_dte < row_exp_dte`).

## Scope

- Snowflake only. **No stored procedures.**
- IDMC is deferred. Objects are shaped so they can be folded into the existing ETL pipeline afterwards.
- Source of truth for the rules: `../sources/Requirement.xlsx` and `solution_design.md` §6.
- Scenario data follows `../Final_Scenarios_v2.xlsx` — same Day 1 / Day 2 pattern.

## Status

Architecture under discussion. No SQL written yet.
