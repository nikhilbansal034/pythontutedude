# Incremental (Day 2+) load — instructions for DataAssist

**Audience:** the DataAssist generator. **Scope:** the incremental load only.
For Day 1 see `../dataassist/historical_load_instructions.md`. For how to behave while generating — when
to stop rather than guess — see `../dataassist/generation_rules.md`, which applies here unchanged.

> ## §0. STATUS: THREE DECISIONS ARE NOT YET CONFIRMED
>
> This file was written so the design is captured and reviewable. **Three premises below are assumptions,
> not settled facts.** Confirm each before generating production SQL from this file.
>
> | | Assumption | If it is wrong |
> |---|---|---|
> | **A1** | `AUDIT_CHANGE_HASH` covers **target-bound attributes only**, excluding `ROW_EFFECTIVE_DATETIME`, `ROW_EXPIRATION_DATETIME`, anything derived from them, and the surrogate key | The rule table's hash branch cannot work at all. **Generated code has already got this wrong once** — see `03_defects_catalogue.md` OD11 |
> | **A2** | `DELETE_INDICATOR` can be **written by the load**. On at least one real STTM it is hardcoded `'N'` | Rules 7, 11 and 15 are inoperable on that table, and roughly a third of the decision table cannot fire |
> | **A3** | Q2 may emit **two rows for one business key** in the same run — a retire and an insert | §6 and §7 need re-designing around whatever single-row shape the framework does allow |
>
> **A3 is the one most likely to force a redesign**, because the current generated Q2 shape emits exactly
> one row per business key by construction.

---

## 1. What changes from Day 1

Every simplification the historical load rests on disappears.

| | Historical | Incremental |
|---|---|---|
| Rules that can fire | **1** — insert | **18** |
| Target state | empty | populated, and the existing rows decide the action |
| Unit of work | one source row → one target row | **rebuild an impacted key's whole timeline, then diff** |
| Clocks in play | one | **two** — process and business |
| Rows written per decision | one | **up to two** — retire + insert |
| Retirement | n/a | **two mechanisms**, chosen by the existing row's expiry |
| Rerun handling | truncate and reload | `Z1_RERUN` / `RESTART` branches |
| The hash | stored, never read | **decides the action** |

> **The single most important consequence.** On Day 1 the hash is inert, so a wrong hash definition is
> invisible. On Day 2 it is the decision. Any defect in the hash that shipped with the historical load
> surfaces here, on every row, at once.

---

## 2. Pre-requisites, per table

Each failure is a **stop**, not a warning. These are in addition to the historical load's checks.

| # | Check | Why |
|---|---|---|
| P1 | The target carries a **surrogate key**, and the stage can carry the matched target row's surrogate | Every update matches on it alone — §7 |
| P2 | The target carries `ROW_EFFECTIVE_DATETIME`, `ROW_EXPIRATION_DATETIME`, `CURRENT_RECORD_INDICATOR`, `DELETE_INDICATOR` and `AUDIT_CHANGE_HASH` | The rule table reads all five |
| P3 | **`AUDIT_CHANGE_HASH` excludes both row dates and everything derived from them** (A1) | Otherwise the hash branch is circular |
| P4 | Every source carries a **process-time column** (`GRS_REFINED_TIMESTAMP` or equivalent), distinct from its business dates | Impacted-key detection — §3 |
| P5 | `DELETE_INDICATOR` is writable, not hardcoded (A2) | Rules 7, 11, 15 |
| P6 | The stage can carry an **action flag** per row | Already satisfied where staging has `CHANGE_FLAG` |
| P7 | The stage can hold **two rows for one business key** (A3) | Retire + insert |

---

## 3. Find the impacted keys — process clock only

A key is impacted if **any** contributing source touched it since the last successful run.

```sql
WITH impacted_keys AS (
    SELECT DISTINCT <business_key>
    FROM   <driving_source>
    WHERE  GRS_REFINED_TIMESTAMP > $LAST_RUN_TIMESTAMP
      AND  GRS_REFINED_TIMESTAMP <= $THIS_RUN_TIMESTAMP
    UNION
    SELECT DISTINCT d.<business_key>
    FROM   <contributing_source> c
    JOIN   <driving_source> d ON <join predicate>
    WHERE  c.GRS_REFINED_TIMESTAMP > $LAST_RUN_TIMESTAMP
      AND  c.GRS_REFINED_TIMESTAMP <= $THIS_RUN_TIMESTAMP
    -- ... one UNION branch per contributing source, and per SCD-2 parent of a foreign key
)
```

### Three rules about this step

