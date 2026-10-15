# `OFFICE_DEPARTMENT` — review of the corrected output

**Round 2.** DataAssist was fixed after the first `OFFICE_DEPARTMENT` review and the SQL regenerated.
This file reviews the **new** `OFFICE_DEPARTMENT_Q1_SRC_TO_STG.sql` and
`OFFICE_DEPARTMENT_Q2_STG_TO_TGT.sql` against the same STTM.

Round 1 findings OD1 – OD9 are in `review_hr_tables.md`. This file records **what those
fixes achieved** and **what the fix round introduced**, as rules with triggers in the same form.

---

## Verdict

| | Round 1 | Round 2 |
|---|---|---|
| Column mappings | 34 of 36 | **36 of 36** ✅ |
| Boundary collection | effective dates only | **complete** ✅ |
| Self-checks on staging | 3 tautologies | **rebuilt, and honestly labelled** ✅ |
| **Split reaches the target** | yes | **no** ❌ |
| Safe to run | No | **No** |

**Six of the nine round-1 findings are fixed, and fixed well.** The round introduced one critical defect
and three regressions.

### The pattern in this round

> **Every defect below is a value that was computed correctly and then not used, or one that was already
> correct and got replaced.** None of them is a failure to understand the design.

Round 1's defects came from ambiguity in the mapping. These come from the opposite place: the generator now
builds the right thing and loses it on the way out. That is a different failure mode and needs a different
guard — **assertions on what is actually written**, which is the one round-1 finding still open.

---

## Resolved in this round

| | Round-1 finding | How it was fixed |
|---|---|---|
| **OD1** | `fk_bounds` collected only effective dates | Four FK branches now — effective **and** expiry, for both `OFFICE` and `DEPARTMENT` |
| **OD4** | `SOURCE_SYSTEM_NAME` hardcoded `'EMPLOYEE'` | `CAST(od.SRC_SYS_NME AS VARCHAR(30))`. Also settles the open question: the column **is** `SRC_SYS_NME` |
| **OD4b** | Lineage omitted the source system | `OBJECT_CONSTRUCT(…, 'SOURCE_SYSTEM', f.SOURCE_SYSTEM_NAME, …)` |
| **OD5** | `DELETE_INDICATOR` was NULL | `CAST('N' AS VARCHAR(1))` |
| **OD6** | Checks 1, 2 and 8 were tautologies | Check 1 moved to `all_records`, **pre-dedup**; new check **1b `DEDUP_DISCARDED_ROWS`**; checks 2 and 8 kept and relabelled *"tamper guard"* |
| **OD8** | Hash separator `\|` could occur in the data | `COALESCE(…, '~NULL~') \|\| CHR(31)` throughout |
| truncate | No truncate, no guard | `TARGET_NOT_EMPTY` check at the head of Q2, plus a commented `TRUNCATE` with a note on restartability |
| **OD9** | Part of both files was unreviewed | Both files now start at line 1. Nothing hidden |

**The OD6 resolution is better than what was proposed.** Keeping checks 2 and 8 but declaring them *tamper
guards* is more honest than deleting them: it states what they are for instead of implying they test the
data.

---

## OD10 — the split is computed, used to pick a foreign key, then discarded

**Severity: critical. It silently defeats the entire feature, and leaves the output worse than no split.**

### Trigger
A query derives a corrected value under a new alias while the original remains in scope — typically from
`SELECT s.*` plus a computed column — and a later stage can still reference either.

### The scenario

Office `O001` moved premises on 2024-05-01, so `OFFICE` holds two versions:

| OFFICE_ID | OFFICE_NUMBER | valid from | valid to |
|---|---|---|---|
| 501 | O001 | 2024-01-01 | 2024-05-01 |
| 502 | O001 | 2024-05-01 | 9999-12-31 |

The association `(O001, D001)` was created on 2024-01-01 and **never changed**. One staging row,
`2024-01-01 → 9999-12-31`.

**The correct target is two rows** — not because the association changed, but because its parent did.

### What the query does, step by step

**Steps 1 to 4 are correct.** `fk_bounds` collects `{2024-01-01, 2024-05-01, 9999-12-31}`, `fk_intervals`
turns that into two intervals, and `fk_split_stg` produces two rows. But note what it carries:

```sql
SELECT s.*,
       fi.ROW_EFFECTIVE_DATETIME  AS SPLIT_ROW_EFFECTIVE_DATETIME,
       fi.ROW_EXPIRATION_DATETIME AS SPLIT_ROW_EXPIRATION_DATETIME
```

