# Generation rules for DataAssist — learned from the `THIRD_PARTY_AGREEMENT` review

**Read this before generating Q1 or Q2 for any table.** It is not about `THIRD_PARTY_AGREEMENT`.
Each rule below has a **trigger** that can be evaluated against any STTM and any DDL. The
`THIRD_PARTY_AGREEMENT` case is only the evidence that the rule is needed.

Companion file: `historical_load_instructions.md` says **what to produce**. This file says
**how to behave while producing it**.

---

## The principle these rules come from

> **Every defect found in the `THIRD_PARTY_AGREEMENT` review, except the missing checks, was DataAssist
> producing plausible SQL where it should have stopped and reported that it could not generate.**
>
> It never once said "I cannot do this." It dropped a function it could not parse, dropped a condition it
> could not place, and substituted a join key that did not exist — each time emitting clean,
> runnable, wrong SQL.

**Wrong SQL that runs is the worst possible output.** It is worse than no SQL, because no one looks at it
again. A generation that stops with a reason costs an hour. A generation that silently drops a `COALESCE`
costs a reload and a credibility problem.

So: **when in doubt, fail. Never fall back.**

---

## R1 — An unparsed transformation is a STOP, never a fallback

### Trigger
The `Transformation` text for a column contains anything beyond a bare column reference — a function call,
a conditional, a `where`, a `case` — and you cannot map **all** of it into the generated expression.

### What happened
The STTM asks for a fallback on **12** columns. All 12 were generated as a plain column pull from the
joined table:

| STTM `Transformation` | Generated |
|---|---|
| `coalasce(contract_t.srl_num, contract_number_element_t.srl_num)` | `con2.SRL_NUM` |
| `coalasce(contract_t.nmrl_num, contract_number_element_t.nmrl_num)` | `con2.NMRL_NUM` |
| `coalasce(contract_t.yr_iss_num, contract_number_element_t.yr_iss_num)` | `con2.YR_ISS_NUM` |
| `coalasce(broker_t.brkr_loi_cde, contract_t.brkr_loi_cde)` | `con5.BRKR_LOI_CDE` |
| `coalasce(sales_off_t.slsof_cde, contract_t.slsof_cde)` | `con7.SLSOF_CDE` |
| …and 7 more across `broker_t`, `sales_off_t`, `sales_rep_t` | |

A second instance, 3 more columns — the condition was dropped entirely:

| STTM | Generated |
|---|---|
| `straightpull, where contract_t.alph_sort_one_cde <> name_t.alph_sort_one_cde` | `con6.ALPH_SORT_ONE_CDE` |

### Why it is wrong

**The root cause is a typo the generator should have refused to guess past.** The STTM spells it
`coalasce`, not `coalesce`, in all 12 rows. The parser did not recognise the token, and **fell back to
emitting the first column reference it could find** — which, for the first three rows, is not even the
first argument. `coalasce(contract_t.srl_num, contract_number_element_t.srl_num)` became `con2.SRL_NUM`:
the fallback *and* the precedence are inverted.

This is confirmed data loss, not a harmless no-op. `CONTRACT_T`'s DDL carries `SRL_NUM`, `NMRL_NUM`,
`YR_ISS_NUM`, `BRKR_LOI_CDE`, `RENWL_BRKR_NUM`, `RENWL_BRKR_LOI_CDE`, `SLSOF_CDE`, `SLSOF_TWO_CDE`,
`ORGL_SLSOF_CDE`, `SLSRP_CDE`, `SLSRP_TWO_CDE` and `SLSRP_TWO_PCT` — **every one of the 12 fallbacks refers
to a real column holding real values**, and every one is being discarded.

For the `<>` rows the effect is subtler and just as wrong: a column named *Alternate* is populated even when
it is identical to the one it is an alternative to, which is the opposite of what the mapping asks for.

### Correct output

```sql
-- STTM: coalasce(contract_t.srl_num, contract_number_element_t.srl_num)
COALESCE(drv.SRL_NUM, con2.SRL_NUM) AS SERIAL_NUMBER,

-- STTM: straightpull, where contract_t.alph_sort_one_cde <> name_t.alph_sort_one_cde
CASE WHEN drv.ALPH_SORT_ONE_CDE <> con6.ALPH_SORT_ONE_CDE
     THEN con6.ALPH_SORT_ONE_CDE END AS ALTERNATE_ALPHA_SORT_ONE_CODE,
```