**Never filter on the business dates here.** `ROW_EFF_DTE` and `ROW_EXP_DTE` say when a fact was true, not
when the pipeline saw it. A back-dated correction arrives today carrying last year's effective date; a
business-date filter would miss it entirely.

**Every contributor gets a branch, including a source that supplies only one column.** The whole point of
the split is that a change in *any* contributor moves the target's boundaries.

**A foreign key into an SCD-2 parent is a contributor for this purpose too.** If the parent gains a version,
every child row spanning that boundary must be rebuilt, even though no child source moved.

---

## 4. Rebuild the timeline — identical to Day 1, restricted to impacted keys

The derivation is **exactly** the historical load's, applied to the impacted keys only: collect boundaries
from every contributor, `LEAD()` into candidate intervals, resolve each by containment, collapse adjacent
identical touching intervals, drop the trailing open interval.

`../dataassist/historical_load_instructions.md` §8 is the specification. **Do not write a second
implementation.** The rebuild must be byte-identical in behaviour to Day 1's, or a key reloaded tomorrow
will differ from the same key loaded today, and every row will look changed.

Carry the rebuilt rows forward as `rebuilt`, with the full attribute set and the hash computed per A1.

---

## 5. Diff and classify — the 18 rules

Match each rebuilt interval to the existing target row on **`(business_key, ROW_EFFECTIVE_DATETIME)`**.

```sql
diff AS (
  SELECT r.*,
         t.<surrogate>            AS TGT_SURROGATE,
         t.ROW_EXPIRATION_DATETIME AS TGT_ROW_EXPIRATION_DATETIME,
         t.AUDIT_CHANGE_HASH       AS TGT_AUDIT_CHANGE_HASH,
         CASE WHEN t.<surrogate> IS NULL                                    THEN 'NO_MATCH'
              WHEN t.ROW_EXPIRATION_DATETIME >= TIMESTAMP '9999-12-31 00:00:00' THEN 'OPEN'
              ELSE 'CLOSED' END   AS TGT_EXPIRY_CLASS,
         CASE WHEN t.AUDIT_CHANGE_HASH = r.AUDIT_CHANGE_HASH THEN 'SAME' ELSE 'DIFF' END AS HASH_CLASS,
         CASE WHEN t.ROW_EXPIRATION_DATETIME = r.ROW_EXPIRATION_DATETIME THEN 'SAME' ELSE 'DIFF' END AS EXP_CLASS
  FROM rebuilt r
  LEFT JOIN <target> t
    ON  t.<business_key>          = r.<business_key>
    AND t.ROW_EFFECTIVE_DATETIME  = r.ROW_EFFECTIVE_DATETIME
)
```

### The classifier, stated as the decision table expresses it

**Read the branches in this order. The expiry decides first; the hash only decides inside the open branch.**

```sql
rule_no AS (
  SELECT d.*,
    CASE
      -- 17: nothing at this effective date
      WHEN TGT_EXPIRY_CLASS = 'NO_MATCH'                                    THEN 17

      -- 1 / 3: nothing moved
      WHEN HASH_CLASS = 'SAME' AND EXP_CLASS = 'SAME'
           AND TGT_EXPIRY_CLASS = 'OPEN'                                    THEN 1
      WHEN HASH_CLASS = 'SAME' AND EXP_CLASS = 'SAME'                       THEN 3

      -- 5: values unchanged, expiry moved, row was open -> EXPIRE IN PLACE
      WHEN HASH_CLASS = 'SAME' AND EXP_CLASS = 'DIFF'
           AND TGT_EXPIRY_CLASS = 'OPEN'                                    THEN 5

      -- 7: values unchanged, expiry moved, row was CLOSED -> correction, retire
      WHEN HASH_CLASS = 'SAME' AND EXP_CLASS = 'DIFF'                       THEN 7

      -- 9 / 13: values changed, row was open -> DEAD RECORD
      WHEN HASH_CLASS = 'DIFF' AND TGT_EXPIRY_CLASS = 'OPEN'
           AND EXP_CLASS = 'SAME'                                           THEN 9
      WHEN HASH_CLASS = 'DIFF' AND TGT_EXPIRY_CLASS = 'OPEN'                THEN 13

      -- 11 / 15: values changed, row was CLOSED -> DELETE INDICATOR
      WHEN HASH_CLASS = 'DIFF' AND EXP_CLASS = 'SAME'                       THEN 11
      ELSE                                                                       15
    END AS RULE_NO
  FROM diff d
)
```

### The rerun offset — and the defect it already caused

On `EXECUTION_TYPE = 'Z1_RERUN'`, rules 1–16 shift to their paired rerun rule, which differs only by
stamping the UUID: `1→2, 3→4, 5→6, 7→8, 9→10, 11→12, 13→14, 15→16`.

