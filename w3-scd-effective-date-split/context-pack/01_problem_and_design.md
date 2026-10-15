# The problem, and the design that solves it

Distilled from `../solution_design.md` §1–§19. The narrative of how it was reached is there; this file is
the mechanism and the rules, which is what you need to act.

---

## 1. The problem

A target is SCD Type-2: each row is a version, valid from `ROW_EFF_DTE` until `ROW_EXP_DTE`. It is loaded by
joining two or more SCD-2 source tables. **Neither source alone can say when a target version begins or
ends**, because the target changes whenever *either* source changes.

### Worked example

Source A says a broker's status, source B says their commission tier:

| A — status | from | to |
|---|---|---|
| `ACTIVE` | 2024-01-01 | 2024-06-01 |
| `REVIEW` | 2024-06-01 | 9999-12-31 |

| B — tier | from | to |
|---|---|---|
| `GOLD` | 2024-01-01 | 2024-03-15 |
| `SILVER` | 2024-03-15 | 9999-12-31 |

**The correct target is three rows**, cut at every date either source moved:

| from | to | status | tier |
|---|---|---|---|
| 2024-01-01 | 2024-03-15 | `ACTIVE` | `GOLD` |
| 2024-03-15 | 2024-06-01 | `ACTIVE` | `SILVER` |
| 2024-06-01 | 9999-12-31 | `REVIEW` | `SILVER` |

Note the row count: **A has 2 versions, B has 2, the target has 3.** A split table's target row count is not
any source's version count.

### Why the obvious approach fails

Joining A to B on the business key with no date predicate gives `A1×B1, A1×B2, A2×B1, A2×B2` — **four rows
for three valid intervals**, two of them sharing an effective date. The staging de-duplication then keeps
one arbitrarily.

**And the de-duplication is what makes this dangerous.** It collapses the fan-out *before* staging is
written, so a duplicate-key check placed downstream reports zero. The target silently carries the wrong
value for part of its own interval, and nothing errors.

### This is not the common pattern

The established pattern is one driving table LEFT JOINed to others purely for attribute enrichment, where
the driving table alone sets the target dates. That is correct and needs none of this. The split applies
only when two or more sources are **co-equal contributors** — see §3.

---

## 2. The solution: rebuild and diff

**Do not reconcile row by row. Rebuild each impacted key's whole timeline, then diff it against the target.**

### Step 1 — derive the correct timeline

1. **Collect boundaries.** Every effective date and every expiration date from **every** contributing
   source, for that key. Distinct, ascending. This is the only set of dates at which the target may change.
2. **Form candidate intervals.** Each consecutive pair of boundaries is one candidate: `[b(i), b(i+1))`.
3. **Resolve each interval by containment.** For each source, select the version where
   `eff <= b(i) AND exp >= b(i+1)` — the version that contains the **whole** interval. There is at most one.
   A source with none contributes `NULL` for that interval.
4. **Collapse.** Merge adjacent intervals where all attribute values are identical **and** the intervals
   touch (`previous exp = next eff`). **Never collapse across a gap**, even when the values either side
   match.
5. **Emit** one row per surviving interval.

### Which source bounds the target

The **driving source** — the one supplying the business key and the target's identity — is joined
`INNER`; every other contributor is joined `LEFT`. So:

- a period the driving source does not cover produces **no target row**;
- a period it covers but a contributor does not produces a row with that contributor's attributes `NULL`.

### Step 2 — diff against the target

Match each rebuilt interval to the existing target row on `(business_key, row_eff_dte)` and apply §4's
decision table.

---

## 3. Classifying a table — does it need the split?

Read the STTM. Ignore columns whose Transformation is `Audit Field`, `Hardcode …`, or that map from no
source. From the rest, let **S** be the distinct source tables, and **S₂ ⊆ S** those carrying effective and
expiration date columns.

| Condition | Class | Treatment |
|---|---|---|
| `S₂` empty | **A** — no history | one row per key, default dates `1900-01-01` → `9999-12-31` |
| `S₂` has one table | **B** — single history source | that source's own dates, pulled through |
| `S₂` has 2+, but they are **alternatives** | **B** | prioritised union, deduplicate on `(key, eff)` |
| `S₂` has 2+ **co-equal contributors** | **C** — split required | §2 |

### Alternatives vs co-equal contributors

**Alternatives** — a row comes from one source *or* the other and takes that source's dates. Signals:
*"union data from these 2 tables"*, *"When sourcing from X … When sourcing from Y"*, *"Null when sourcing
from Y"*, or a priority list over sources supplying the *same* attributes.

**Co-equal contributors** — one row draws different attributes from both, so both timelines govern it.
Signal: *"Join from A to B by <predicate>"* where the joined table is in `S₂`.