| | SPLIT_ROW_EFFECTIVE | SPLIT_ROW_EXPIRATION | ROW_EFFECTIVE | ROW_EXPIRATION |
|---|---|---|---|---|
| row 1 | **2024-01-01** | **2024-05-01** | 2024-01-01 | 9999-12-31 |
| row 2 | **2024-05-01** | **9999-12-31** | 2024-01-01 | 9999-12-31 |

`SELECT s.*` means **every sub-interval carries a copy of the original, unsplit dates**. The right answer is
in the `SPLIT_` columns; the old one is still sitting beside it.

The FK lookups then correctly join on `SPLIT_ROW_EFFECTIVE_DATETIME`, so row 1 resolves to office `501` and
row 2 to `502`.

### Step 5 — the output emits the original columns

```sql
CAST(stg.ROW_EFFECTIVE_DATETIME  AS TIMESTAMP_NTZ) AS ROW_EFFECTIVE_DATETIME,    -- line 76
CAST(stg.ROW_EXPIRATION_DATETIME AS TIMESTAMP_NTZ) AS ROW_EXPIRATION_DATETIME,   -- line 77
```

The two rows are now identical except for the foreign key:

| | ROW_EFFECTIVE | ROW_EXPIRATION | OFFICE_ID |
|---|---|---|---|
| row 1 | 2024-01-01 | 9999-12-31 | 501 |
| row 2 | 2024-01-01 | 9999-12-31 | 502 |

### Step 6 — the uniqueness guarantee then deletes one of them

```sql
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY stg.OFFICE_NUMBER, stg.DEPARTMENT_NUMBER, stg.ROW_EFFECTIVE_DATETIME   -- line 137
    ORDER BY stg.ROW_EXPIRATION_DATETIME DESC NULLS LAST) = 1;
```

Both rows share `2024-01-01`, so they fall in one partition and one is dropped. The tie-break compares
`9999-12-31` against `9999-12-31`, so **which survives is arbitrary**.

### The result, executed

```
fk_split_stg produces 2 correct sub-intervals
the generated final SELECT returns:
   ('O001','D001', 2024-01-01, 9999-12-31, OFFICE_ID 502)      <- 1 row
```

**One row covering 2024-01-01 to 9999-12-31, pointing at office version 502 — which did not exist until
2024-05-01.** For the first four months the row points at the wrong office.

Two separate harms:

1. **History is lost.** The Jan–May version of the association never reaches the target.
2. **The surviving row's foreign key is wrong, and wrong arbitrarily.**

> **This is worse than not splitting at all.** With no split you would at least get the office in force at
> the interval's start, `501`. With the split half-applied you get whichever row a tie-break over identical
> values happened to keep.

### Why it is easy to miss

The intent behind line 137 is sound. Its comment reads *"Output guarantee: exactly one row per business key
leaves this query"*, and it protects the downstream IDMC merge from fanning out on a duplicate target row.
The mistake is subtle:

> **After a split, the business key is no longer `(office, department, original effective date)`. It is
> `(office, department, sub-interval start)`.** Keyed on the old one, the guarantee does exactly what the
> split exists to prevent.

### Correct output

```sql
-- lines 76-77: emit the split interval, not the original
stg.SPLIT_ROW_EFFECTIVE_DATETIME  AS ROW_EFFECTIVE_DATETIME,
stg.SPLIT_ROW_EXPIRATION_DATETIME AS ROW_EXPIRATION_DATETIME,

-- line 134: match the target on the split date
AND stg.SPLIT_ROW_EFFECTIVE_DATETIME = tgt.ROW_EFFECTIVE_DATETIME

-- line 137: key the uniqueness guarantee on the split date
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY stg.OFFICE_NUMBER, stg.DEPARTMENT_NUMBER, stg.SPLIT_ROW_EFFECTIVE_DATETIME
    ORDER BY stg.SPLIT_ROW_EXPIRATION_DATETIME DESC NULLS LAST) = 1;
```

**And `CURRENT_RECORD_INDICATOR` must be recomputed** from `SPLIT_ROW_EXPIRATION_DATETIME`. It currently
comes through from Q1, derived from the unsplit expiry, so after the fix every sub-interval would claim
`'Y'`:

```sql
CAST(CASE WHEN stg.SPLIT_ROW_EXPIRATION_DATETIME >= TIMESTAMP '9999-12-31 00:00:00'
          THEN 'Y' ELSE 'N' END AS VARCHAR(1))     AS CURRENT_RECORD_INDICATOR,
```

With those four references changed, the output becomes:

```
('O001','D001', 2024-01-01, 2024-05-01, 501)
('O001','D001', 2024-05-01, 9999-12-31, 502)
```

### The rule

**When a stage derives a corrected value, the original must not remain reachable under its own name.** Two
ways to enforce it, and the first is stronger:

1. In `fk_split_stg`, do not use `SELECT s.*`. Project the columns explicitly and emit the split interval
   **as** `ROW_EFFECTIVE_DATETIME` / `ROW_EXPIRATION_DATETIME`, so the original is simply not available
   downstream and no later stage can pick the wrong one.
2. If both must coexist, every downstream reference to a date — output, join, `PARTITION BY`, `ORDER BY` —
   is reviewed as a unit, because they must all move together.

**A uniqueness guarantee is keyed on the grain its own stage produces, never the grain it inherited.**

---

## OD11 — the hash now includes the row dates, and it blocks OD10's fix

**Severity: high. Harmless for the historical load in isolation; it makes the OD10 fix incomplete.**

### Trigger
A change-detection hash whose terms include any column the versioning logic decides about — effective date,
expiration date, or anything derived from them.

### What was generated

```sql
COALESCE(TO_VARCHAR(f.ROW_EFFECTIVE_DATETIME,  'YYYY-MM-DD HH24:MI:SS.FF3'), '~NULL~') || CHR(31) ||
COALESCE(TO_VARCHAR(f.ROW_EXPIRATION_DATETIME, 'YYYY-MM-DD HH24:MI:SS.FF3'), '~NULL~') || CHR(31) ||
COALESCE(CAST(f.CURRENT_RECORD_INDICATOR AS VARCHAR), '~NULL~') || CHR(31) ||
COALESCE(CAST(f.DELETE_INDICATOR AS VARCHAR), '~NULL~')
```

The previous generation excluded both dates. This is a regression, and it is a regression against a stated
requirement: the incremental rule table needs a hash over **target-bound attributes only**, so it can tell
*"same values, different expiry"* from *"different values"*. With the dates inside, every interval split
reads as a value change.

`CURRENT_RECORD_INDICATOR` is doubly redundant — it is a pure function of `ROW_EXPIRATION_DATETIME`, which
is already a term.

### Why it blocks OD10

`AUDIT_CHANGE_HASH` is built in **Q1, before the split exists**. So once OD10 is fixed, two sub-intervals of
the same staging row carry **the same hash** — computed over the same unsplit dates — despite being
different rows, over different periods, with different foreign keys. Change detection cannot tell them
apart, and the `DD_CHANGE_FLAG` logic in Q2 compares exactly that hash.

**Fixing OD10 alone leaves the output half-broken. The two must ship together.**

### Correct output

Remove the three date-derived terms:

```sql
MD5( COALESCE(CAST(f.OFFICE_NUMBER AS VARCHAR), '~NULL~') || CHR(31) ||
     …                                                                      -- business attributes only
     COALESCE(CAST(f.DELETE_INDICATOR AS VARCHAR), '~NULL~') )
```

If the dates must stay in the hash for some other reason, the hash has to be **recomputed in Q2 after the
split**, not carried from Q1. Removing them is simpler and is what the incremental design needs.

### The rule

**A change-detection hash answers "did the attributes change?". The dates are what the versioning logic
decides about, so including them makes the answer circular.** Hash the business attributes and the delete
indicator; never the effective date, the expiration date, the current-record indicator, or the surrogate
key.

---

## OD12 — the audit identifiers regressed to a clock reading

**Severity: medium. The load becomes untraceable.**

### What was generated

```sql
CAST(TO_NUMBER(TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS')) AS NUMBER(38,0)) AS AUDIT_BATCH_ID,
CAST(TO_NUMBER(TO_VARCHAR(CURRENT_SESSION()))                      AS NUMBER(38,0)) AS AUDIT_JOB_ID,
```

The previous generation used `$AUDIT_BATCH_ID` / `$AUDIT_JOB_ID`.

### Why it is wrong

The **type** is now right — `NUMBER(38,0)` matching the STTM's `BIGINT`, which the earlier `VARCHAR(255)`
form did not. The **value** went backwards. A batch id invented from the clock cannot be joined to the
orchestration framework's control tables, which is the only reason the column exists. Two runs in the same
second collide; a restart gets a different id from the run it is restarting.

### Correct output

Keep the corrected type, restore the framework source:

```sql
CAST($AUDIT_BATCH_ID AS NUMBER(38,0))       AS AUDIT_BATCH_ID,
CAST($AUDIT_JOB_ID   AS NUMBER(38,0))       AS AUDIT_JOB_ID,
```

Where the parameters are not available, **halt** — do not substitute a clock reading.

---

## OD13 — a NULL interval date silently deletes the row

**Severity: medium. Unreported row loss.**

### Trigger
Any containment or overlap predicate over columns that are not provably `NOT NULL`.

### What was generated

Round 1's `fk_bounds` ended with `WHERE b IS NOT NULL`. That filter is gone, and nothing replaced it. The
containment join reads:

```sql
AND s.ROW_EFFECTIVE_DATETIME  <= fi.ROW_EFFECTIVE_DATETIME
AND s.ROW_EXPIRATION_DATETIME >  fi.ROW_EFFECTIVE_DATETIME
```

### Why it is wrong

If a staging row has a NULL expiry, the second predicate evaluates to NULL rather than true, and the row is
**dropped from the output entirely**. Executed:

```
staging rows: 1 (expiry NULL)   rows surviving the split: 0
```

Q1's checks do not catch it either. Check 4 tests `ROW_EXPIRATION_DATETIME <= ROW_EFFECTIVE_DATETIME`, which
is NULL — not true — for a NULL expiry, and check 6 counts only rows at the high end date. **Both are
NULL-blind.** Q1 casts `od.ROW_EXP_DTE` straight through with no `COALESCE`, so a NULL in the source reaches
staging unchallenged.

### Correct output

Guard it in Q1, where it can still be reported against the business key:

```sql
SELECT 'NULL_INTERVAL_DATE' AS CHECK_NAME, COUNT(*) AS FAILURES
FROM GRS_DIAI_GLOBAL_EMPLOYEE_DATA_DOMAIN_CURATED_DB.EMPLOYEE_MAIN_T.OFFICE_DEPARTMENT_STG
WHERE ROW_EFFECTIVE_DATETIME IS NULL OR ROW_EXPIRATION_DATETIME IS NULL;
```

### The rule

**A three-valued predicate drops rows silently; a check written with `<=` or `>` will not notice.** Where a
join or filter compares interval dates, assert they are non-NULL first, as a separate check that names the
columns — do not rely on the interval checks, which cannot see a NULL.

---

## Still open from round 1

| | Finding | Why it matters more now |
|---|---|---|
| **OD2** | No assertions on the post-split output | **OD10 is exactly the defect a post-split row-count check catches on the first run.** Every check in this pipeline still runs against the pre-split staging table |
| **OD3** | No FK-resolution check; both lookups are `LEFT JOIN` | An association row is nothing but its two foreign keys, and an unresolved one still lands as NULL, uncounted |

The single check that would have caught OD10:

```sql
-- The number of rows leaving the final SELECT must equal the number of split intervals.
SELECT 'SPLIT_ROWS_DROPPED' AS CHECK_NAME,
       (SELECT COUNT(*) FROM fk_split_stg) - (SELECT COUNT(*) FROM <final select>) AS FAILURES;
```

Check 9 (`DEGENERATE_KEY`) also disappeared this round. Minor, since check 1 now runs pre-dedup.

### Shape change, not a defect

Q2 is now an IDMC-style `SELECT` emitting `DD_CHANGE_FLAG` (`0` insert, `1` update, `3` reject) with
`COALESCE(tgt.OFFICE_DEPARTMENT_ID, …SEQ.NEXTVAL)`, rather than `INSERT … SELECT`. On an empty target every
row is `0`, so it is correct for the historical load and matches the house convention. **The flag-`1` path
is update-in-place**, which will overwrite history on the first incremental run — out of scope here, worth
carrying forward.

---

## Fix list, in order

| | Fix | Size |
|---|---|---|
| 1 | **OD10** — emit `SPLIT_` dates; key the `QUALIFY` and the `tgt` join on them; recompute `CURRENT_RECORD_INDICATOR` | 4 references + 1 expression |
| 2 | **OD11** — remove the three date-derived terms from the hash. **Ship with fix 1** | delete 3 lines |
| 3 | **OD13** — add the `NULL_INTERVAL_DATE` check to Q1 | 1 check |
| 4 | **OD12** — restore `$AUDIT_BATCH_ID` / `$AUDIT_JOB_ID`, keeping the `NUMBER(38,0)` cast | 2 lines |
| 5 | **OD2** — assert the post-split output: row count, duplicate key, overlap, open-ended | small |
| 6 | **OD3** — FK-resolution checks, and declare the load dependency on `OFFICE` / `DEPARTMENT` | 2 checks + a comment |

> **Fixes 1 and 2 are one change, not two.** Fixing OD10 alone produces two correct rows that change
> detection then treats as one.

---

## Verification

`../tools/verify/verify_office_department_fix_review.py` reproduces every executed claim in this file:

| Claim | Finding |
|---|---|
| `fk_split_stg` produces the correct sub-intervals, carrying the unsplit dates alongside | OD10 |
| The generated final `SELECT` returns one row with the unsplit interval and an arbitrary FK | **OD10** |
| The same query with the `SPLIT_` dates used returns two correct rows | OD10 fix |
| A NULL expiry in staging drops the row and no Q1 check reports it | OD13 |

```
python3 ../tools/verify/verify_office_department_fix_review.py
```

Re-run it if any example here changes.