```sql
CASE WHEN $EXECUTION_TYPE = 'Z1_RERUN' AND RULE_NO BETWEEN 1 AND 16
     THEN RULE_NO + 1 ELSE RULE_NO END AS RULE_NO
```

> **The `BETWEEN 1 AND 16` is not cosmetic.** The POC's first version added 1 to *every* rule including 17,
> so a genuinely new interval classified as **18** — "this target row is gone, do nothing" — and **the
> insert was silently dropped, losing all target cover from that date onward.** It is the one real product
> defect the POC found. Scenario S12 TC03 is the regression guard.

### Rule 18 — the orphan, left live deliberately

A target row whose effective date no longer appears in the rebuilt timeline is **not** touched. It is left
live, on purpose: the rebuild covers only impacted keys and only what the sources currently say, so a
missing date may mean the source stopped reporting, not that the fact was false. Deleting on that basis
would lose history that nothing has contradicted.

Detect it, count it, do not act on it:

```sql
SELECT 'ORPHANED_TARGET_ROWS' AS CHECK_NAME, COUNT(*) AS INFORMATIONAL
FROM <target> t
WHERE t.<business_key> IN (SELECT <business_key> FROM impacted_keys)
  AND NOT EXISTS (SELECT 1 FROM rebuilt r
                  WHERE r.<business_key> = t.<business_key>
                    AND r.ROW_EFFECTIVE_DATETIME = t.ROW_EFFECTIVE_DATETIME);
```

---

## 6. The stage carries up to two rows per decision

This is where the incremental shape departs hardest from the historical one.

| Rule | Stage rows |
|---|---|
| 1, 3, 18 | **none** |
| 2, 4 | one `'U'` (UUID only) |
| 5, 6 | one `'U'` **+** one `'I'` at the **new** effective date |
| 7–16 | one `'D'` **+** one `'I'` at the **same** effective date |
| 17 | one `'I'` |

**The `'U'` and `'D'` rows carry the matched target row's surrogate key.** Not the business key, not the
dates. Matching on `(key, eff, exp)` would also hit a row retired in an *earlier* run that happened to cover
the same interval.

```sql
stage AS (
    -- the retire / update row
    SELECT TGT_SURROGATE AS <surrogate>, <business_key>,
           CASE WHEN RULE_NO IN (2,4,5,6) THEN 'U' ELSE 'D' END AS ACTION_FLAG,
           ROW_EXPIRATION_DATETIME, RULE_NO, ...
    FROM rule_no WHERE RULE_NO IN (2,4,5,6,7,8,9,10,11,12,13,14,15,16)
    UNION ALL
    -- the insert row
    SELECT NULL AS <surrogate>, <business_key>, 'I' AS ACTION_FLAG,
           ROW_EXPIRATION_DATETIME, RULE_NO, ...
    FROM rule_no WHERE RULE_NO IN (5,6,7,8,9,10,11,12,13,14,15,16,17)
)
```

---

## 7. The apply — one MERGE, and the Snowflake constraint that shapes it

The client has not approved separate `UPDATE` and `INSERT` statements. One `MERGE`.

**`ERROR_ON_NONDETERMINISTIC_MERGE` defaults to TRUE in Snowflake.** Two stage rows matching the *same*
target row abort the entire statement. The retire-plus-insert pair is safe **only because the `'I'` row
carries a NULL surrogate and therefore matches nothing** — it falls to `WHEN NOT MATCHED`. Preserve that
property exactly; do not "improve" the merge key.

```sql
MERGE INTO <target> T
USING stage S
   ON T.<surrogate> = S.<surrogate>          -- 'I' rows carry NULL and match nothing

WHEN MATCHED AND S.ACTION_FLAG = 'U' THEN UPDATE SET
    T.ROW_EXPIRATION_DATETIME = S.ROW_EXPIRATION_DATETIME,
    T.CURRENT_RECORD_INDICATOR = CASE WHEN S.ROW_EXPIRATION_DATETIME
                                           >= TIMESTAMP '9999-12-31 00:00:00' THEN 'Y' ELSE 'N' END,
    T.AUDIT_UPDATE_DATETIME   = CURRENT_TIMESTAMP()

WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
    T.DELETE_INDICATOR         = CASE WHEN T.ROW_EXPIRATION_DATETIME
                                           >= TIMESTAMP '9999-12-31 00:00:00'
                                      THEN T.DELETE_INDICATOR ELSE 'Y' END,
    T.ROW_EXPIRATION_DATETIME  = CASE WHEN T.ROW_EXPIRATION_DATETIME
                                           >= TIMESTAMP '9999-12-31 00:00:00'
                                      THEN T.ROW_EFFECTIVE_DATETIME ELSE T.ROW_EXPIRATION_DATETIME END,
    T.CURRENT_RECORD_INDICATOR = 'N',
    T.AUDIT_UPDATE_DATETIME    = CURRENT_TIMESTAMP()

WHEN NOT MATCHED THEN INSERT (...) VALUES (<seq>.NEXTVAL, ...);
```

