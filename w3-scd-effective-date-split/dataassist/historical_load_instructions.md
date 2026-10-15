# Historical (Day 1) load — instructions for DataAssist

**Audience:** the DataAssist generator. **Scope:** the historical / full-history load only.
**Out of scope:** incremental loads. See §11.

**Read `generation_rules.md` first.** It is the generation discipline — when to stop rather
than guess — learned from reviewing the first generated output against this file. This file says *what to
produce*; that one says *how to behave while producing it*.

Read §1 to §5 for every table. Then run the classifier in §4, pick exactly one template from §6, §7 or
§8, and emit the assertions in §10 into the generated SQL. §12 says how to re-verify the examples.

---

## 1. Assumptions this file is written on

Confirm these once. If any is false, stop and raise it rather than generating.

| # | Assumption |
|---|---|
| A1 | **The target table is empty when the historical load runs.** Truncate-and-reload. The load is not restartable against a partially filled target |
| A2 | The **high end date** is `9999-12-31`. A row carrying it is open-ended |
| A3 | **The target DDL is the source of truth for datatypes.** Where staging disagrees, staging is redesigned to match the target. Never cast to the staging type to make a load succeed |
| A4 | Q1 (source to staging) always runs before Q2 (staging to target) |
| A5 | Every target in scope is `SCD-2` in the STTM's `Future State Table SCD Type` column |

> ### The one place these instructions override the STTM
>
> For a **class C** table (§4), the STTM names one source's `ROW_EFF_DM` / `ROW_EXP_DM` as the mapping for
> the target's `ROW_EFFECTIVE_DATETIME` / `ROW_EXPIRATION_DATETIME`. **Do not take them literally.** The
> target's dates must be the **derived interval boundaries** of §8, which are built from *both* sources'
> boundaries and in general match neither source's raw dates.
>
> This is unavoidable: a target row is only valid over a period where both contributing sources hold one
> unchanging version, and no single source's dates describe that. Everywhere else in the STTM is taken as
> written. For class A and class B tables there is no override at all.

---

## 2. Day 1 in one line

> **On an empty target every derived row is an INSERT. No row can be updated, expired or retired, because
> there is nothing there to match.**

This is not a simplification. The incremental design has an 18-rule decision table, and seventeen of those
rules require an existing target row — sixteen require a match, one requires a row that has disappeared.
On an empty target **only the insert rule can fire**. Verified by running the initial load of fifteen
differently-shaped test scenarios: every one produced the insert rule and nothing else.

So **the whole difficulty of Day 1 is deriving the right rows**, not deciding what to do with them.

---

## 3. Pre-requisite checks, per table

Run before generating anything. Each failure is a **stop**, not a warning.

| # | Check | Why |
|---|---|---|
| P1 | The target has `ROW_EFFECTIVE_DATETIME` and `ROW_EXPIRATION_DATETIME`, both `NOT NULL` | Without both there is no SCD-2 timeline to build |
| P2 | The target has `CURRENT_RECORD_INDICATOR` and `DELETE_INDICATOR` | §5 populates both |
| P3 | The STTM names a **business key** — the natural-key flagged column(s) — and it is not the surrogate key, **not a hardcoded constant, and present in staging**. If every natural-key column is a constant or resolved downstream, use the driving table's own identifier and say so in a comment | The timeline is built per business key, and every assertion and the MERGE are keyed on it. A constant key makes all of them measure nothing — `generation_rules.md` R3 |
| P4 | The target's surrogate key has a sequence available | Q2 assigns it |
| P5 | Every source table named in the STTM exists and is readable | |
| P6 | For each source table, record whether it carries **effective and expiry date columns** (`ROW_EFF_DM` / `ROW_EXP_DM` or equivalent). **This is the input to the classifier** | §4 |
| P7 | Where staging and target datatypes disagree, flag for staging redesign per A3 — do not generate a cast | |

---

## 4. The classifier — does this table need effective-date splitting?

### What to read

For each target column the STTM gives: current-state table(s), current-state column(s), a free-text
**Transformation**, the physical target column, and the SCD-type and natural-key flags.

Ignore columns whose Transformation is `Audit Field`, `Hardcode …`, or which map from no source table.
Those never affect the classification. Consider only columns that **draw a value from a source table**.

### The decision

Let **S** = the set of distinct source tables feeding those columns.
Let **S₂** ⊆ S = those that carry effective/expiry dates (from P6).