### What to do instead of guessing

1. Normalise obvious misspellings of known SQL functions **only** against a fixed allow-list
   (`coalasce`/`colaesce` → `COALESCE`, `straightpull`/`straight pull` → direct reference). Log every
   normalisation in a comment so a human sees it:
   `-- NORMALISED: 'coalasce' -> COALESCE (STTM row 19)`
2. **Anything not on that list is a STOP.** Do not generate the column, do not generate the file. Emit:
   ```
   -- GENERATION HALTED
   -- STTM row 19, column SERIAL_NUMBER
   -- Unparsed transformation: "coalasce(contract_t.srl_num, contract_number_element_t.srl_num)"
   -- Reason: token 'coalasce' is not a recognised function and is not on the normalisation list.
   -- Required: a human must correct the STTM or extend the list. No SQL emitted for this table.
   ```
3. **Never emit a partial expression.** If only part of a transformation is understood, none of it is.

> **Why halt the whole file rather than just the column?** Because a file with one column quietly wrong is
> indistinguishable from a correct file, and it will be run. A file that does not exist cannot be run.

---

## R2 — Every table and column named in a transformation must resolve against a real DDL

### Trigger
A `Transformation` names any identifier — table or column — on either side of a join predicate.

### What happened
STTM, three columns (`Broker_Original_Source_System_Code`, `Agency_Brokerage_Number`,
`Broker_Update_Source_System_Code`):

> `Left join from contract_t to Broker_t on **prsp_id** = brkr_sjct_area_id where brkr_sjct_area_cde='CONTRACT'`

**`CONTRACT_T` has no column `PRSP_ID`.** Its DDL was checked in full: 74 columns, no `PRSP_ID`, and nothing
resembling it. The generator silently used the `AGR_ID` join alias (`con5`) that already existed for other
broker columns.

### Why it is wrong
The substitution may even produce the rows a reviewer expects, which is what makes it dangerous — it reads
as correct. But the mapping asked for a different relationship, and nobody was told it could not be
satisfied. **The STTM is the defect here; the silent substitution is the defect on the generator's side.**
Both need to surface. Only one did, and only because the SQL was reviewed by hand.

### Correct output

```
-- GENERATION HALTED
-- STTM rows 79-81, columns BROKER_ORIGINAL_SOURCE_SYSTEM_CODE, AGENCY_BROKERAGE_NUMBER,
--                          BROKER_UPDATE_SOURCE_SYSTEM_CODE
-- Unresolved identifier: CONTRACT_T.PRSP_ID
-- CONTRACT_T DDL contains no such column. Nearest candidates: PRODR_CNTC_ID, STKR_ID.
-- Required: data modeller must correct the join predicate. No SQL emitted for this table.
```

### The rule

Before generating one line of SQL, build the identifier set from every `Transformation` and resolve **all**
of it against the actual DDLs. **Any unresolved identifier halts generation.** Never reuse an existing join
alias because it is "close enough" — if the predicate differs, the relationship differs.

---

## R3 — Carry the business key into staging, and key everything on it

### Trigger
Always. Every table has a business key; find it before generating.

### What happened
The STTM marks two columns `Natural Key = Y`: `Agreement_ID` and `Source_System_Code`.

- `Source_System_Code` is **hardcoded `'CCO'`** — a constant, identical on every row.
- `Agreement_ID` is **not resolvable in Q1** — it comes from a lookup performed in Q2, so Q1 emits
  `CAST(NULL AS NUMBER(38,0)) AS AGREEMENT_ID`.

With no usable key in staging, **everything downstream improvised**, in two places.

**(a) Four of the seven emitted self-checks were keyed on the constant.** Run verbatim against a staging
table holding just **two** business keys:

```
FAIL  1 DUPLICATE_KEY_EFF      = 1      (should be 0)
FAIL  3 OVERLAPPING_INTERVALS  = 2      (should be 0)
FAIL  6 OPEN_ENDED_COUNT       = 1      (should be 0)
pass  5 NULL_BUSINESS_KEY      = 0      ('CCO' can never be NULL — this check can never fire)
```

