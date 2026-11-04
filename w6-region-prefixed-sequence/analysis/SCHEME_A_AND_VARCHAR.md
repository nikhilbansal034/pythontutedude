# Scheme A under single-digit regions, and what a VARCHAR target means

> **Outcome:** after this analysis the decision taken was **Scheme B — fixed-width offset**
> (`D5`, 2026-11-04). §5 is the recommendation that was adopted. The rest of the document is kept
> because it is the record of *why* the single-digit assumption did not change the answer.

Answering two things: **does the "regions will never exceed 9" assumption rescue Scheme A**, and
**how does a VARCHAR target column get handled**. Taking them in that order, because the second
answer depends on the first.

---

## 1. What the single-digit assumption does and does not rescue

The assumption is doing real work. If every region code is 1–9, the region field occupies **exactly
one character, always**. The split point is fixed. So:

| | Under codes 1–9 |
|---|---|
| **R12** uniqueness | **Holds.** `"1"‖"42"` and `"4"‖"2"` cannot both be `"142"` when the first field is one char. |
| **R13** decode | **Holds.** `LEFT(key, 1)` is correct for every key. |
| **C6** coexistence with legacy keys | **Does not hold.** |

That third row is the part the assumption does not touch, and it is worth being clear about because
it was a separate run, not a restatement of R12.

The first key Scheme A ever mints is region 1, sequence 1 → `"11"` → **11**. That is already an
existing `EMPLOYEE_ID` in the table. The legacy-key run measured **999 collisions with rows already
present**. Scheme A's keys start small and grow, so they walk straight up through the legacy range.
Region count is irrelevant to this; it happens with one region.

**It is fixable:** start each region's sequence above the legacy maximum, e.g. `START 1000000000`.
Then region 1's first key is `"11000000000"`.

Note what that fix did, though. It pinned the sequence field to a known minimum width — which is
the thing Scheme A was defined by *not* doing. Together with the region-code guard in §4, every
patch Scheme A needs is a hand-rebuilt piece of Scheme B's fixed-width property, held in place by
convention rather than by construction. That is the honest summary of where A stands: workable, at
the price of two permanent constraints that nothing in the database enforces for you.

## 2. The one thing to weigh before committing

"Regions will never exceed 9" is a **business commitment, not a technical property** — and R11
proved the platform happily supports adding regions, so nothing will stop a tenth from arriving.
Nine is also closer than it sounds: NA, EU, APAC, LATAM, UK, Benelux, Nordics, DACH, Iberia is
already nine.

What happens on the day a tenth region is onboarded, under A:

- New keys collide with existing region-1 keys
- **No error is raised** — the insert succeeds
- The damage is in a dimension's primary key, and it is not forensically separable afterwards,
  because nothing records whether `111` meant region 11 or region 1

Under B or C, a tenth region is a non-event. Nothing changes, because the field was already wide
enough.

So the question is not "will we exceed 9" but "what is the cost of being wrong". §4 reduces that
cost to a loud failure rather than silent corruption, and it is one line. If you go with A, that
line is not optional.

---

## 3. How Scheme A handles a VARCHAR target

Here A genuinely has an advantage: **text is its native output.** The expression is

```sql
CAST(region_code AS VARCHAR) || CAST(seq.NEXTVAL AS VARCHAR)
```

so a `VARCHAR` target needs no conversion at all, and a `NUMBER` target needs one cast. One function
serves both column types:

```sql
CREATE OR REPLACE FUNCTION key_a(region_name VARCHAR)
RETURNS VARCHAR VOLATILE
AS $$ ... $$;
```

and in Q2, at the call site, alongside the 27 casts that query already performs:

```sql
CAST(key_a($region) AS NUMBER(38,0))   -- numeric target
CAST(key_a($region) AS VARCHAR(20))    -- text target
```

**Cast at the call site, not inside the function.** The target type cannot be a UDF parameter —
`IDENTIFIER()` accepts only a literal, session variable, bind or Scripting variable, never an
argument — so the alternative is one function per base type, which multiplies the objects to deploy
and keeps the guard logic in two places. The call-site cast keeps one function and puts the type
decision in the generated SQL, where the target column's type is already known.

### Three things that behave differently because the column is text

**(a) Ordering stops agreeing with the key's magnitude.** This is the real cost of a VARCHAR target
under A, and it does not exist under a NUMBER target.

```
region 1, sequence  9  ->  "19"
region 1, sequence 10  ->  "110"

numeric intent:  19 < 110
lexical reality: "110" < "19"
```

So `MAX(EMPLOYEE_ID)` does not return the newest key, `ORDER BY EMPLOYEE_ID` is not issue order, and
`BETWEEN` does not select a contiguous block. Anything using the key as a high-water mark —
`WHERE EMPLOYEE_ID > :last_max` in an incremental or catch-up load — silently misses rows. If the
key is used only for identity and joins, this costs nothing. If anything orders or ranges on it,
this is a defect, and it is the kind that produces missing rows rather than an error.