| Condition | Class | Template |
|---|---|---|
| `S₂` is empty | **A — no history** | §6 |
| `S₂` has one table | **B — single history source** | §7 |
| `S₂` has two or more, **but** the Transformations mark them as *alternatives* | **B — single history source** | §7 |
| `S₂` has two or more and they are **co-equal contributors** | **C — effective-date split** | §8 |

### Telling alternatives from co-equal contributors

**Alternatives** — one row comes from one source *or* the other, and takes that source's dates.
Signals in the Transformation text:

- `"union data from these 2 tables"`
- `"When sourcing from X … When sourcing from Y …"`
- `"Null when sourcing from Y"`
- `"Hardcode 'N' when sourcing from X. Hardcode 'Y' when sourcing from Y"`
- a priority or precedence list over sources supplying the *same* attributes

**Co-equal contributors** — one row draws different attributes from both, so both timelines govern it.
Signal:

- `"Join from A to B by <predicate>"` (or any phrasing describing a lookup/join to another table)
  **where that joined table is in `S₂`**

> ### The rule that matters most
>
> **A single target column sourced by a join to a second table that carries effective/expiry dates makes
> the table class C — even if every other column comes from one source, and even if the join predicate
> mentions no dates at all.**
>
> One column is enough. This is the easiest case to miss by eye.

### Worked example — `ACCOUNT_PARTY_REFERENCE` is class C

| Source table | In `S₂`? | Feeds |
|---|---|---|
| `ACCOUNT_REF_T` | **yes** (`ROW_EFF_DM`, `ROW_EXP_DM`) | most attributes, and the STTM names its dates for the target's dates |
| `PROSPECT_REF_T` | yes | an **alternative** to `ACCOUNT_REF_T` — *"union data from these 2 tables"*, *"Null when sourcing from prospect_ref_t"* |
| `ACCOUNT_NUMBER_ELEMENT_T` | **yes** (`ROW_EFF_DM`, `ROW_EXP_DM`) | `ACTIVE_NUMERAL_ISSUE_RECORD_INDICATOR`, via *"Join from account_number_element_t to account_ref_t by using concat(acct_ldgr_num,'-',acct_srl_num) = acct_rfrn_num and srl_typ_code = acct_rfrn_typ_cde"* |

`ACCOUNT_REF_T` and `PROSPECT_REF_T` are alternatives, so they collapse to one. `ACCOUNT_NUMBER_ELEMENT_T`
is reached by a **join** and is in `S₂`. Two co-equal contributors remain → **class C**.

**22 of this table's 23 mapped columns look like an ordinary union.** One column decides it.

### Worked example — `BROKER_PARTY` is class B

Eight source tables, all prioritised alternatives supplying the same attribute set, deduplicated by a
priority order. No join to a second dated table → **class B**.

### Record the decision

Emit the classification and its evidence as a comment at the head of Q1, so a human can audit it:

```sql
-- CLASSIFICATION: class C (effective-date split)
-- Dated source tables: ACCOUNT_REF_T, PROSPECT_REF_T, ACCOUNT_NUMBER_ELEMENT_T
-- ACCOUNT_REF_T / PROSPECT_REF_T treated as ALTERNATIVES, evidence:
--   STTM row 1 Transformation: "union data from these 2 tables"
--   STTM row 7 Transformation: "Null when sourcing from prospect_ref_t"
-- ACCOUNT_NUMBER_ELEMENT_T treated as a CO-EQUAL CONTRIBUTOR, evidence:
--   STTM row 9 Transformation: "Join from account_number_element_t to account_ref_t by ..."
--   and ACCOUNT_NUMBER_ELEMENT_T carries ROW_EFF_DM / ROW_EXP_DM
```

---

## 5. Column rules that apply to every class

### `CURRENT_RECORD_INDICATOR`

```sql
CASE WHEN <target ROW_EXPIRATION_DATETIME> >= TIMESTAMP '9999-12-31 00:00:00'
     THEN 'Y' ELSE 'N' END
```

It is **derived from the expiry date and nothing else**. Never carry it from a source. Never hardcode it.
A source table with no history produces one open-ended row, so it gets `'Y'`.

### `DELETE_INDICATOR`

Carry the source's soft-delete column where the STTM names one — e.g. `COALESCE(DLT_I, 'N')`.
Where the STTM says to hardcode `'N'`, hardcode `'N'` **for the historical load**.

> Note for later: the incremental design retires some rows by setting this column to `'Y'`. A target whose
> mapping hardcodes it cannot support that. Flag it; it does not affect Day 1.

### Dates

The target's `ROW_EFFECTIVE_DATETIME` / `ROW_EXPIRATION_DATETIME` come from:

- **class A** — defaults: `1900-01-01` to `9999-12-31`
- **class B** — the single history source's own effective and expiry dates
- **class C** — **the derived interval boundaries** (§8). **These are not any one source's raw dates.**

### Audit and surrogate columns

| Column | Historical load |
|---|---|
| surrogate key | `NULL` in staging; Q2 assigns `<TARGET>_SEQ.NEXTVAL` |
| `ROW_CREATE_DATETIME`, `ROW_UPDATE_DATETIME` | `CURRENT_TIMESTAMP()` |
| `ROW_CREATED_BY_USERID`, `ROW_UPDATED_BY_USERID` | `CURRENT_USER()` |
| `AUDIT_BATCH_ID`, `AUDIT_JOB_ID` | per existing convention |
| `AUDIT_CHANGE_HASH` | MD5 over the target's business and attribute columns |
| `AUDIT_ZONE_1_LINEAGE_ID` | `OBJECT_CONSTRUCT` of the contributing source table name(s) and key |
| `CHANGE_FLAG` (staging) | **`0`** — DataAssist's existing insert value (`0` insert, `1` update, `3` skip). Every historical row is an insert |

### Datatypes

Per A3, the **target DDL wins**. Where staging disagrees, raise it for staging redesign. Do not emit a cast
that would truncate or fail — e.g. a concatenated identifier must not be loaded into a numeric column.

---

## 6. Template A — no history source

One row per business key. Dates default to `1900-01-01` → `9999-12-31`, `CURRENT_RECORD_INDICATOR = 'Y'`.

---

## 7. Template B — one history source, or prioritised alternatives

This is the shape already in use. In outline:

1. Extract from each dated source, `UNION ALL`, carrying a `TABLE_PRIORITY`.
2. Deduplicate per `(business key, effective date)`:
   `ROW_NUMBER() OVER (PARTITION BY <key>, <eff> ORDER BY TABLE_PRIORITY, <exp> DESC) = 1`
3. Add non-dated sources only for keys absent from the dated ones, with default dates.
4. Build the target column set per §5.

Each source row becomes one staging row. **No interval derivation is required.**

---

## 8. Template C — two or more co-equal history sources (the split)

### The problem this solves

The target's attributes come from two timelines. A target row is only valid over a period where **both**
sources hold a single unchanging version. Joining them on business attributes alone produces a cartesian
across versions.

### The algorithm

For each business key:

1. **Collect boundaries.** Take every effective date and every expiry date from **every** contributing
   source for that key. Sort distinct ascending. This is the only set of dates at which the target may
   change.
2. **Form candidate intervals.** Each consecutive pair of boundaries is one candidate interval
   `[b(i), b(i+1))`.
3. **Resolve each interval.** For each contributing source, select the version whose
   `eff <= b(i) AND exp >= b(i+1)` — the version that **contains** the whole interval. There is at most
   one. If a source has none, that source's attributes are `NULL` for that interval.
4. **Collapse.** Merge adjacent intervals where **all** attribute values are identical **and** the
   intervals touch (`previous exp = next eff`). A gap must never be collapsed across, even when the values
   either side match.
5. **Emit.** One staging row per surviving interval, with
   `ROW_EFFECTIVE_DATETIME = b(i)`, `ROW_EXPIRATION_DATETIME = b(i+1)`, and §5's column rules.

### Which source bounds the target

The target's extent is bounded by the source supplying the **business key and the target's identity** —
the driving source. Periods covered only by a contributing source, with no driving-source row, produce **no
target row**. Periods covered by the driving source but not a contributor produce a row with that
contributor's attributes `NULL`.

### Worked example

Business key `1001 / AB-123 / L`.

**`ACCOUNT_REF_T`** — the driving source:

| version | `ROW_EFF_DM` | `ROW_EXP_DM` | `ACCT_RFRN_TYP_CDE` |
|---|---|---|---|
| v1 | 2024-01-01 | 2024-06-01 | `L` |
| v2 | 2024-06-01 | 9999-12-31 | `M` |

**`ACCOUNT_NUMBER_ELEMENT_T`** — joined contributor:

| version | `ROW_EFF_DM` | `ROW_EXP_DM` | `ACTV_NMRL_ISS_RCRD_I` |
|---|---|---|---|
| e1 | 2024-01-01 | 2024-03-15 | `Y` |
| e2 | 2024-03-15 | 9999-12-31 | `N` |

**Step 1 — boundaries:** `2024-01-01`, `2024-03-15`, `2024-06-01`, `9999-12-31`