Re-keyed on `(SOURCE_TPA_IDENTIFIER, SOURCE_SYSTEM_CODE)`, all four return 0. On a real table these would
report failures in the millions, and the team would learn to ignore the checks entirely.

**(b) The Q2 `MERGE` was keyed on a resolved foreign-key surrogate:**

```sql
ON  src.SOURCE_SYSTEM_CODE      = tgt.SOURCE_SYSTEM_CODE
AND src.ROW_EFFECTIVE_DATETIME  = tgt.ROW_EFFECTIVE_DATETIME
AND EQUAL_NULL(src.AGREEMENT_ID, tgt.AGREEMENT_ID)
```

`AGREEMENT_ID` is the primary key of the `AGREEMENT` table, which is SCD-2 — so it identifies **a version
row**, and it changes when `AGREEMENT` is reloaded or the agreement gains a version. Executed: with the
target already holding the row at `AGREEMENT_ID = 901`, a reload that renumbers it to `903` makes the
`MERGE` match **0 rows**, `WHEN NOT MATCHED` fires, and the same business row **inserts again as a
duplicate**.

`EQUAL_NULL` makes it worse: on a lookup miss every unmatched row carries `AGREEMENT_ID = NULL`, so all of
them collapse onto `(SOURCE_SYSTEM_CODE, ROW_EFFECTIVE_DATETIME)` alone.

### Why it is wrong
A merge key must be **stable and intrinsic to the row being merged**. A surrogate resolved from another
SCD-2 table is neither. A check key must **vary across rows**, or the check measures nothing.

### Correct output

Identify the business key by this order of preference, and **record the choice in a comment**:

1. The STTM's `Natural Key = Y` columns, **excluding** any that are hardcoded constants or resolved
   downstream of the artefact being keyed.
2. The source column carrying the driving table's own identity — here `SOURCE_TPA_IDENTIFIER`, which is
   `contract_t.agr_id` and is present in staging.
3. If neither yields a varying column, **halt**. Do not key on a constant.

```sql
-- BUSINESS KEY: (SOURCE_TPA_IDENTIFIER, SOURCE_SYSTEM_CODE)
--   Agreement_ID is Natural Key = Y but is NULL in staging (resolved in Q2) -> not usable here.
--   Source_System_Code is Natural Key = Y but is hardcoded 'CCO' -> constant, not usable alone.

-- check 1, correctly keyed
SELECT 'DUPLICATE_KEY_EFF' AS CHECK_NAME, COUNT(*) AS FAILURES FROM (
  SELECT SOURCE_TPA_IDENTIFIER, SOURCE_SYSTEM_CODE, ROW_EFFECTIVE_DATETIME
  FROM THIRD_PARTY_AGREEMENT_STG GROUP BY 1,2,3 HAVING COUNT(*) > 1);

-- the MERGE, correctly keyed
ON  src.SOURCE_TPA_IDENTIFIER  = tgt.SOURCE_TPA_IDENTIFIER
AND src.SOURCE_SYSTEM_CODE     = tgt.SOURCE_SYSTEM_CODE
AND src.ROW_EFFECTIVE_DATETIME = tgt.ROW_EFFECTIVE_DATETIME
```

### Self-check to emit

```sql
-- The business key must actually vary. A key with one distinct value is not a key.
SELECT 'DEGENERATE_BUSINESS_KEY' AS CHECK_NAME,
       CASE WHEN COUNT(DISTINCT <business_key>) <= 1 THEN 1 ELSE 0 END AS FAILURES
FROM <staging>;
```

---

## R4 — Read each contributor's version interval off its DDL, never off its column names

### Trigger
Any table contributing to an effective-date split. You must decide **which pair of columns bounds its
versions** before you can place it in the boundary union.

### What happened — DataAssist got this right, and it matters that it did

`CNTR_CLM_ADMNM_T` was bounded by `CLM_ADMNM_EFF_DTE` / `CLM_ADMNM_EXP_DTE` while every other contributor
was bounded by `ROW_EFF_DM` / `ROW_EXP_DM`. That inconsistency looks like a bug. **It is not.** Its DDL:

```sql
CREATE OR REPLACE ICEBERG TABLE CNTR_CLM_ADMNM_T (
    AGR_ID INT, CLM_ADMNM_CDE STRING,
    CLM_ADMNM_EFF_DTE DATE, CLM_ADMNM_EXP_DTE DATE,
    UDT_USR_ID STRING, UDT_DM TIMESTAMP_NTZ(6), UPDT_SRC_CDE STRING,
    TRNX_ID INT, GRS_REFINED_TIMESTAMP TIMESTAMP_NTZ(6))
```

**There are no `ROW_EFF_DM` / `ROW_EXP_DM` columns.** The table is not SCD-2. Its business dates *are* its
version interval, and they are mapped to target columns 32 and 33, so the target must be cut where they
change. Using them was correct.

### The trap this rule exists for

`CONTRACT_T` carries **two** candidate pairs:

```sql
ROW_EFF_DM     TIMESTAMP_NTZ(6),  ROW_EXP_DM     TIMESTAMP_NTZ(6),
ADW_ROW_EFF_DM TIMESTAMP_NTZ(6),  ADW_ROW_EXP_DM TIMESTAMP_NTZ(6),
```

A classifier matching on `ROW_EFF%` or `%ROW_EFF_DM` hits both. The STTM disambiguates in prose —
*"Use row_eff_dm for historical records"* — and DataAssist chose correctly, but by luck of ordering as much
as by rule. On the next table there may be no prose to lean on.

### The rule

For each contributing table, in this order:

1. If the STTM names the pair explicitly in prose, use it, and **comment the sentence you used**.
2. Else, if the DDL has exactly **one** pair matching `ROW_EFF*`/`ROW_EXP*`, use it.
3. Else, if the DDL has **no** such pair, the table is not SCD-2 — use the business date pair that the STTM
   maps to the target, and **comment why**.
4. Else (**more than one** candidate pair, no prose) — **halt**. Do not pick by ordinal position.

```sql
-- INTERVAL BASIS, per contributor:
--   CONTRACT_T            ROW_EFF_DM / ROW_EXP_DM
--                         (two candidate pairs; STTM row 69: "Use row_eff_dm for historical records";
--                          ADW_ROW_EFF_DM / ADW_ROW_EXP_DM deliberately NOT used)
--   CNTR_CLM_ADMNM_T      CLM_ADMNM_EFF_DTE / CLM_ADMNM_EXP_DTE
--                         (not SCD-2: DDL has no ROW_EFF_DM; business dates are the version interval)
```

---

## R5 — Emit the containment check once per contributing source. It is not optional

### Trigger
Any table classified as needing the effective-date split, for every contributor.

### What happened
The generated assertion block numbers them **1, 2, 3, 4, 5, 6, 8**. **Check 7 — containment — is missing.**

### Why that is the worst one to drop
It is the only check that catches a wrong interval basis or a misclassified table. The others all pass on
wrong data, because the staging de-duplication collapses a join fanout *before* staging is written.

This table is the highest-risk case for exactly that fault: **eight contributors, eight chances to carry a
stale value.** And `CNTR_CLM_ADMNM_T` adds a specific risk the DDL makes visible — it is **not** SCD-2 and
has **no uniqueness guarantee** on `(AGR_ID, CLM_ADMNM_EFF_DTE)`. Two concurrent claim administrators, or
two history-bucket snapshots of the same period, fan the `LEFT JOIN` out and nothing else would report it.

### Correct output — one block per contributor

```sql
-- 7a. CONTAINMENT, contributor CNTR_CLM_ADMNM_T.
--     Across every contributor version overlapping a staging interval, the contributed VALUES
--     must be one single value. Compare values, not versions: a collapsed interval legitimately
--     spans two versions when the value did not change.
SELECT 'CONTAINMENT_VIOLATION_CNTR_CLM_ADMNM_T' AS CHECK_NAME, COUNT(*) AS FAILURES FROM (
  SELECT s.SOURCE_TPA_IDENTIFIER, s.ROW_EFFECTIVE_DATETIME
  FROM THIRD_PARTY_AGREEMENT_STG s
  JOIN CNTR_CLM_ADMNM_T c ON TRIM(s.SOURCE_TPA_IDENTIFIER) = TRIM(c.AGR_ID)
  WHERE c.CLM_ADMNM_EFF_DTE < s.ROW_EXPIRATION_DATETIME
    AND s.ROW_EFFECTIVE_DATETIME < c.CLM_ADMNM_EXP_DTE
  GROUP BY 1, 2
  HAVING COUNT(DISTINCT CONCAT_WS('~', COALESCE(c.CLM_ADMNM_CDE,       '~NULL~'),
                                       COALESCE(CAST(c.CLM_ADMNM_EFF_DTE AS VARCHAR), '~NULL~'),
                                       COALESCE(CAST(c.CLM_ADMNM_EXP_DTE AS VARCHAR), '~NULL~'))) > 1);
```