**The two retirement mechanisms are one `CASE` each**, keyed on the target row's *existing* expiry — not on
anything the stage carries. That is what makes rule 9 and rule 11 differ without the classifier having to
decide between them twice.

**Every action is idempotent.** Re-applying a `'U'` writes the value already there; re-retiring a dead
record leaves it dead; an interval already inserted matches next run with the same hash and expiry and falls
to rule 1 or 3. This is what makes restart safe without depending on framework cleanup.

---

## 8. Execution types

| `EXECUTION_TYPE` | Behaviour |
|---|---|
| `REGULAR` | As above |
| `Z1_RERUN` | Rules 1–16 shift by +1 (§5). **Never 17 or 18** |
| `RESTART` | A failed run processed nothing, so the restart runs the same window again. Idempotency (§7) makes this safe with no special branch |

---

## 9. What DataAssist must change from its current Q2 shape

The generated Q2 today is an IDMC-style `SELECT` emitting `DD_CHANGE_FLAG`: `0` insert, `1` update, `3`
reject. **Three things about it are correct for Day 1 and wrong for Day 2.**

| | Today | Required |
|---|---|---|
| **`DD_CHANGE_FLAG = 1`** | update in place | **Retire + insert.** An update-in-place on an SCD-2 target overwrites history — the one thing the target exists to prevent. This is the `upd` wording that was struck from the requirement precisely because it reads as update-in-place when it means retire-and-replace |
| **One row per business key** | guaranteed by a closing `QUALIFY ROW_NUMBER() … = 1` | **Up to two** — a retire and an insert. The guarantee must be re-keyed on `(business key, effective date, action flag)`, or the retire and the insert will collapse into one |
| **Change detection on the whole hash** | includes the row dates | **Attributes only.** With the dates inside, every interval split reads as a value change (A1) |

**And one thing that must newly happen in Q2 at all:** the foreign-key boundary split must run on the
incremental load too. A parent gaining a version impacts every child row spanning that boundary, even when
no child source moved — which is why §3 lists SCD-2 parents as contributors for impacted-key detection.

---

## 10. Self-check assertions

Emit all of these. **Every one must return zero**, and a non-zero result is a stop, not a warning.

```sql
-- 1. No key may end up with two live rows at one effective date.
SELECT 'DUPLICATE_LIVE_KEY_EFF' AS CHECK_NAME, COUNT(*) AS FAILURES FROM (
  SELECT <business_key>, ROW_EFFECTIVE_DATETIME FROM <target>
  WHERE DELETE_INDICATOR = 'N' AND ROW_EXPIRATION_DATETIME > ROW_EFFECTIVE_DATETIME
  GROUP BY 1,2 HAVING COUNT(*) > 1);

-- 2. No live interval overlaps another for the same key.
SELECT 'OVERLAPPING_LIVE_INTERVALS', COUNT(*) FROM <target> a JOIN <target> b
  ON a.<business_key> = b.<business_key>
 AND a.ROW_EFFECTIVE_DATETIME < b.ROW_EFFECTIVE_DATETIME
 AND b.ROW_EFFECTIVE_DATETIME < a.ROW_EXPIRATION_DATETIME
WHERE a.DELETE_INDICATOR = 'N' AND b.DELETE_INDICATOR = 'N'
  AND a.ROW_EXPIRATION_DATETIME > a.ROW_EFFECTIVE_DATETIME
  AND b.ROW_EXPIRATION_DATETIME > b.ROW_EFFECTIVE_DATETIME;

-- 3. At most one open-ended live row per key.
SELECT 'OPEN_ENDED_COUNT', COUNT(*) FROM (
  SELECT <business_key> FROM <target>
  WHERE ROW_EXPIRATION_DATETIME >= TIMESTAMP '9999-12-31 00:00:00' AND DELETE_INDICATOR = 'N'
  GROUP BY 1 HAVING COUNT(*) > 1);

-- 4. CURRENT_RECORD_INDICATOR always agrees with the expiry.
SELECT 'CURRENT_IND_MISMATCH', COUNT(*) FROM <target>
WHERE CURRENT_RECORD_INDICATOR <> CASE WHEN ROW_EXPIRATION_DATETIME
       >= TIMESTAMP '9999-12-31 00:00:00' THEN 'Y' ELSE 'N' END;

-- 5. Every 'D' and 'U' stage row carries a surrogate; every 'I' row carries none.
SELECT 'BAD_STAGE_SURROGATE', COUNT(*) FROM stage
WHERE (ACTION_FLAG IN ('D','U') AND <surrogate> IS NULL)
   OR (ACTION_FLAG = 'I'        AND <surrogate> IS NOT NULL);

-- 6. The rerun offset never reaches 17 or 18. Guards the defect the POC found.
SELECT 'RERUN_OFFSET_ESCAPED', COUNT(*) FROM rule_no WHERE RULE_NO = 18 AND $EXECUTION_TYPE = 'Z1_RERUN';

-- 7. Nothing was lost between the rebuild and the stage.
SELECT 'REBUILD_TO_STAGE_LOSS',
       (SELECT COUNT(*) FROM rule_no WHERE RULE_NO NOT IN (1,3,18))
     - (SELECT COUNT(DISTINCT <business_key> || '~' || ROW_EFFECTIVE_DATETIME) FROM stage);

-- 8. Only impacted keys were touched.
SELECT 'UNIMPACTED_KEY_TOUCHED', COUNT(*) FROM <target>
WHERE AUDIT_UPDATE_DATETIME >= $RUN_START
  AND <business_key> NOT IN (SELECT <business_key> FROM impacted_keys);
```

