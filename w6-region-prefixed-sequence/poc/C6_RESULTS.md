# C6 — **ANSWERED: leave legacy keys alone. Backfill is actively harmful.**

**Run**: 2026-11-04 01:49 UTC. **Evidence**:
`../C6_09_c6_legacy_key_coexistence_20261104-014923.json` — 25 statements, one script defect
corrected mid-run.

| Test | Result | Verdict |
|---|---|---|
| T9.1 | Offset's smallest key 10¹⁵ vs legacy max 5,000 — **eleven orders of magnitude apart**. Concat's smallest key is `11`, itself a legacy key | **sensitivity established** |
| T9.2 | 11,000 / 11,000 / **0 duplicates** | **PASS** |
| T9.3 | All 5,000 legacy keys decode to region **0** | **SAFE — self-identifying** |
| T9.4 | **Zero misclassifications** across 11,000 rows | **PASS** |
| T9.5 | Backfill: **3,000 duplicates** | **FAILED — worse than predicted** |
| T9.6 | Concat: **999 legacy/new collisions** | **confirms C3** |

## "Leave them" is safe — and the reason is structural

Legacy keys sit strictly below 10¹⁵. Applying R13's decode rule to one returns **region 0**, which
does not exist in the mapping. **A legacy key is therefore self-identifying**: the decode returns an
impossible region rather than a plausible wrong one. That is the difference between a detectable and
a silent fault.

One predicate separates the eras with zero misclassification:

```sql
EMPLOYEE_ID >= 1000000000000000   -- prefixed; below that, legacy
```

Note it references no `ERA` column, so **it works on the real target**, where no such column exists.

## Backfill failed earlier and worse than the script predicted

We expected backfill to pass here and to collide only with *future* keys. Instead:

```
legacy key 1  ->  backfills to 1000000000000001
                  ...which a PREFIXED row ALREADY holds
```

**3,000 duplicates**, because 3,000 North America keys had been issued from sequence values 1–3,000,
overlapping the backfilled legacy range 1–5,000.

The remedy we had in mind — advance the sequence past the legacy maximum — **addresses only the
forward half**. It cannot repair the collision with keys already issued. A viable backfill would
need either doing it *before any prefixed key exists*, or re-keying the already-prefixed rows too.
That is a materially larger change than "migrate the old rows".

## Build-standard caveat

**Region code 0 must never be allocated.** The whole self-identifying property depends on legacy
keys decoding to an impossible region.

## Script defect (F33)

T9.5's correlated subquery inside `CASE` within `CREATE TABLE AS` was refused:
`Unsupported subquery type cannot be evaluated`. Rewritten as a join. Worth noting generally: the
same pattern **does** work inside UDF bodies elsewhere in this pack, so the restriction is
positional, not a blanket prohibition.
