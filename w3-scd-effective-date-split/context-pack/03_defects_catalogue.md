# Defect catalogue — four generated assets

Every defect found in DataAssist-generated SQL, consolidated. Full write-ups with triggers, evidence and
correct SQL are in `../dataassist/review_hr_tables.md` and `../dataassist/review_office_department_fix.md`;
the `THIRD_PARTY_AGREEMENT` findings are rules in `../dataassist/generation_rules.md`.

**Status key:** `OPEN` · `FIXED` · `WITHDRAWN` (my finding was wrong) · `DECISION` (needs a human).

---

## Scoreboard

| Asset | Source | Shape | Columns right | Findings |
|---|---|---|---|---|
| `THIRD_PARTY_AGREEMENT` | CCO, 8 sources | multi-source + SCD-2 FK | 76% | 8 open, 1 withdrawn |
| `DEPARTMENT` | ADW HR | single source | 19/21 | 7 open |
| `JOB` | ADW HR | single source | 23/25 | 7 open |
| `OFFICE_DEPARTMENT` r1 | ADW HR | composite key, 2 SCD-2 FKs | 34/36 | 6 fixed, 3 open |
| `OFFICE_DEPARTMENT` r2 | — | after the fix round | **36/36** | **4 new**, incl. 1 critical |

---

## The two patterns everything falls into

**Pattern 1 — the generator improvises where the mapping is ambiguous, and never says so.**
A misspelled function, an identifier in prose that does not resolve, a bare `Audit Field` on an indicator
column. Each produced clean, runnable, **wrong** SQL. *Wrong SQL that runs is the worst possible output,
because no one looks at it again.*

**Pattern 2 — the generator computes the right thing and loses it on the way out.**
Only seen in the fix round, and it is a different failure needing a different guard: the split is derived
correctly, then discarded by the output stage. No amount of clearer mapping prevents this. **Assertions on
what is actually written** do, and that is the one finding still open from every round.

---

## Critical — fix before any run

### OD10 · the foreign-key split is computed, then discarded · `OPEN`

`fk_split_stg` derives each sub-interval under `SPLIT_` aliases but carries the original staging dates
alongside via `SELECT s.*`. The FK lookups correctly use the split dates — then the output emits the
**original** ones, and the closing `QUALIFY` partitions on the original effective date, identical on every
sub-interval. The sub-intervals collapse back to one row.

Executed, on an association spanning two office versions: **two correct sub-intervals in, one row out**,
carrying the unsplit interval and the office version that did not exist for the first four months of it.
The surviving FK is arbitrary — the tie-break compares `9999-12-31` to `9999-12-31`.

> **Worse than not splitting at all.** Without a split the row would at least carry the parent in force at
> its own start.

**Fix:** emit `SPLIT_ROW_EFFECTIVE_DATETIME` / `SPLIT_ROW_EXPIRATION_DATETIME` as the row dates; key the
`QUALIFY` and the target join on the split date; recompute `CURRENT_RECORD_INDICATOR` from the split
expiry. Four references and one expression.

### OD11 · the hash includes the row dates · `OPEN` — ships with OD10

`AUDIT_CHANGE_HASH` now covers `ROW_EFFECTIVE_DATETIME`, `ROW_EXPIRATION_DATETIME` and
`CURRENT_RECORD_INDICATOR`, and is computed in Q1 **before the split exists**. So once OD10 is fixed, two
sub-intervals of one staging row carry the **same hash** despite different periods and different FKs.

It also breaks the incremental rule table outright: with the dates inside, every interval split reads as a
value change.

**Fix:** delete the three date-derived terms. **This is assumption A1 of
`02_incremental_load_instructions.md`.**

---

## Open across all assets

| | Finding | Assets | Fix |
|---|---|---|---|
| **No post-write assertions** | Every check runs against staging; nothing asserts the rows actually written. **This is why all of the above reached human review instead of failing at run time** | all 4 | row-count comparison across each transformation, plus the keyed checks moved downstream |
| **Unresolved FK lands as NULL, uncounted** | Both lookups are `LEFT JOIN`, on a row that is nothing but its two FKs. Load-order dependency on the parents is also undeclared | OD | two checks + a comment |
| **NULL interval date drops the row silently** | The containment predicate evaluates to NULL; the interval checks are NULL-blind | OD r2 | one NULL guard in Q1 |
| **Audit ids invented from the clock** | `TO_NUMBER(TO_VARCHAR(CURRENT_TIMESTAMP(),…))` instead of the framework's parameters — the load cannot be traced | TPA, OD r2 | restore `$AUDIT_BATCH_ID` / `$AUDIT_JOB_ID` |
| **Containment check missing** | The only check that catches a misclassified split table. Omitted on an 8-contributor table | TPA | one per contributor |
| **`MERGE` keyed on a resolved FK surrogate** | A renumbered parent makes the merge match zero rows and insert the business row again | TPA | key on the business key |
| **SCD-2 FK resolved on start date alone** | A row spanning a parent version boundary carries the expired version for its tail | TPA | boundary-split at the parent's versions |