> **Checks 1–4 run against the TARGET, after the apply** — not against staging. Checks that run only on
> staging cannot see what the merge actually wrote, and every defect found in four generated assets reached
> human review rather than failing at run time for exactly that reason.

---

## 11. Worked example — one key, one run

Target before the run, broker `B1`:

| SK | eff | exp | status | tier | hash | is_del |
|---|---|---|---|---|---|---|
| 101 | 2024-01-01 | 2024-06-01 | `ACTIVE` | `GOLD` | `h1` | N |
| 102 | 2024-06-01 | 9999-12-31 | `REVIEW` | `GOLD` | `h2` | N |

Overnight, source B restates the tier from `2024-03-15`: `GOLD` → `SILVER`. The rebuild gives:

| eff | exp | status | tier | hash |
|---|---|---|---|---|
| 2024-01-01 | 2024-03-15 | `ACTIVE` | `GOLD` | `h1` |
| 2024-03-15 | 2024-06-01 | `ACTIVE` | `SILVER` | `h3` |
| 2024-06-01 | 9999-12-31 | `REVIEW` | `SILVER` | `h4` |

Matching on `(key, eff)`:

| rebuilt eff | target row | hash | expiry | rule | why | stage |
|---|---|---|---|---|---|---|
| 2024-01-01 | SK 101, closed 06-01 | **same** `h1` | **diff** (06-01 → 03-15) | **7** | values unchanged but the row was **closed** — a published statement, so it is a correction | `D` on 101 + `I` |
| 2024-03-15 | *none* | — | — | **17** | new boundary | `I` |
| 2024-06-01 | SK 102, open | **diff** `h2`→`h4` | same | **9** | values changed and the row was **open** — dead record | `D` on 102 + `I` |

After the apply:

| SK | eff | exp | status | tier | is_del | note |
|---|---|---|---|---|---|---|
| 101 | 2024-01-01 | 2024-06-01 | `ACTIVE` | `GOLD` | **Y** | retired by delete indicator, dates untouched, visible for traceability |
| 102 | 2024-06-01 | **2024-06-01** | `REVIEW` | `GOLD` | N | **dead record** — spans zero days, invisible to an as-of query |
| 103 | 2024-01-01 | 2024-03-15 | `ACTIVE` | `GOLD` | N | new |
| 104 | 2024-03-15 | 2024-06-01 | `ACTIVE` | `SILVER` | N | new |
| 105 | 2024-06-01 | 9999-12-31 | `REVIEW` | `SILVER` | N | new |

**Three things to take from this.**

The two retired rows went by **different mechanisms**, decided by their own expiries, not by what changed.
SK 101 was closed so it is a correction; SK 102 was open so closing it is natural progression — but its
*values* also changed, which is what makes it a dead record rather than an expire-in-place.

**Rule 7 fired on a row whose hash was unchanged.** The values never moved; only the boundary did. A
hash-only comparison would have written nothing.

**The target grew from 2 rows to 5, of which 3 are live.** Retired rows are not deleted. Any consumer
reading this table must filter `DELETE_INDICATOR = 'N'` **and** exclude zero-width intervals — see
`../solution_design.md` §14.