> **The rule that matters most.** A single target column sourced by a join to a second dated table makes the
> table class C — **even if every other column comes from one source, and even if the join predicate
> mentions no dates at all.** On the one confirmed instance, 22 of 23 mapped columns looked like an ordinary
> union; one column decided it.

### A fourth case the classifier must also catch

A **foreign key into another SCD-2 table** behaves like a contributor even though it is a lookup, not a
join. If the target FKs to a dimension whose ID identifies a *version*, the target must be cut at that
dimension's version boundaries too — otherwise a target row spanning a parent version change carries a
stale foreign key. See `04_worked_examples.md` §3.

---

## 4. The locked decision table — 18 rules

Every rebuilt interval is matched to the existing target row on `(business_key, row_eff_dte)`.
**The matched row's current expiry decides first. The hash only decides inside the high-end-date branch.**

Source of truth: the client's `Requirement.xlsx`, confirmed with leadership.

Each row describes what happens at **one** effective date. A run processes every effective date in the
rebuilt timeline, so one key normally triggers several of these in the same run.

| # | EFF_DATE | HASH | EXP_DATE | EXEC | ACTION | Flag |
|---|---|---|---|---|---|---|
| 1 | matches | same | same · target at 9999 | regular | do nothing | — |
| 2 | matches | same | same · target at 9999 | rerun | update UUID | `U` |
| 3 | matches | same | same · target at real date | regular | do nothing | — |
| 4 | matches | same | same · target at real date | rerun | update UUID | `U` |
| 5 | matches | same | **diff** · target at 9999 | regular | **expire in place** — update `row_exp_dte`; no retire, no `is_del`, surrogate survives — **and insert** the new version at the new effective date if the source supplies one | `U` (+`I`) |
| 6 | matches | same | **diff** · target at 9999 | rerun | as 5, + UUID | `U` (+`I`) |
| 7 | matches | same | **diff** · target at **real date** | regular | **retire** — `is_del='Y'`, both dates untouched — **+ insert** at the **same** effective date | `D`+`I` |
| 8 | matches | same | **diff** · target at **real date** | rerun | as 7, + UUID | `D`+`I` |
| 9 | matches | **diff** | same · target at 9999 | regular | **dead record** — `row_exp_dte` pulled back to its own `row_eff_dte` — **+ insert** at the same effective date | `D`+`I` |
| 10 | matches | **diff** | same · target at 9999 | rerun | as 9, + UUID | `D`+`I` |
| 11 | matches | **diff** | same · target at **real date** | regular | **retire** (`is_del='Y'`) **+ insert** at the same effective date | `D`+`I` |
| 12 | matches | **diff** | same · target at **real date** | rerun | as 11, + UUID | `D`+`I` |
| 13 | matches | **diff** | **diff** · target at 9999 | regular | **dead record + insert** at the same effective date | `D`+`I` |
| 14 | matches | **diff** | **diff** · target at 9999 | rerun | as 13, + UUID | `D`+`I` |
| 15 | matches | **diff** | **diff** · target at **real date** | regular | **retire** (`is_del='Y'`) **+ insert** at the same effective date | `D`+`I` |
| 16 | matches | **diff** | **diff** · target at **real date** | rerun | as 15, + UUID | `D`+`I` |
| 17 | **no target row at that effective date** | — | — | either | **insert** | `I` |
| 18 | **target row's effective date is gone from the rebuilt timeline** | — | — | either | **no action — the row is left live, deliberately** | — |

`execution_type` changes nothing but the UUID stamp: rows 1–16 pair up identically apart from it.

**Two kinds of insert, deliberately distinguished.** Rows 5–6 insert at a **new** effective date (which is
rule 17 firing at the next boundary). Rows 7–16 insert at the **same** effective date as the row being
retired — which is why a dead record and its replacement share an effective date.

### Why the expiry decides first

A row already closed with a **real** date was a statement published downstream — *"valid 10-Sep to 21-Sep"*
went out in a report. Changing it is a **correction**, so the old row is retired and stays visible for
traceability.

A row sitting at the **high end date** never committed to an end date; it meant *"current, end unknown"*.
Closing it is not a correction, it is the natural progression, so it is **expired in place**.

### Why the hash is needed at all

Two rows can be identical on both dates and still differ in value — a source restating a row in place. Dates
alone cannot tell them apart, and a date-only comparison would write nothing, leave the stale value in the
target, and report success.

### Why the hash covers only target-bound columns

A source column the target never carries can change without meaning anything to a consumer. Hashing it would
split the target into two identical rows.

> **And it must exclude the dates.** The hash decides the action *about* the dates, so including them makes
> the decision circular: every interval split would read as a value change. Exclude `ROW_EFF_DTE`,
> `ROW_EXP_DTE`, anything derived from them (such as a current-record indicator), and the surrogate key.

---

## 5. Two retirement mechanisms

Once the hash says a row must go, *how* it goes depends on its expiry:

| The row being retired | Mechanism | Result |
|---|---|---|
| Expiry is the **high end date** | **Dead record** — set `ROW_EXP_DTE` = that row's own `ROW_EFF_DTE` | Spans zero days, so no as-of query can return it |
| Expiry is a **real date** | **Delete indicator** — set `IS_DEL = 'Y'`, leave both dates alone | Excluded by a consumer filtering on `IS_DEL` |

A dead record is the stronger of the two: it is invisible to an as-of query **whether or not the consumer
knows to filter on a flag**. A delete indicator only works if every consumer remembers.

`IS_DEL = 'Y'` therefore fires on **any** change to a row whose expiry was already a real date, whether or
not its values moved. The `'U'` branch is the narrow one: it needs a row at the high end date whose values
did not change.

---

## 6. Two clocks, never mixed

| Clock | Column | What it is for |
|---|---|---|
| **Process time** | `GRS_REFINED_TIMESTAMP` | When the pipeline last touched the row. Used **only** to find impacted keys |
| **Business time** | `ROW_EFF_DTE` / `ROW_EXP_DTE` | When the fact was true. Used for **everything else** |

Impacted-key detection reads the process clock; the rebuild and the rule table read the business clock.
Mixing them produces a timeline cut at pipeline-run boundaries instead of at business events.

---

## 7. The apply

**One `MERGE`.** Separate `UPDATE` and `INSERT` statements are not approved by the client.

Both the `U` and `D` stage rows carry the **target row's own surrogate key**, so each update matches on one
column. Matching on `(key, eff, exp)` instead would also hit a row retired in an earlier run that happened
to cover the same interval.

```sql
-- 2a. the row sat at the high end date and its values did not change: expire in place
UPDATE <target> T
SET ROW_EXP_DTE = S.ROW_EXP_DTE, AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
FROM <stage> S
WHERE S.ACTION_FLAG = 'U' AND T.<surrogate> = S.<surrogate>;

-- 2b. retire. A real expiry means a correction (delete indicator); the high end date means a dead record
UPDATE <target> T
SET IS_DEL      = CASE WHEN T.ROW_EXP_DTE = '9999-12-31'::DATE THEN T.IS_DEL ELSE 'Y' END,
    ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = '9999-12-31'::DATE THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
    AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
FROM <stage> S
WHERE S.ACTION_FLAG = 'D' AND T.<surrogate> = S.<surrogate>;

-- 3. insert
INSERT INTO <target> (...) SELECT <seq>.NEXTVAL, ... FROM <stage> WHERE ACTION_FLAG = 'I';
```

The shipped implementation folds all three into one `MERGE`; the reference is
`../poc_v2/00_objects.sql`.

**Every action is idempotent**, which makes restart safe without depending on framework cleanup:
re-applying a `'U'` writes the value already there, re-retiring a dead record leaves it dead, and an interval
already inserted matches on the next run with the same hash and expiry, so nothing is written.

---

## 8. Snowflake specifics that have already caused defects

| | |
|---|---|
| `ERROR_ON_NONDETERMINISTIC_MERGE` defaults to **TRUE** | Two stage rows targeting one target row abort the whole MERGE. A key needing retire+insert must emit them on **different** branches, not two matches |
| A narrowing `VARCHAR` conversion **errors**, it does not truncate | `CAST(x AS VARCHAR(35))` on a longer value fails the load |
| `INSERT … VALUES` rejects general function calls | `INSERT … SELECT` does not. Prefer the `SELECT` form |
| Sequences are **not gapless** | Never assume surrogate keys are contiguous |
| `FILTER (WHERE …)` is **not supported** | Use `COUNT(CASE WHEN … THEN 1 END)`. DuckDB accepts it, Snowflake does not — so an offline harness will not catch this |

---

## 9. What the POC proved, and how

`../poc_v2/` — 69 test cases across 15 scenarios, 69 passing against Snowflake.

**Coverage is measured, not claimed.** 15 of the 18 rules emit a stage row and were observed directly in the
evidence. Rules 1, 3 and 18 emit nothing at all, so they are proved by **zero writes**, not by a visible row.

The scenarios that matter most, because they are the cases most likely to fail silently:

| | What it establishes |
|---|---|
| S01 | The core case: one source untouched, yet its target rows still have to move |
| S03 | A change in a column the target never carries writes **nothing** |
| S04 | A value returning after a different one — repeated values do not collapse |
| S05 | A gap in cover with the same value either side — gaps survive |
| S06 | A value corrected with no change to its dates — **dead records** |
| S10 | A back-dated correction — **delete-indicator** retirement, both dates untouched |
| S11 | An orphaned row stays live and untouched across five runs |
| S12 | `Z1_RERUN`, all eight variants — **and the regression guard for the defect the POC found** |
| S14 | A hash-definition change mid-pipeline — gradual migration |