---

## The HR template defects — one STTM template, three tables

**All six reproduce identically on `DEPARTMENT`, `JOB` and `OFFICE_DEPARTMENT`.** They belong to the
mapping template and to the generator's fall-through behaviour, **not to any table.** Fixing them per table
will not converge.

| | Finding | Status |
|---|---|---|
| **D1/J2/OD4** | `SOURCE_SYSTEM_NAME` takes the **incremental** branch in a historical file, hardcoding `'EMPLOYEE'`. Root cause: the STTM's column cell reads `src_sys_nme`, its prose reads `src_sys_nm` — **in all three sheets** — and the generator falls through rather than halting | `FIXED` on OD r2; open on the other two. **Fix the template** |
| **D2/J3/OD5** | `DELETE_INDICATOR` emitted as NULL where a historical row needs `'N'`. Note `CURRENT_RECORD_INDICATOR` has the same bare `Audit Field` transformation and *was* derived correctly — a rule exists for one indicator and not the other | `FIXED` on OD r2; open elsewhere |
| **D3/J4/OD6** | Three of the self-checks are **tautologies** — they restate what the same query just computed, so they report zero whatever the data holds. The duplicate-key check is the costly one: the de-duplication is what hides a corrupt source chain, and the check runs downstream of it | `FIXED` on OD r2 (moved pre-dedup, loss-check added, the other two honestly relabelled "tamper guard") |
| **D4/J6** | No `TRUNCATE` on a truncate-and-reload load; a re-run doubles the target | `FIXED` on OD r2 (guard + commented truncate) |
| **D5/J5/OD7** | Q2 re-reads `$AUDIT_BATCH_ID` instead of carrying staging's, so the target records the batch that *moved* the rows, not the one that produced them | `OPEN` everywhere |
| **D6/J7/OD8** | Hash separator `\|` can occur in the data; `COALESCE(…,'')` makes NULL and `''` identical | `FIXED` on OD r2 (`CHR(31)` + `'~NULL~'`) |

---

## Table-specific

### J1 · `JOB`'s business key is probably incomplete · `DECISION`

The STTM flags only `Job_Code` as natural key. The table also carries `HR_Business_Group_Code`. A
four-character job code being unique across *every* HR business group is an assumption nothing states.

Executed with one job code in two business groups: **a whole job disappeared, and all eight self-checks
reported zero.** Nothing in the output says a row was lost.

> `OFFICE_DEPARTMENT` later proved the generator uses **every** natural key the STTM declares — both of its
> flagged columns appear in the dedup and every keyed check. **So J1 is a mapping defect, not a generator
> defect**, and the fix belongs in the STTM.

**Settle it with one query:**

```sql
SELECT COUNT(*) FROM (
  SELECT JOB_CDE, ROW_EFF_DTE FROM <HR_JOB_T> GROUP BY 1,2 HAVING COUNT(*) > 1);
```

Non-zero means job codes are not globally unique and the historical load is losing rows.

### `THIRD_PARTY_AGREEMENT` · two mapping errors for the modeller · `DECISION`

- **`CONTRACT_T` has no `PRSP_ID`**, but the STTM joins on it for three broker columns. The STTM is wrong
  *and* the generator substituted a different join silently.
- **12 `COALESCE` fallbacks dropped**, because the STTM spells it `coalasce` in all 12 rows. Confirmed data
  loss: `CONTRACT_T` carries every one of the fallback columns.

### Withdrawn

**`CNTR_CLM_ADMNM_T` bounded by business dates** — I raised this as a defect. The DDL shows the table has
no `ROW_EFF_DM` and is **not SCD-2**, so its business dates *are* its version interval and the generator
was right. The surviving rule is *"read the interval basis off the DDL"*, which also catches the real trap:
`CONTRACT_T` has **two** candidate date pairs (`ROW_EFF_DM` and `ADW_ROW_EFF_DM`) and only prose
disambiguates them.

---

## What to verify a fix against

Each review has a runnable script reproducing every executed claim in it. They need `duckdb` only.

```
python3 tools/verify/verify_department_findings.py            # D*, J*, OD1-9
python3 tools/verify/verify_office_department_fix_review.py   # OD10-13
python3 tools/verify/verify_tpa_assertions.py                 # constant-keyed checks
python3 tools/verify/verify_tpa_agreement_fk.py               # stale FK, duplicate insert
python3 tools/verify/verify_historical_examples.py            # the split, collapse, gaps
python3 tools/verify/verify_historical_check7.py              # containment check
```