Fixed width removes it entirely: when all keys are the same length, lexical order *is* numeric order.

**(b) The width cannot be declared on the function.** A UDF's `RETURNS VARCHAR(17)` is accepted but
the length is **ignored** — Snowflake enforces the base type at `CREATE` and discards
precision/scale/length (R6/C7). So the only place a width is enforced is the target column, and A's
width grows with the value: 2 characters at sequence 1, 13 at a trillion, up to 20 at the 64-bit
ceiling. Declare the column generously — `VARCHAR(20)` covers every value a Snowflake sequence can
produce — because the failure mode is a runtime *"String is too long and would be truncated"* years
into production.

**(c) Round-tripping through NUMBER is lossless, which is A's genuine win.** A produces no leading
zeros, so `'142'::NUMBER::VARCHAR` is `'142'` again. A zero-padded scheme does not survive that:
`'01000000000000042'::NUMBER::VARCHAR` comes back as `'1000000000000042'`, and `LEFT(key, 2)` then
reads `'10'` instead of `'01'`. If keys will cross between `VARCHAR` and `NUMBER` columns — a text
key here, a numeric FK on a child table — padding needs care and A does not.

---

## 4. If you go with A, this is the non-negotiable part

Put the region-code range into the guard the C5 run just proved, so a tenth region fails loudly
instead of corrupting silently:

```sql
CREATE OR REPLACE FUNCTION key_a(region_name VARCHAR)
RETURNS VARCHAR VOLATILE
AS $$
    (SELECT CAST(m.REGION_CODE AS VARCHAR)
       FROM region_map m
      WHERE UPPER(TRIM(m.REGION_NAME)) = UPPER(TRIM(region_name))
        AND UPPER(TRIM(m.REGION_NAME)) = UPPER(TRIM((SELECT c.VALUE
                                                       FROM deployment_config c
                                                      WHERE c.SETTING = 'REGION_NAME')))
        AND m.REGION_CODE BETWEEN 1 AND 9)          -- <<< the line that matters
    || CAST(LM_POC_DB.<home_schema>.emp_seq.NEXTVAL AS VARCHAR)
$$;
```

With `NOT NULL` on the target key column, a region code of 10 yields `NULL` yields a rejected load —
the exact mechanism that closed F35, reused. **A `CHECK` constraint will not do this job**: Snowflake
accepts `CHECK` and does not enforce it. It has to be in the function, or in whatever loads
`region_map`.

Plus the two carried from C5, unchanged: sequence by full FQN inside the body, and the function
created while the session is in its home schema.

And set each region's sequence `START` above the legacy `EMPLOYEE_ID` maximum, per §1.

---

## 5. The better suggestion

You do not have to choose between A and padding. **Scheme B, cast to text, gives a VARCHAR column
all of A's advantages and none of its costs** — under exactly the single-digit assumption you are
already making:

```sql
CAST(region_code * 1000000000000000 + seq.NEXTVAL AS VARCHAR)
--  region 1, sequence 42  ->  "1000000000000042"
```

| | A as text | B as text | C (padded text) |
|---|---|---|---|
| Unique under codes 1–9 | yes | yes | yes |
| Unique if a 10th region arrives | **no** | yes | yes |
| Width | **2–20, varies with value** | 16, constant | 17, constant |
| Lexical order = issue order | **no** | **yes** | yes |
| Decode | `LEFT(key,1)` | `LEFT(key,1)` | `LEFT(key,2)` |
| Survives a NUMBER round trip | yes | **yes** | **no** (loses the pad) |
| Collides with legacy keys | **yes, needs a START floor** | no — 16 digits is above them | no |
| Needs a region-code ≤ 9 guard | **yes** | no | no |

B-as-text wins every row that A loses and loses nothing A wins. It is also the *same expression* as
the numeric target uses, so the only thing that varies per table is the cast — one function, one
guard, one thing to deploy, and the type decision sits in Q2 next to every other cast.

That is the recommendation: **one expression, cast at the call site.** Pick the scheme once for the
whole platform rather than by target column type, and let the column type decide only the cast.

**If you still prefer A**, it is defensible — but then §4 is part of the build standard, not advice,
and point 3(a) needs a yes/no answer: does anything order, range, or watermark on the surrogate key?
If yes, A's variable width is a defect regardless of region count.

---

## 6. What is untested

The call-site-cast mechanics in §3 come from documentation and from the R6 run's finding that
declared length is ignored. `poc/scripts/12_q3_variable_target_datatype.sql` tests them directly — one
function per base type vs. cast at the call site, the VARCHAR target length, the lexical sort trap
in 3(a), and the round trip in 3(c). It has not been run. Everything in §4 is proven, having come
straight out of the C5 two-deployment run.