Substitute **every column that contributor supplies to the target** into the `CONCAT_WS`.

> **Never emit a version-counting form of this check** (`HAVING COUNT(*) > 1`). It fires on correct data:
> a collapsed interval spans two contributor versions by design when the value did not change.

---

## R6 — A foreign key to an SCD-2 table is a version reference. Cut the target at its boundaries too

### Trigger
A `Transformation` describes a **lookup** into another table — words like *"do a lookup on X"*, *"use Y to
look up"* — **and** that table's DDL carries `ROW_EFFECTIVE_DATETIME` / `ROW_EXPIRATION_DATETIME`.

### Why this one is easy to miss
`AGREEMENT` appears **once in the entire STTM**, in the free-text `Transformation` of row 2, on a row whose
`Current State Table` column says `Contract_t`:

> `use agr_id to do a lookup on Agreement table using the source_agreement_id attribute`

**A classifier that builds its source list from the `Current State Table` column will never see it.** This
is the second instance of the same blind spot that made this table a split table in the first place: a
table that governs the output, named only in prose.

### What happened
`AGREEMENT`'s DDL confirms it is SCD-2, and that its key is per-version:

```sql
AGREEMENT_ID NUMBER(38,0) NOT NULL
  COMMENT 'Unique, system-generated identifier for each agreement record;
           serves as the primary key of the agreement table.'
...
ROW_EFFECTIVE_DATETIME  TIMESTAMP_NTZ(9) NOT NULL
ROW_EXPIRATION_DATETIME TIMESTAMP_NTZ(9) NOT NULL
CURRENT_RECORD_INDICATOR VARCHAR(1) NOT NULL
```

Q2 resolves it by matching on the staging row's **start date only**:

```sql
AND stg.ROW_EFFECTIVE_DATETIME >= p_agreement_id.ROW_EFFECTIVE_DATETIME
AND stg.ROW_EFFECTIVE_DATETIME <  p_agreement_id.ROW_EXPIRATION_DATETIME
```

Executed. Agreement `A1` has two versions — `901` ACTIVE to 2024-04-01, then `902` ENDORSED. A staging
interval running 2024-01-01 → 9999-12-31 resolves to:

```
('A1', 2024-01-01, 9999-12-31, 901)
```

**One row, carrying `901` for all time — but `901` expired on 2024-04-01.** Every query joining this row to
`AGREEMENT` after that date reads status `ACTIVE` when the agreement was `ENDORSED`. This is precisely the
stale-attribute fault the effective-date split exists to prevent, one layer up.

### Correct output — split the staging interval at the looked-up table's boundaries

```sql
-- Any AGREEMENT version boundary falling strictly inside a staging interval becomes a cut point.
WITH fk_bounds AS (
    SELECT s.SOURCE_TPA_IDENTIFIER, s.SOURCE_SYSTEM_CODE, s.ROW_EFFECTIVE_DATETIME AS b
    FROM   THIRD_PARTY_AGREEMENT_STG s
    UNION
    SELECT s.SOURCE_TPA_IDENTIFIER, s.SOURCE_SYSTEM_CODE, s.ROW_EXPIRATION_DATETIME
    FROM   THIRD_PARTY_AGREEMENT_STG s
    UNION
    SELECT s.SOURCE_TPA_IDENTIFIER, s.SOURCE_SYSTEM_CODE, a.ROW_EFFECTIVE_DATETIME
    FROM   THIRD_PARTY_AGREEMENT_STG s
    JOIN   AGREEMENT a
      ON   s.SOURCE_TPA_IDENTIFIER = a.SOURCE_AGREEMENT_IDENTIFIER
     AND   s.SOURCE_SYSTEM_CODE    = a.SOURCE_SYSTEM_CODE
    WHERE  a.ROW_EFFECTIVE_DATETIME >  s.ROW_EFFECTIVE_DATETIME
      AND  a.ROW_EFFECTIVE_DATETIME <  s.ROW_EXPIRATION_DATETIME)
-- then LEAD() into intervals and resolve each by CONTAINMENT, exactly as the split does:
--   a.ROW_EFFECTIVE_DATETIME <= interval_start AND a.ROW_EXPIRATION_DATETIME >= interval_end
```

