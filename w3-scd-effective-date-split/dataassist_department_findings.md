# ADW HR historical loads — review findings and the rules they give

Covers two generated assets from the ADW HR source:

| Table | Source | Findings | Section |
|---|---|---|---|
| `DEPARTMENT` | `HR_DEPT_T` | **D1 – D7** | below |
| `JOB` | `HR_JOB_T` | **J1 – J7** | [§ JOB](#job-hr-historical-load) |

Both reviewed against their own STTM and their own generated
`<TABLE>_Q1_SRC_TO_STG.sql` / `<TABLE>_Q2_STG_TO_TGT.sql`. Each finding is written as a **rule with a
trigger**, so it applies to the next table, with the defect as the evidence that the rule is needed.

This file covers the ADW HR assets only. It draws no comparison with tables from other sources.

> ### Read this first: the two tables share one STTM template, and therefore one set of defects
>
> `JOB` reproduces **six of `DEPARTMENT`'s seven findings exactly** — same conditional taking the wrong
> branch, same NULL indicator, same three tautological checks, same missing truncate, same re-read audit
> parameters, same hash separator. The `src_sys_nme` / `src_sys_nm` one-character inconsistency appears
> **identically in both STTMs**, which makes it templated rather than a typo on one row.
>
> **Treat D1 – D7 as defects of the HR mapping template, not of `DEPARTMENT`.** Fix them once, at the
> template and in the generator, and every HR table generated afterwards is clean. Fixing them table by
> table will not converge.
>
> **`JOB` has one finding of its own — J1 — and it is the most dangerous on either table**, because it
> produces a load that passes all eight self-checks while silently dropping rows.

---

## `DEPARTMENT` (HR) historical load

Source `HR_DEPT_T`, target
`GRS_DIAI_GLOBAL_EMPLOYEE_DATA_DOMAIN_CURATED_DB.EMPLOYEE_MAIN_T.DEPARTMENT`.

## Verdict

| | |
|---|---|
| Column mappings | **19 of 21 correct** |
| Structure | **Correct** — classification, dedup, derived indicator, date-free hash, insert-only load |
| Self-checks | **5 of 8 can actually fail**; 3 are tautologies |
| Safe to run | **No** — on D1 and D2 |

### What is right, and should not be disturbed

- **The table is correctly classified as a single-history-source load.** `HR_DEPT_T` carries its own
  `ROW_EFF_DTE` / `ROW_EXP_DTE`, so no interval derivation is needed and none was generated. The STTM says
  *"Direct pull for History Load"* on both, and both are pulled directly.
- **`CURRENT_RECORD_INDICATOR` is derived, not stored** —
  `CASE WHEN ROW_EXPIRATION_DATETIME >= '9999-12-31' THEN 'Y' ELSE 'N' END`.
- **`AUDIT_CHANGE_HASH` excludes `ROW_EFFECTIVE_DATETIME` and `ROW_EXPIRATION_DATETIME`**, and excludes the
  surrogate key. It covers the nine business attributes. This is what lets a later incremental load tell
  *"same values, different expiry"* from *"different values"*.
- **Q2 is `INSERT … SELECT`, not a merge.** On an empty target that is exactly right — no change detection,
  no update path, no skip path. `DEPARTMENT_SEQ.NEXTVAL` in an `INSERT … SELECT` is valid Snowflake.
- **Audit identifiers come from framework parameters** (`$AUDIT_BATCH_ID`, `$AUDIT_JOB_ID`), not from the
  clock.
- **Datatypes match the STTM exactly.** `CHAR(5)` / `CHAR(1)` generated as `VARCHAR(5)` / `VARCHAR(1)` is a
  non-issue: Snowflake treats `CHAR(n)` as `VARCHAR(n)` and does not pad.

### The pattern in what is wrong

> **The generated SQL is correct wherever the STTM was explicit, and wrong wherever it was ambiguous — and
> the self-checks cannot tell the difference.**

Both column defects sit on rows where the STTM left something to interpretation: a conditional naming a
column that does not quite match the column-name cell, and a bare `Audit Field` on a column that needs a
value. In both cases a default was chosen silently. Meanwhile three of the eight checks restate what the
query just computed, so they report zero no matter what the data holds.

---

## D1 — A load-type conditional must resolve to the branch matching the file being generated

**Severity: high. Blocks the run.**

### Trigger
The `Transformation` text names more than one behaviour, selected by load type — *"for History … else …
for incremental"*, *"historical load uses X, incremental uses Y"*, or any similar branch.

### What the STTM asks

> Row 7, `Source_System_Name`: **`for History use src_sys_nm else hardcoded as 'EMPLOYEE' for incremental`**

### What was generated

```sql
CAST('EMPLOYEE' AS VARCHAR(30))             AS SOURCE_SYSTEM_NAME,
```

### Why it is wrong

This is the **historical** load. The file is `DEPARTMENT_Q1_SRC_TO_STG.sql` under `HR - Historical`, and the
query's own lineage column says so:

```sql
CAST(OBJECT_CONSTRUCT('SOURCE_TABLE', f.SOURCE_TABLE_NAME,
                      'LOAD_TYPE', 'HISTORICAL') AS VARIANT) AS AUDIT_ZONE_1_LINEAGE_ID,
```

The incremental branch was taken in a file that declares itself historical. Every historical row will record
`EMPLOYEE` as its source system, discarding what `HR_DEPT_T` actually holds — and the column exists
precisely because that value varies across history.

The error also propagates: `SOURCE_SYSTEM_NAME` is the sixth term of `AUDIT_CHANGE_HASH`, so every
historical row's change hash is computed over the wrong value.

### Probable cause, and why it matters more than the typo

The STTM row disagrees with itself by one character:

| Cell | Value |
|---|---|
| `Current State Column` | **`src_sys_nme`** |
| `Transformation` prose | **`src_sys_nm`** |

If the prose identifier could not be resolved, falling through to the other branch produces exactly this
output. **That fallback is the defect, not the typo.** An unresolvable identifier inside a conditional is
more dangerous than one in a plain expression: dropping a function leaves a visibly thin expression, while
picking the wrong branch produces something that reads as entirely deliberate.

### Correct output

```sql
CAST(hd.SRC_SYS_NME AS VARCHAR(30))         AS SOURCE_SYSTEM_NAME,
```

### The rule

1. Determine the load type being generated **once**, from the output target, and record it:
   `-- LOAD_TYPE: HISTORICAL`.
2. For every branching transformation, select the branch matching that load type, and **comment which
   branch was taken and why**:
   `-- STTM row 7: HISTORICAL branch -> hd.SRC_SYS_NME (incremental branch would hardcode 'EMPLOYEE')`
3. If the chosen branch names an identifier that does not resolve against the source DDL, **halt**. Never
   fall through to the other branch, and never substitute the literal from a branch that was not selected.

```
-- GENERATION HALTED
-- STTM row 7, column SOURCE_SYSTEM_NAME
-- Load type HISTORICAL selects the branch "use src_sys_nm".
-- Unresolved identifier: HR_DEPT_T.SRC_SYS_NM
-- Nearest match in the DDL: SRC_SYS_NME. The STTM's Current State Column cell reads 'src_sys_nme'.
-- Required: a human must reconcile the STTM. No SQL emitted for this table.
```

### Verify after the fix

```sql
-- The historical load must not collapse the source system to one value.
SELECT 'SOURCE_SYSTEM_COLLAPSED' AS CHECK_NAME,
       CASE WHEN COUNT(DISTINCT SOURCE_SYSTEM_NAME)
                 < (SELECT COUNT(DISTINCT SRC_SYS_NME) FROM <source>) THEN 1 ELSE 0 END AS FAILURES
FROM DEPARTMENT_STG;
```

---

## D2 — An indicator column whose transformation is bare `Audit Field` needs a derivation, never NULL

**Severity: high. May block the run outright.**

### Trigger
A target column whose `Transformation` is only `Audit Field`, and whose name ends in `_INDICATOR` or
`_FLAG`.

### What the STTM asks

> Row 17, `Delete_Indicator`, `CHAR(1)`, Transformation `Audit Field`
> Comment: *"Logical-delete flag whether the business record is considered deleted or inactive."*

### What was generated

```sql
CAST(NULL AS VARCHAR(1))                    AS DELETE_INDICATOR,
```

### Why it is wrong

A row being loaded by a historical load is, by definition, not deleted. The correct value is `'N'`. NULL
carries two further costs:

1. **It may fail the insert.** If `DEPARTMENT.DELETE_INDICATOR` is declared `NOT NULL` — which the column's
   role suggests — Q2 fails on the first row.
2. **It churns the hash.** `DELETE_INDICATOR` is the last term of `AUDIT_CHANGE_HASH`:

   ```sql
   COALESCE(CAST(f.DELETE_INDICATOR AS VARCHAR), '')
   ```

   Historical rows therefore hash with an empty string. The first incremental run, writing `'N'`, produces
   a different hash for **every unchanged row**, so each one is treated as changed and gets a spurious new
   version on day 2. Executed:

   ```
   historical row, DELETE_INDICATOR NULL -> ac1d99cb942c301abd72e5135c9d8cf7
   same row next run, DELETE_INDICATOR 'N' -> ad7479f71e08be33067963d6f4b71839
   DIFFER
   ```

### The inconsistency that identifies the gap

`Current_Record_Indicator` (row 16) carries the **same** bare `Audit Field` transformation, and was
generated correctly as a derived expression. So the generator has a rule for one indicator column and no
rule for the other, and defaulted to NULL rather than halting.

### Correct output

```sql
CAST('N' AS VARCHAR(1))                     AS DELETE_INDICATOR,
```

### The rule

`Audit Field` is not a value. For every column it marks, the generator needs a named rule:

| Column pattern | Historical load |
|---|---|
| `ROW_CREATE_DATETIME`, `ROW_UPDATE_DATETIME` | `CURRENT_TIMESTAMP()` |
| `ROW_CREATED_BY_USERID`, `ROW_UPDATED_BY_USERID` | `CURRENT_USER()` |
| `CURRENT_RECORD_INDICATOR` | derived from the expiry date |
| `DELETE_INDICATOR` | `'N'` — nothing loaded by a historical load is deleted |
| `AUDIT_BATCH_ID`, `AUDIT_JOB_ID` | framework parameters |
| `AUDIT_CHANGE_HASH` | MD5 over the business attributes, excluding the row dates |
| `AUDIT_ZONE_1_LINEAGE_ID` | `OBJECT_CONSTRUCT` of the identifying source attributes |

**Any `Audit Field` column not on this list halts generation.** Never emit NULL for a column the STTM
describes as a flag or indicator.

---

## D3 — A self-check must be able to fail

**Severity: high. It is false assurance, which is worse than no check.**

### Trigger
The predicate of a self-check restates an expression, a literal, or a window function that the same query
has already applied.

### What was generated

Eight checks, numbered 1, 2, 3, 4, 5, 6, 8, 9. **Three of them cannot report a failure under any data.**

Tested by seeding `HR_DEPT_T` with a deliberately corrupt chain — department `00123` with two rows sharing
an effective date, plus a third overlapping one — and running the checks verbatim:

```
reports 0   1 DUPLICATE_KEY_EFF      = 0      <- on a source that genuinely HAS a duplicate
reports 0   2 CURRENT_IND_MISMATCH   = 0
FIRES       3 OVERLAPPING_INTERVALS  = 1
reports 0   4 BAD_INTERVAL           = 0
reports 0   5 NULL_BUSINESS_KEY      = 0
FIRES       6 OPEN_ENDED_COUNT       = 1
reports 0   8 NON_INSERT_FLAG        = 0
```

| Check | Why it cannot fire |
|---|---|
| **1** `DUPLICATE_KEY_EFF` | `final_deduped` is `WHERE final_dedup_rn = 1` over a `ROW_NUMBER()` partitioned by **exactly** `(DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME)` — the dedup guarantees the property the check tests |
| **2** `CURRENT_IND_MISMATCH` | compares `CURRENT_RECORD_INDICATOR` against the expression that produced it, two CTEs earlier |
| **8** `NON_INSERT_FLAG` | `CHANGE_FLAG` is the literal `0` in the final `SELECT` list |

### Why check 1 is the costly one

The dedup is precisely the mechanism that **hides a corrupt source chain**, and the check meant to detect
that corruption runs downstream of it. The same check pointed at the source finds the duplicate at once:

```
same check run against HR_DEPT_T instead of DEPARTMENT_STG: 1
```

Here that duplicate carried a different `DEPARTMENT_NAME` and a different source system. The dedup kept one
arbitrarily, by `ROW_EXPIRATION_DATETIME DESC`, and nothing reported it.

### Correct output

**Move check 1 upstream of the dedup, where the property is not guaranteed:**

```sql
-- 1. The source must not hold two versions of a key on the same effective date.
--    Runs against the SOURCE: downstream of the dedup this condition is guaranteed and cannot fail.
SELECT 'SOURCE_DUPLICATE_KEY_EFF' AS CHECK_NAME, COUNT(*) AS FAILURES FROM (
  SELECT DEPT_NUM, ROW_EFF_DTE
  FROM GRS_DIAI_HISTORY_RAW_DB.LEGACY_NA_MM_CM_ADW_HR_T_D.HR_DEPT_T
  GROUP BY 1, 2 HAVING COUNT(*) > 1);

-- 1b. Nothing was lost to de-duplication.
SELECT 'DEDUP_DISCARDED_ROWS' AS CHECK_NAME,
       (SELECT COUNT(*) FROM GRS_DIAI_HISTORY_RAW_DB.LEGACY_NA_MM_CM_ADW_HR_T_D.HR_DEPT_T)
     - (SELECT COUNT(*) FROM DEPARTMENT_STG) AS FAILURES;
```

Checks 2 and 8 should be dropped, or kept only with a comment stating they guard the staging table against
modification between Q1 and the check — which is their only remaining value.

Checks **3, 4, 5, 6 and 9 are sound** and were left as they are. Check 9 (`DEGENERATE_KEY`) is the right
shape: it tests a property of the data, not of the query.

### The rule

Before emitting a check, ask: **what data would make this fail?** If the answer is "none, because this
query already guarantees it", the check belongs somewhere else — usually against the source, before the
step that enforces the property. A check that restates the query is a tautology, and a green tautology
reads exactly like a passing test.

---

## D4 — A truncate-and-reload load must contain the truncate

**Severity: medium.**

### Trigger
Any historical load. The load is defined as truncate-and-reload against an empty target.

### What was generated

```sql
INSERT INTO GRS_DIAI_GLOBAL_EMPLOYEE_DATA_DOMAIN_CURATED_DB.EMPLOYEE_MAIN_T.DEPARTMENT ( … )
SELECT … FROM ( … ) src;
```

No `TRUNCATE`, no guard that the target is empty. Executed twice:

```
after run 1: 1 row(s) in target
after run 2: 2 row(s) in target
```

### Why it is wrong

A historical load is not restartable against a partially filled target. A re-run after a partial failure —
the most likely reason anyone re-runs it — silently doubles the table. Nothing in the script or the checks
would report it.

### Correct output

Either the truncate, or an explicit pre-condition:

```sql
TRUNCATE TABLE GRS_DIAI_GLOBAL_EMPLOYEE_DATA_DOMAIN_CURATED_DB.EMPLOYEE_MAIN_T.DEPARTMENT;
```

or, when the orchestration framework owns it:

```sql
-- PRE-CONDITION: the framework truncates DEPARTMENT before this step. This load is not
-- restartable against a partially filled target.
SELECT 'TARGET_NOT_EMPTY' AS CHECK_NAME, COUNT(*) AS FAILURES
FROM GRS_DIAI_GLOBAL_EMPLOYEE_DATA_DOMAIN_CURATED_DB.EMPLOYEE_MAIN_T.DEPARTMENT;
```

Also worth adding, since nothing currently validates the target after Q2:

```sql
SELECT 'ROWCOUNT_MISMATCH' AS CHECK_NAME,
       (SELECT COUNT(*) FROM DEPARTMENT_STG) - (SELECT COUNT(*) FROM …DEPARTMENT) AS FAILURES;
```

---

## D5 — Audit identifiers stamped in Q1 must be carried by Q2, not re-read

**Severity: medium. Breaks lineage at the join you would use to trace a load.**

### Trigger
Any column Q1 writes into staging from a framework parameter.

### What was generated

Q1:

```sql
CAST($AUDIT_BATCH_ID AS NUMBER(38,0))       AS AUDIT_BATCH_ID,
CAST($AUDIT_JOB_ID AS NUMBER(38,0))         AS AUDIT_JOB_ID,
```

Q2, reading from that same staging table:

```sql
CAST($AUDIT_BATCH_ID AS NUMBER(38,0))       AS AUDIT_BATCH_ID,
CAST($AUDIT_JOB_ID AS NUMBER(38,0))         AS AUDIT_JOB_ID,
```

### Why it is wrong

Q1 and Q2 are separate files, run as separate steps — that is the point of splitting them. If they run
under different batch or job ids, the target's `AUDIT_BATCH_ID` is the id of the step that *moved* the rows,
not the one that *produced* them, and the staging and target rows no longer join on it. Tracing a load back
to its extract is the one thing these columns exist for.

### Correct output

```sql
stg.AUDIT_BATCH_ID,
stg.AUDIT_JOB_ID,
```

### The same shape, lower stakes

Q2 also overwrites `ROW_CREATE_DATETIME` and `ROW_UPDATE_DATETIME` with a fresh `CURRENT_TIMESTAMP()`
rather than carrying staging's values, so both record when Q2 ran rather than when the data was extracted.
Carry `stg.ROW_CREATE_DATETIME` / `stg.ROW_UPDATE_DATETIME`.

### The rule

Q2 re-derives nothing that Q1 already wrote. A value computed in two places will eventually differ in two
places. Carry it.

---

## D6 — A change-detection hash needs a separator that cannot occur in the data

**Severity: low, but the class is eliminable.**

### What was generated

```sql
MD5( COALESCE(CAST(f.DEPARTMENT_NUMBER AS VARCHAR), '') || '|' ||
     COALESCE(CAST(f.DEPARTMENT_NAME   AS VARCHAR), '') || '|' || … )
```

### Why it is wrong

Two defects of the same kind:

- **`|` can appear in the data.** A department named `A|B` with short name `C` produces the same
  concatenation as one named `A` with short name `B|C`, so a real change goes undetected.
- **`COALESCE(…, '')` makes NULL and the empty string identical.** A value changing from NULL to `''` does
  not move the hash.

### Correct output

Use a separator that cannot appear, and a distinct NULL marker:

```sql
MD5( COALESCE(CAST(f.DEPARTMENT_NUMBER AS VARCHAR), '~NULL~') || CHR(31) ||
     COALESCE(CAST(f.DEPARTMENT_NAME   AS VARCHAR), '~NULL~') || CHR(31) || … )
```

`CHR(31)` is the ASCII unit separator and does not occur in business text. Alternatively use
`HASH_AGG`-style length prefixing. **Whichever is chosen must stay fixed**, because changing the hash
definition later re-versions every row in the table.

---

## D7 — Lineage must carry every identifying attribute the row has

**Severity: low.**

### What was generated

```sql
CAST(OBJECT_CONSTRUCT('SOURCE_TABLE', f.SOURCE_TABLE_NAME,
                      'LOAD_TYPE', 'HISTORICAL') AS VARIANT) AS AUDIT_ZONE_1_LINEAGE_ID,
```

### Why it is thin

This table has a real source-system column. Lineage that names the table but not the system cannot answer
*"which system did this row come from?"* — the question the column exists for — without joining back to
the row's own attributes.

### Correct output

```sql
CAST(OBJECT_CONSTRUCT('SOURCE_TABLE',  f.SOURCE_TABLE_NAME,
                      'SOURCE_SYSTEM', f.SOURCE_SYSTEM_NAME,
                      'LOAD_TYPE',     'HISTORICAL') AS VARIANT) AS AUDIT_ZONE_1_LINEAGE_ID,
```

This depends on **D1** being fixed first — until then the value would be the constant `'EMPLOYEE'`.

---

## `DEPARTMENT` — open, needs a DDL before it can be closed

| | What is needed | What it decides |
|---|---|---|
| D1 | `HR_DEPT_T` DDL | Whether the column is `SRC_SYS_NME` or `SRC_SYS_NM`, and so whether the STTM's prose or its column-name cell is wrong |
| D2 | `DEPARTMENT` target DDL | Whether `DELETE_INDICATOR` is `NOT NULL`, and so whether the current output fails the insert or merely stores a wrong value |

---

## `DEPARTMENT` — for the data modeller: the business key may be incomplete

The STTM flags **only `Department_Number`** as a natural key, and the dedup partitions on
`(DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME)` alone.

But row 7 asks history to carry `src_sys_nme`, which implies **more than one system feeds this table**. If
two systems supply the same `dept_num` on the same effective date, the dedup keeps one arbitrarily and
discards the other. Demonstrated:

```
two source systems supply department 00123 on the same effective date:
  ('00123', 'PAYROLL',  'Claims Dept',   2024-01-01, 9999-12-31)
  ('00123', 'BENEFITS', 'Claims Dept B', 2024-01-01, 9999-12-31)
rows surviving dedup: 1 -> [('00123', 'PAYROLL', 'Claims Dept')]
```

**If `src_sys_nme` genuinely varies, the business key is `(DEPARTMENT_NUMBER, SOURCE_SYSTEM_NAME)`** and
the dedup, the self-checks and any later merge key all need it. This cannot be observed until D1 is fixed,
because today every row carries the constant `'EMPLOYEE'`.

---

## `DEPARTMENT` — fix list, in order

| | Fix | Size |
|---|---|---|
| 1 | **D1** — `SOURCE_SYSTEM_NAME` → `hd.SRC_SYS_NME` | one line |
| 2 | **D2** — `DELETE_INDICATOR` → `'N'` | one line |
| 3 | **D3** — move check 1 to the source, add the dedup-loss check, drop checks 2 and 8 | small |
| 4 | **D4** — truncate, or document the framework's and add the target-empty check | one line |
| 5 | **D5** — carry `stg.AUDIT_BATCH_ID`, `stg.AUDIT_JOB_ID`, `stg.ROW_CREATE_DATETIME`, `stg.ROW_UPDATE_DATETIME` in Q2 | four lines |
| 6 | **D7** — add `SOURCE_SYSTEM` to the lineage object | one line |
| 7 | **D6** — hash separator, if the hash is being changed before first load | one line, do it now or never |

> D6 last on purpose: changing a hash definition after the first load re-versions every row. Fix it before
> the historical load runs, or leave it alone permanently.

---

---
---

# `JOB` (HR) historical load

Source `HR_JOB_T`, target `GRS_DIAI_GLOBAL_EMPLOYEE_DATA_DOMAIN_CURATED_DB.EMPLOYEE_MAIN_T.JOB`.
Reviewed against the `JOB` STTM and the generated `JOB_Q1_SRC_TO_STG.sql` / `JOB_Q2_STG_TO_TGT.sql`.

## Verdict

| | |
|---|---|
| Column mappings | **23 of 25 correct** |
| Structure | **Correct** |
| Self-checks | **8 emitted; 3 are tautologies, and none caught the worst case** |
| Safe to run | **No** |

### What is right, and should not be disturbed

- **Correctly classified as a single history source.** `HR_JOB_T` carries its own `ROW_EFF_DTE` /
  `ROW_EXP_DTE`, so no interval derivation was generated and none is needed.
- **`CURRENT_RECORD_INDICATOR` derived from the expiry**, not stored.
- **`AUDIT_CHANGE_HASH` over 13 business attributes**, excluding both row dates and the surrogate key.
- **Audit identifiers from framework parameters** in Q1.
- **Q2 is `INSERT … SELECT` with `JOB_SEQ.NEXTVAL`** — the right shape for an empty target. Its 25-column
  insert list and its select list match exactly in count and order; checked position by position.

---

## J1 — the business key is probably `(JOB_CODE, HR_BUSINESS_GROUP_CODE)`, not `JOB_CODE` alone

**Severity: highest on either table. It produces a load that passes every check while losing rows.**

This is `JOB`'s own finding. It has no counterpart in `DEPARTMENT`.

### Trigger

The STTM flags a single natural-key column, **and** the same table carries another column that names a
scope, owner, group, company or region. Treat the key as suspect until proved otherwise: a code that
identifies a thing *within* an organisational unit is rarely unique across all of them.

### What the STTM says

| | Column | Type | Natural Key |
|---|---|---|---|
| 2 | `Job_Code` | `CHAR(4)` | **Y** |
| 3 | `HR_Business_Group_Code` | `CHAR(10)` | — |

`HR_Business_Group_Code` is described as *"Code identifying the HR business group for the employee."*
A four-character job code being globally unique across every HR business group is an assumption, not a
fact, and nothing in the mapping states it.

### What was generated

```sql
ROW_NUMBER() OVER (
    PARTITION BY JOB_CODE, ROW_EFFECTIVE_DATETIME
    ORDER BY TABLE_PRIORITY ASC, ROW_EXPIRATION_DATETIME DESC
) AS final_dedup_rn
...
final_deduped AS ( SELECT * FROM cross_table_deduped WHERE final_dedup_rn = 1 )
```

### Why it is wrong

If one job code exists in two business groups, the dedup keeps one and discards the other. Executed, with
job `A100` present in `CORP-US` and `SPECIALTY`:

```
source rows 4 -> staging rows 3
   ('A100', 'CORP-US  ', 'Claims Adjuster')
   ('B200', 'CORP-US  ', 'Senior Actuary')
   ('B200', 'CORP-US  ', 'Actuary')
-> the SPECIALTY 'Underwriting Analyst' job is gone
```

**A whole job disappeared.** Then all eight generated self-checks, run verbatim against that staging table:

```
reports 0   1 DUPLICATE_KEY_EFF     = 0
reports 0   2 CURRENT_IND_MISMATCH  = 0
reports 0   3 OVERLAPPING_INTERVALS = 0
reports 0   4 BAD_INTERVAL          = 0
reports 0   5 NULL_BUSINESS_KEY     = 0
reports 0   6 OPEN_ENDED_COUNT      = 0
reports 0   8 NON_INSERT_FLAG       = 0
reports 0   9 DEGENERATE_KEY        = 0
```

**Every check passes. The load reads as completely clean.** Re-keyed on
`(JOB_CODE, HR_BUSINESS_GROUP_CODE, ROW_EFFECTIVE_DATETIME)`, all four source rows survive.

This is what makes J1 worse than J2 and J3: those are visible the moment anyone looks at a row, while J1
produces a table that is simply missing jobs and reports nothing.

### Settle it before generating — one query

```sql
-- Non-zero means JOB_CDE is NOT globally unique, and the historical load will lose rows.
SELECT COUNT(*) AS DUPLICATE_KEY_EFF_IN_SOURCE FROM (
  SELECT JOB_CDE, ROW_EFF_DTE
  FROM GRS_DIAI_HISTORY_RAW_DB.LEGACY_NA_MM_CM_ADW_HR_T_D.HR_JOB_T
  GROUP BY 1, 2 HAVING COUNT(*) > 1);
```

### Correct output, if it comes back non-zero

The key change must be applied in **every** place the key appears — the dedup, every keyed self-check, and
any later incremental merge:

```sql
ROW_NUMBER() OVER (
    PARTITION BY JOB_CODE, HR_BUSINESS_GROUP_CODE, ROW_EFFECTIVE_DATETIME
    ORDER BY TABLE_PRIORITY ASC, ROW_EXPIRATION_DATETIME DESC
) AS final_dedup_rn
```

### The rule

**A business key is a claim about the data, not a field in the STTM.** Before generating, verify it:

1. Run the source-side duplicate query above for the declared key.
2. If it returns zero, record that: `-- BUSINESS KEY: JOB_CODE (verified unique per effective date on <date>)`.
3. If it returns non-zero, **halt**. Do not generate a dedup that resolves the ambiguity by discarding rows.
   Name the candidate scope column in the halt message.
4. Always emit the dedup-loss check below, whatever the key turns out to be.

```sql
-- Nothing may be lost to de-duplication.
SELECT 'DEDUP_DISCARDED_ROWS' AS CHECK_NAME,
       (SELECT COUNT(*) FROM GRS_DIAI_HISTORY_RAW_DB.LEGACY_NA_MM_CM_ADW_HR_T_D.HR_JOB_T)
     - (SELECT COUNT(*) FROM JOB_STG) AS FAILURES;
```

This single check would have caught J1 on its own. **Nothing else did.**

---

## J2 — `SOURCE_SYSTEM_NAME` takes the incremental branch in a historical load

**Severity: high. Blocks the run.** Same defect as **D1** — rule and correct behaviour there.

### JOB's evidence

STTM row 11:

> **`for History use src_sys_nm else hardcoded as 'EMPLOYEE' for incremental`**

Generated:

```sql
CAST('EMPLOYEE' AS VARCHAR(30))             AS SOURCE_SYSTEM_NAME,
```

The file sits under `HR - Historical` and its own lineage declares `'LOAD_TYPE', 'HISTORICAL'`.

### Correct output

```sql
CAST(hj.SRC_SYS_NME AS VARCHAR(30))         AS SOURCE_SYSTEM_NAME,
```

### What `JOB` adds to the rule

The `Current State Column` cell reads **`src_sys_nme`** and the prose reads **`src_sys_nm`** — the same
one-character inconsistency as `DEPARTMENT` row 7, on a different table in a different STTM sheet.

**That makes it templated, not a typo.** Every HR table generated from this mapping template will hardcode
`'EMPLOYEE'` in its historical load. Fix it at the template, not per table — and fix the generator's
fall-through, because the fall-through is what turns a one-character inconsistency into wrong data.

The value also feeds the hash, as its tenth term.

---

## J3 — `DELETE_INDICATOR` is NULL

**Severity: high. May block the run outright.** Same defect as **D2** — rule and correct behaviour there.

### JOB's evidence

STTM row 21, `Delete_Indicator`, `CHAR(1)`, Transformation `Audit Field`. Generated:

```sql
CAST(NULL AS VARCHAR(1))                    AS DELETE_INDICATOR,
```

It is the **thirteenth and last** term of `AUDIT_CHANGE_HASH`:

```
DELETE_INDICATOR NULL -> 24795da7d7bc2afa7e70bb5953ae9304
DELETE_INDICATOR 'N'  -> 36fe425697bd86ea131ac8ecd1ebf034
```

Every unchanged row re-versions on the first incremental run.

`Current_Record_Indicator` (row 20) carries the identical bare `Audit Field` transformation and **was**
derived correctly — the same inconsistency as on `DEPARTMENT`, confirming the generator has a rule for one
indicator column and none for the other.

### Correct output

```sql
CAST('N' AS VARCHAR(1))                     AS DELETE_INDICATOR,
```

---

## J4 — three of the eight checks cannot fail

**Severity: high.** Same defect as **D3** — rule and correct placement there.

### JOB's evidence

| Check | Why it cannot fire on `JOB` |
|---|---|
| **1** `DUPLICATE_KEY_EFF` | groups by `(JOB_CODE, ROW_EFFECTIVE_DATETIME)`, which is **exactly** the partition of the `ROW_NUMBER()` that `final_deduped` filters to 1 |
| **2** `CURRENT_IND_MISMATCH` | compares `CURRENT_RECORD_INDICATOR` against the expression that produced it two CTEs earlier |
| **8** `NON_INSERT_FLAG` | `CHANGE_FLAG` is the literal `0` in the final `SELECT` list |

Checks **3, 4, 5, 6 and 9 are sound**.

**J1 is the proof of why check 1's placement matters.** The de-duplication is the step that destroyed the
row, and the check written to detect duplicates runs downstream of it. Pointed at `HR_JOB_T` instead, the
same check returns `1` immediately:

```
source-side duplicate check on (JOB_CDE, ROW_EFF_DTE): 1
```

---

## J5 — Q2 re-reads `$AUDIT_BATCH_ID` instead of carrying staging's

**Severity: medium.** Same defect as **D5** — rule there.

### JOB's evidence

Q1 writes `$AUDIT_BATCH_ID` / `$AUDIT_JOB_ID` into `JOB_STG`. Q2, reading from that same table, reads the
parameters again:

```sql
CAST($AUDIT_BATCH_ID AS NUMBER(38,0))       AS AUDIT_BATCH_ID,
CAST($AUDIT_JOB_ID AS NUMBER(38,0))         AS AUDIT_JOB_ID,
```

Should be `stg.AUDIT_BATCH_ID` / `stg.AUDIT_JOB_ID`. Q2 also overwrites `ROW_CREATE_DATETIME` and
`ROW_UPDATE_DATETIME` with a fresh `CURRENT_TIMESTAMP()` rather than carrying staging's.

Note that Q2 **does** correctly carry `stg.AUDIT_CHANGE_HASH` and `stg.AUDIT_ZONE_1_LINEAGE_ID` — so the
template already knows how to carry a staging value. Only the parameter-derived columns are re-read.

---

## J6 — no `TRUNCATE` on a truncate-and-reload load

**Severity: medium.** Same defect as **D4** — rule and correct output there.

`JOB_Q2_STG_TO_TGT.sql` is a bare `INSERT … SELECT` into `…EMPLOYEE_MAIN_T.JOB`, with no `TRUNCATE` and no
target-empty guard. A re-run after a partial failure doubles the table and nothing reports it.

---

## J7 — hash separator, and thin lineage

**Severity: low, but the separator is now-or-never.** Same defects as **D6** and **D7**.

### What `JOB` adds

`JOB`'s hash has **13 terms against `DEPARTMENT`'s 9**, and four of them are free-text name fields:

```
JOB_TITLE_NAME, JOB_NAME, JOB_FAMILY_NAME, EEO_OCCUPATIONAL_CATEGORY_NAME
```

Free text is where a literal `|` actually turns up. More terms and more free text means more surface for a
separator collision to mask a real change. The fix is the same — `CHR(31)` and a distinct NULL marker —
and it must land **before the first load**, because changing a hash definition afterwards re-versions every
row in the table.

Lineage is the same shape as `DEPARTMENT`'s and omits the source system:

```sql
CAST(OBJECT_CONSTRUCT('SOURCE_TABLE',  f.SOURCE_TABLE_NAME,
                      'SOURCE_SYSTEM', f.SOURCE_SYSTEM_NAME,
                      'LOAD_TYPE',     'HISTORICAL') AS VARIANT) AS AUDIT_ZONE_1_LINEAGE_ID,
```

Depends on **J2** being fixed first, or the value is the constant `'EMPLOYEE'`.

---

## `JOB` — open, needs an answer before generation

| | What is needed | What it decides |
|---|---|---|
| **J1** | The duplicate query above, run against `HR_JOB_T` | Whether the business key is `JOB_CODE` or `(JOB_CODE, HR_BUSINESS_GROUP_CODE)`. **Non-zero means the current load loses rows silently** |
| J2 | `HR_JOB_T` DDL | Whether the column is `SRC_SYS_NME` or `SRC_SYS_NM` |
| J3 | `JOB` target DDL | Whether `DELETE_INDICATOR` is `NOT NULL`, and so whether the insert fails or merely stores a wrong value |

`SOURCE_SYSTEM_NAME` is a second candidate key component here, as on `DEPARTMENT` — but it cannot be
assessed until J2 is fixed, because today every row carries the constant `'EMPLOYEE'`.

---

## `JOB` — fix list, in order

| | Fix | Size |
|---|---|---|
| 1 | **J1** — run the duplicate query; if non-zero, re-key the dedup and every keyed check | query first, then small |
| 2 | **J2** — `SOURCE_SYSTEM_NAME` → `hj.SRC_SYS_NME`, **and correct the HR STTM template** | one line + template |
| 3 | **J3** — `DELETE_INDICATOR` → `'N'` | one line |
| 4 | **J4** — move check 1 to the source, add the dedup-loss check, drop checks 2 and 8 | small |
| 5 | **J6** — truncate, or document the framework's and add the target-empty check | one line |
| 6 | **J5** — carry `stg.AUDIT_BATCH_ID`, `stg.AUDIT_JOB_ID`, `stg.ROW_CREATE_DATETIME`, `stg.ROW_UPDATE_DATETIME` | four lines |
| 7 | **J7** — hash separator and lineage | one line, now or never |

---

# Verification

`tools/verify_department_findings.py` reproduces every executed claim in this file. It needs `duckdb` only.

| Claim | Where |
|---|---|
| Hash divergence from a NULL delete indicator | **D2**, **J3** |
| Three tautological checks, and a source duplicate hidden by the dedup | **D3**, **J4** |
| Double-insert from a missing truncate | **D4**, **J6** |
| Dedup discarding a second source system | `DEPARTMENT` modeller note |
| **A whole job lost while all eight checks report zero** | **J1** |

```
python3 tools/verify_department_findings.py
```

Re-run it if any example in this file changes.