**Steps 2–3 — resolve:**

| interval | from `ACCOUNT_REF_T` | from `ACCOUNT_NUMBER_ELEMENT_T` |
|---|---|---|
| 2024-01-01 → 2024-03-15 | v1 → type `L` | e1 → indicator `Y` |
| 2024-03-15 → 2024-06-01 | v1 → type `L` | e2 → indicator `N` |
| 2024-06-01 → 9999-12-31 | v2 → type `M` | e2 → indicator `N` |

**Step 4 — collapse:** no two adjacent intervals have identical attributes, so all three survive.

**Step 5 — three staging rows:**

| `ROW_EFFECTIVE_DATETIME` | `ROW_EXPIRATION_DATETIME` | type | indicator | `CURRENT_RECORD_INDICATOR` |
|---|---|---|---|---|
| 2024-01-01 | 2024-03-15 | `L` | `Y` | `N` |
| 2024-03-15 | 2024-06-01 | `L` | `N` | `N` |
| 2024-06-01 | 9999-12-31 | `M` | `N` | **`Y`** |

### What goes wrong without the split

Joining on the business attributes alone, with no date predicate, gives `v1×e1, v1×e2, v2×e1, v2×e2` —
**four rows for a key that has three valid intervals**, two of them sharing an effective date. The staging
de-duplication then keeps one arbitrarily. Whichever survives, the target carries the wrong indicator for
part of its own interval, and nothing reports an error.

Note also that the correct answer has **three** rows where the driving source has **two** versions. A split
table's target row count is not the driving source's version count.

### A collapse illustration

Had `ACCOUNT_NUMBER_ELEMENT_T` held `Y` for both e1 and e2, intervals 1 and 2 would carry identical
attributes and touch at `2024-03-15`, so step 4 merges them into `2024-01-01 → 2024-06-01`. Two rows, not
three. Without collapsing, the target would be split at a date where nothing actually changed.

---

## 9. Q2 for the historical load

With an empty target (A1), every staging row is an insert.

- Assign the surrogate key: `<TARGET>_SEQ.NEXTVAL`
- Carry every column through from staging
- No change-detection join, no update path, no skip path — those exist for the incremental load

If `CHANGE_FLAG` is populated it is **`0`** on every row — never `1` (update) and never `3` (skip).
**A historical run that emits any other value means the target was not empty — stop and investigate.**

---

## 10. Self-check assertions to emit into the generated SQL

Emit all of these. They cost one scan each and turn a misclassification into a loud failure instead of
quietly wrong data.

```sql
-- 1. One staging row per business key and effective date. Catches a raw join fanout.
--    NOTE: this does NOT catch a misclassified class C table on its own -- see check 7.
SELECT 'DUPLICATE_KEY_EFF' AS CHECK_NAME, COUNT(*) AS FAILURES FROM (
  SELECT <business_key>, ROW_EFFECTIVE_DATETIME
  FROM <staging> GROUP BY 1,2 HAVING COUNT(*) > 1);

-- 2. CURRENT_RECORD_INDICATOR always agrees with the expiry date.
SELECT 'CURRENT_IND_MISMATCH', COUNT(*) FROM <staging>
WHERE CURRENT_RECORD_INDICATOR <>
      CASE WHEN ROW_EXPIRATION_DATETIME >= TIMESTAMP '9999-12-31 00:00:00' THEN 'Y' ELSE 'N' END;

-- 3. No interval overlaps another for the same key.
SELECT 'OVERLAPPING_INTERVALS', COUNT(*) FROM <staging> a JOIN <staging> b
  ON a.<business_key> = b.<business_key>
 AND a.ROW_EFFECTIVE_DATETIME < b.ROW_EFFECTIVE_DATETIME
 AND b.ROW_EFFECTIVE_DATETIME < a.ROW_EXPIRATION_DATETIME;

-- 4. No zero- or negative-width interval.
SELECT 'BAD_INTERVAL', COUNT(*) FROM <staging>
WHERE ROW_EXPIRATION_DATETIME <= ROW_EFFECTIVE_DATETIME;

-- 5. No NULL business key.
SELECT 'NULL_BUSINESS_KEY', COUNT(*) FROM <staging> WHERE <business_key> IS NULL;

-- 6. Exactly one open-ended row per key.
SELECT 'OPEN_ENDED_COUNT', COUNT(*) FROM (
  SELECT <business_key> FROM <staging>
  WHERE ROW_EXPIRATION_DATETIME >= TIMESTAMP '9999-12-31 00:00:00'
  GROUP BY 1 HAVING COUNT(*) <> 1);

-- 7. CLASS C ONLY. Across every contributing-source version that overlaps a staging interval,
--    the contributed VALUES must be the same one. This is the containment property the split exists
--    to guarantee. Compare values, not versions -- see the note below.
SELECT 'CONTAINMENT_VIOLATION', COUNT(*) FROM (
  SELECT s.<business_key>, s.ROW_EFFECTIVE_DATETIME
  FROM <staging> s
  JOIN <contributing_source> c ON <join predicate>
  WHERE c.ROW_EFF_DM < s.ROW_EXPIRATION_DATETIME
    AND s.ROW_EFFECTIVE_DATETIME < c.ROW_EXP_DM
  GROUP BY 1, 2
  HAVING COUNT(DISTINCT CONCAT_WS('~', COALESCE(c.<contributed_col_1>, '~NULL~'),
                                       COALESCE(c.<contributed_col_2>, '~NULL~'))) > 1);
```