Executed, this yields the right answer:

```
('A1', 2024-01-01, 2024-04-01, 901, 'ACTIVE')
('A1', 2024-04-01, 9999-12-31, 902, 'ENDORSED')
```

### The decision to record

If the data model intends `AGREEMENT_ID` to be a **durable** business identifier rather than a version
surrogate, none of this applies — but then it must not be the SCD-2 table's primary key, and the model
needs a durable key exposed. **Either way, do not resolve an SCD-2 foreign key on the start date alone and
leave the interval uncut.** State which reading you used in a comment.

---

## R7 — Audit batch and job identifiers come from the framework, never from the query

### Trigger
A column whose STTM `Transformation` reads `Audit Fields` or `Audit Field: …`.

### What happened

| Column | STTM type | Generated |
|---|---|---|
| `AUDIT_BATCH_ID` | `BIGINT` | `CAST(TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS') AS VARCHAR(255))` |
| `AUDIT_JOB_ID` | `BIGINT` | `CAST(TO_VARCHAR(CURRENT_SESSION()) AS VARCHAR(255))` |

### Why it is wrong
A batch id invented from the clock cannot be joined to the orchestration framework's control tables, so the
load becomes untraceable — which is the one thing an audit column exists for. Two runs in the same second
collide; a restart gets a different id than the run it is restarting. The type is wrong in the opposite
direction from every other column, which is itself a signal the value was improvised.

### Correct output
Take both from the parameters the orchestration framework passes into the job. Where they are not
available, **halt** — do not substitute a clock reading.

```sql
CAST($AUDIT_BATCH_ID AS NUMBER(38,0)) AS AUDIT_BATCH_ID,
CAST($AUDIT_JOB_ID   AS NUMBER(38,0)) AS AUDIT_JOB_ID,
```

---

## R8 — Target DDL wins on datatypes, and the STTM must be told when it loses

### Trigger
The STTM's `Physical Data Type` disagrees with the target DDL.

### What happened
The generated `CAST`s differ from the STTM in a consistent pattern — `VARCHAR(255)→VARCHAR(80)`,
`VARCHAR(1024)→VARCHAR(35)`, `SMALLINT→VARCHAR(4)`. That consistency is evidence the generator read the
**real target DDL**, which is the correct precedence and is working as designed.

### Why it still needs reporting
Snowflake **does not permit a narrowing `VARCHAR` conversion** — it raises an error rather than truncating.
So if the STTM's `VARCHAR(1024)` is right for `Contract_Number` and the DDL's `VARCHAR(35)` is stale, the
load fails outright on the first long value. Silently preferring one source leaves nobody to resolve which
is correct.

### Correct output
Keep the target DDL's type. **Emit a reconciliation list as a comment at the head of the file**, so the
discrepancy reaches the data modeller instead of only the runtime:

```sql
-- DATATYPE RECONCILIATION (target DDL wins; STTM needs correcting):
--   CONTRACT_NUMBER        STTM VARCHAR(1024)  DDL VARCHAR(35)   <- narrowing, load fails on long values
--   CLIENT_NAME            STTM VARCHAR(1024)  DDL VARCHAR(255)  <- narrowing
--   BUSINESS_GROUP_CODE    STTM VARCHAR(255)   DDL VARCHAR(80)
--   FIRST_CONTRACT_EFFECTIVE_YEAR  STTM SMALLINT  DDL VARCHAR(4)
```

---

## Pre-flight checklist — run all of this before emitting any SQL

Each line is a **halt** if it fails.

