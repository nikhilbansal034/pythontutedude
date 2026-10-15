# Worked examples

Every example here was **executed**, not reasoned about. The scripts that reproduce them are in
`../tools/verify/` and need `duckdb` only. Pattern-match against these before inventing an approach.

---

## 1. The core split — two co-equal sources

**Sources.** `ACCOUNT_REF_T` is the driving source; `ACCOUNT_NUMBER_ELEMENT_T` contributes one column.

| `ACCOUNT_REF_T` | eff | exp | type |
|---|---|---|---|
| v1 | 2024-01-01 | 2024-06-01 | `L` |
| v2 | 2024-06-01 | 9999-12-31 | `M` |

| `ACCOUNT_NUMBER_ELEMENT_T` | eff | exp | indicator |
|---|---|---|---|
| e1 | 2024-01-01 | 2024-03-15 | `Y` |
| e2 | 2024-03-15 | 9999-12-31 | `N` |

**Boundaries:** `2024-01-01`, `2024-03-15`, `2024-06-01`, `9999-12-31`

**Resolve each candidate interval by containment:**

| interval | from `ACCOUNT_REF_T` | from `..._ELEMENT_T` |
|---|---|---|
| 01-01 → 03-15 | v1 → `L` | e1 → `Y` |
| 03-15 → 06-01 | v1 → `L` | e2 → `N` |
| 06-01 → 9999 | v2 → `M` | e2 → `N` |

**Collapse:** no two adjacent intervals are identical, so all three survive.

**Output — three rows:**

| eff | exp | type | indicator | current |
|---|---|---|---|---|
| 2024-01-01 | 2024-03-15 | `L` | `Y` | `N` |
| 2024-03-15 | 2024-06-01 | `L` | `N` | `N` |
| 2024-06-01 | 9999-12-31 | `M` | `N` | **`Y`** |

**Two sources with two versions each produce three target rows.** A split table's row count is not any
source's version count.

### What happens without the split

Joining on the business attributes alone gives `v1×e1, v1×e2, v2×e1, v2×e2` — **four rows for three valid
intervals**, two sharing an effective date. Executed, the duplicate-key check fires with 2. But if a
`ROW_NUMBER()` de-duplication runs first, that check returns **0** and the wrong value ships silently.

---

## 2. Collapse, and why gaps are different

### Collapse — adjacent and identical

Change `e2`'s indicator to `Y` so both element versions agree. Intervals 1 and 2 now carry identical
attributes **and touch** at `2024-03-15`, so they merge:

| eff | exp | type | indicator |
|---|---|---|---|
| 2024-01-01 | **2024-06-01** | `L` | `Y` |
| 2024-06-01 | 9999-12-31 | `M` | `Y` |

**Two rows, not three.** Without collapsing, the target would be split at a date where nothing changed.

### A gap must never be collapsed across

Staging holds `2024-01-01 → 2024-06-01` and `2024-09-01 → 9999-12-31` — a genuine gap from June to
September. Executed:

```
('O001','D001', 2024-01-01, 2024-06-01)
('O001','D001', 2024-09-01, 9999-12-31)
```

The June→September interval has no containing staging row, so the `INNER` join drops it. **The gap is
preserved** — by construction, not by an explicit rule. That means nothing protects it if the join is
later changed to a `LEFT`.

> **The collapse test is "identical **and** touching".** Identical alone would erase the gap; touching
> alone would merge a real change.

---

## 3. The foreign-key split — a parent that versions

A target FKs into an SCD-2 dimension whose ID identifies a **version**.

| `OFFICE_ID` | `OFFICE_NUMBER` | from | to |
|---|---|---|---|
| 501 | O001 | 2024-01-01 | 2024-05-01 |
| 502 | O001 | 2024-05-01 | 9999-12-31 |

The association `(O001, D001)` was created 2024-01-01 and **never changed**. One staging row,
`2024-01-01 → 9999-12-31`.

**The correct answer is two rows** — not because the association changed, but because its parent did.
Executed, with the split applied:

```
('O001','D001', 2024-01-01, 2024-05-01, 501)
('O001','D001', 2024-05-01, 9999-12-31, 502)
```

### The edge case: a parent that is retired

Office `O001` is retired on 2024-05-01 with **no successor**. A boundary union collecting only the parent's
**effective** dates finds nothing inside the interval, so no cut is made. Executed:

```
('O001','D001', 2024-01-01, 9999-12-31, 501)   <- 501 expired on 2024-05-01
```

**A version chain is defined by two dates, so a boundary union takes both.** Collecting only effective
dates silently assumes the chain has no end and no gaps.

### The volume consequence, which is correct but needs sizing

One association that never changed, against an office that versions 15 times:

```
staging rows: 1   office versions: 15   ->   target rows: 16
```

Every target version exists only because its **parent** changed. Over a long history, parent churn becomes
the dominant driver of an association table's row count. That is inherent to a correct SCD-2 foreign key,
not a bug — but cost it before the historical load runs.

---

## 4. The split computed and then discarded — defect OD10

The stage derives each sub-interval under new aliases but keeps the original dates alongside:

| | `SPLIT_ROW_EFFECTIVE` | `SPLIT_ROW_EXPIRATION` | `ROW_EFFECTIVE` | `ROW_EXPIRATION` |
|---|---|---|---|---|
| row 1 | **2024-01-01** | **2024-05-01** | 2024-01-01 | 9999-12-31 |
| row 2 | **2024-05-01** | **9999-12-31** | 2024-01-01 | 9999-12-31 |

The FK lookup correctly uses the `SPLIT_` dates, so row 1 resolves to `501` and row 2 to `502`. Then the
output emits the **original** columns, making the two rows identical except for the FK — and the closing
uniqueness guarantee partitions on the original effective date:

```sql
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY OFFICE_NUMBER, DEPARTMENT_NUMBER, ROW_EFFECTIVE_DATETIME    -- the UNSPLIT date
    ORDER BY ROW_EXPIRATION_DATETIME DESC NULLS LAST) = 1;
```

Both rows share `2024-01-01`, so one is dropped, and the tie-break compares `9999-12-31` to `9999-12-31` —
**arbitrary**. Executed:

```
fk_split_stg produces 2 correct sub-intervals
the final SELECT returns:
   ('O001','D001', 2024-01-01, 9999-12-31, OFFICE_ID 502)      <- 1 row
```

> **After a split, the business key is no longer `(key, original effective date)`. It is
> `(key, sub-interval start)`.** Keyed on the old one, a uniqueness guarantee does exactly what the split
> exists to prevent.

---

## 5. A self-check that cannot fail

Seeded with a genuinely corrupt source chain — one department with **two rows on the same effective date**,
plus a third overlapping — and the generated checks run verbatim:

```
reports 0   1 DUPLICATE_KEY_EFF      = 0      <- on a source that HAS a duplicate
reports 0   2 CURRENT_IND_MISMATCH   = 0
FIRES       3 OVERLAPPING_INTERVALS  = 1
reports 0   8 NON_INSERT_FLAG        = 0
```

| Check | Why it cannot fire |
|---|---|
| 1 | the query filters `ROW_NUMBER() = 1` over **exactly** `(key, effective date)` — the dedup guarantees what the check tests |
| 2 | compares a column against the expression that produced it |
| 8 | tests a literal in the `SELECT` list |

The same check pointed at the **source** returns `1` immediately.

> **Before emitting a check, ask: what data would make this fail?** If the answer is "none, because this
> query already guarantees it", the check belongs somewhere else — usually against the source, before the
> step that enforces the property.

---

## 6. Checks keyed on the wrong key

### A constant as the business key

Four self-checks were keyed on `SOURCE_SYSTEM_CODE`, a hardcoded `'CCO'`. Run against a staging table with
just **two** business keys:

```
FAIL  1 DUPLICATE_KEY_EFF      = 1     (should be 0)
FAIL  3 OVERLAPPING_INTERVALS  = 2     (should be 0)
FAIL  6 OPEN_ENDED_COUNT       = 1     (should be 0)
pass  5 NULL_BUSINESS_KEY      = 0     ('CCO' can never be NULL — can never fire)
```

Re-keyed properly, all four return 0. On a real table these report failures in the millions, and the team
learns to ignore the checks.

### A key missing a scoping column

The STTM flags only `JOB_CODE` as natural key; the table also carries `HR_BUSINESS_GROUP_CODE`. Seeded with
job `A100` in two business groups:

```
source rows 4 -> staging rows 3
   ('A100', 'CORP-US  ', 'Claims Adjuster')
   ('B200', 'CORP-US  ', 'Senior Actuary')
   ('B200', 'CORP-US  ', 'Actuary')
-> the SPECIALTY 'Underwriting Analyst' job is gone
```

Then **all eight generated checks against that staging table:**

```
reports 0   1 · 2 · 3 · 4 · 5 · 6 · 8 · 9     — every one
```

**A whole job lost, every check green.** No amount of checking a wrongly-keyed table finds a wrongly-chosen
key. The only check that catches it compares source and staging row counts.

---

## 7. A NULL date deletes a row silently

Staging holds one row whose expiry is NULL. The containment predicate
`s.ROW_EXPIRATION_DATETIME > fi.ROW_EFFECTIVE_DATETIME` evaluates to **NULL**, not true:

```
staging rows: 1 (expiry NULL)   rows surviving the split: 0
```

And the interval checks are NULL-blind: `ROW_EXPIRATION_DATETIME <= ROW_EFFECTIVE_DATETIME` is also NULL,
so check 4 reports zero. **A three-valued predicate drops rows silently, and a check written with `<=` or
`>` will not notice.** Assert non-NULL separately, naming the columns.

---

## 8. The incremental rule table on one key

Worked in full in `02_incremental_load_instructions.md` §11. The short version — a target with two rows,
one restated source column, and what comes out:

| rebuilt eff | target row | hash | expiry | rule | mechanism |
|---|---|---|---|---|---|
| 2024-01-01 | closed 06-01 | **same** | **diff** | **7** | delete indicator — the row was a published statement, so changing it is a correction |
| 2024-03-15 | none | — | — | **17** | insert |
| 2024-06-01 | open | **diff** | same | **9** | dead record — the row never committed to an end date |

**Rule 7 fired on a row whose hash was unchanged.** Only the boundary moved. A hash-only comparison would
have written nothing and reported success.

**The two retirements used different mechanisms**, decided by each row's **own expiry** — not by what
changed about it.