```sql
-- 8. Historical load only: every staging row is an insert.
SELECT 'NON_INSERT_FLAG', COUNT(*) FROM <staging> WHERE CHANGE_FLAG <> 0;
```

**Every one must return zero.** A non-zero result is a stop, not a warning.

> **Check 7 is the one that catches a misclassification, and it cannot be dropped.** When a class C table is
> generated with the class B template, the dedup `ROW_NUMBER()` collapses the fanout to one row per
> `(key, effective date)` *before* staging is written. Checks 1 to 6 then all pass, on data that is wrong.
> Proved against §8's worked example: the class B template emits two staging rows, both carrying indicator
> `'N'`, and the first of them carries `'N'` over a period where the source says `'Y'`. Check 1 returned 0.
> **Check 7 returned 1.** It was the only signal.
>
> **Check 7 compares values, not versions, and that distinction matters.** A collapsed interval (§8 step 4)
> legitimately spans two contributing-source versions — that is the whole point of collapsing: the value did
> not change, so the target is not cut there. Counting *versions* would report a violation on correct data.
> Counting *distinct contributed values* reports one only when a single target interval would have to carry
> two different values at once, which is the actual fault. **A version-counting form of this check was
> written first and was proved wrong against the collapse example in §8** — do not reintroduce it.
>
> Check 7 also catches **overlapping versions inside a single source**, where two versions covering the same
> instant disagree on the value. The split assumes each source holds a clean non-overlapping chain per key.
> That assumption is load-bearing and is not enforced upstream, so check 7 is the only thing standing between
> an overlapping source and silently wrong output.
>
> Substitute every column the contributing source supplies to the target into check 7's `CONCAT_WS`. With
> one contributed column, drop the second argument.
>
> **Emit check 7 once per contributing source, not once per table.** The first generated output omitted it
> entirely on a table with eight contributors — `generation_rules.md` R5.

---

## 11. Deliberately out of scope

Everything below belongs to the incremental load and must **not** appear in generated historical SQL.

| | Why it is out of scope |
|---|---|
| The 18-rule decision table | Seventeen rules need an existing target row; §2 |
| Expire-in-place, dead records, soft-delete retirement | All require a row to retire |
| `AUDIT_CHANGE_HASH` comparison against the target | Nothing to compare against on an empty target |
| Rerun / restart handling | A1: truncate and reload |

**One forward note.** The incremental design needs a hash over **target-bound attributes only, excluding
the dates**, because it must tell *"same values, different expiry"* apart from *"different values"*. A hash
that includes the effective and expiry dates cannot distinguish them. This does not affect the historical
load, where the hash is only stored. Raise it before incremental work starts.

---

## 12. These examples are machine-verified

Every worked example and every assertion in this file was executed, not reasoned about. Two runnable
scripts in `tools/` reproduce it:

| Script | What it proves |
|---|---|
| `verify_historical_examples.py` | §8's algorithm on §8's data gives exactly the three documented rows; the collapse variant gives exactly two; all eight assertions return zero on both; and the naive join gives exactly the four rows §8 says it does, tripping check 1 |
| `verify_historical_check7.py` | Generating §8's class C table with the **class B** template passes checks 1 to 6 and is caught **only** by check 7 |

```
python3 ../tools/verify/verify_historical_examples.py
python3 ../tools/verify/verify_historical_check7.py
```

They need `duckdb` only. **If an example in this file is changed, re-run both.** A documented example that
has drifted from the algorithm is worse than no example, because DataAssist will follow the example.