| # | Check |
|---|---|
| 1 | Every identifier in every `Transformation` resolves against a real DDL (**R2**) |
| 2 | Every `Transformation` is fully parsed; nothing was dropped or approximated (**R1**) |
| 3 | A business key is identified, it is not a constant, and it is present in staging (**R3**) |
| 4 | Each contributor's interval basis is decided from its DDL and recorded in a comment (**R4**) |
| 5 | Every lookup target has been checked for `ROW_EFFECTIVE_DATETIME` — if SCD-2, apply **R6** |
| 6 | Source tables named only inside `Transformation` prose have been added to the source set (**R6**) |
| 7 | Datatype discrepancies are listed in a header comment (**R8**) |
| 8 | Audit batch and job ids come from framework parameters (**R7**) |
| 9 | One containment check emitted per contributor (**R5**) |
| 10 | The `MERGE` key is the business key, containing no resolved foreign-key surrogate (**R3**) |

---

## Appendix — the review this came from

Nine findings were raised against the generated `THIRD_PARTY_AGREEMENT` SQL. After the DDLs for
`CNTR_CLM_ADMNM_T`, `AGREEMENT` and `CONTRACT_T` were obtained, they resolve as follows.

| | Finding | Verdict | Rule |
|---|---|---|---|
| 1 | 12 `coalasce` fallbacks dropped | **Confirmed** — all 12 fallback columns exist on `CONTRACT_T`; real data loss | R1 |
| 2 | 3 `<>` conditions dropped | **Confirmed** | R1 |
| 3 | 3 broker columns on the wrong join key | **Confirmed** — `CONTRACT_T` has no `PRSP_ID`; the STTM is wrong *and* the substitution was silent | R2 |
| 4 | 4 of 7 self-checks keyed on a constant | **Confirmed by execution** — 3 fail on correct data with two keys; 1 can never fire | R3 |
| 5 | Containment check missing | **Confirmed** — numbering runs 1-6, 8 | R5 |
| 6 | `AGREEMENT` FK resolved on start date only | **Confirmed by execution** — stale FK demonstrated; `AGREEMENT` is SCD-2, `AGREEMENT_ID` is its per-version primary key | R6 |
| 7 | `CNTR_CLM_ADMNM_T` bounded by business dates | **WITHDRAWN** — the DDL has no `ROW_EFF_DM`; the table is not SCD-2 and DataAssist's choice was correct | R4 |
| 8 | `AUDIT_BATCH_ID` / `AUDIT_JOB_ID` invented | **Confirmed** | R7 |
| 9 | `MERGE` keyed on a resolved FK surrogate | **Confirmed by execution** — a renumbered `AGREEMENT` surrogate causes a duplicate insert | R3 |

### What the generator got right

Worth stating, because these rules should not disturb any of it:

- The **boundary-union split** is correctly implemented, and generalised unaided from the two-source
  proof to **eight contributing sources**.
- `drv` is an **INNER** join with containment and contributors are **LEFT** joins with containment —
  the driving source correctly bounds the target.
- The collapse step is **gap-aware**: `new_grp` includes `interval_start <> LAG(interval_end)`, so adjacent
  equal values merge but a gap is never collapsed across.
- `ROW_EFFECTIVE_DATETIME` / `ROW_EXPIRATION_DATETIME` are the **derived interval boundaries**, correctly
  overriding the STTM's literal mapping to `contract_t.row_eff_dm`.
- `CURRENT_RECORD_INDICATOR` is derived from the expiry alone.
- `AUDIT_CHANGE_HASH` **excludes both dates** — needed so "same values, different expiry" can be told from
  "different values".
- `WHERE i.interval_end IS NOT NULL` correctly drops the trailing open interval from `LEAD()`.

### Open, not a generator defect

`THIRD_PARTY_AGREEMENT_SEQ.NEXTVAL` inside `WHEN NOT MATCHED THEN INSERT … VALUES` is expected to work but
was not confirmed from documentation. **Test it in the account before the first run** — it is a hard failure
if unsupported.

### Verification

Every executed claim above is reproduced by `../tools/verify/verify_tpa_assertions.py` and
`../tools/verify/verify_tpa_agreement_fk.py`. Re-run both if an example in this file changes.
