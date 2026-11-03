# R3 — RESULT: **PASS**. A Snowflake SQL UDF body may contain `seq.NEXTVAL`.

**Run**: 2026-11-03, by Nikhil Bansal, in `LM_POC_DB.POC_SCHEMA`.
**Evidence**: `../R3_evidence.docx` — seven screenshots, one per statement.
**Script**: `01_r3_sequence_in_udf.sql`.

**G2 closes. The blocker is cleared, and the branch-selector design in D1 is viable.**

---

## Results

| Test | What it checked | Result | Verdict |
|---|---|---|---|
| T1.1 | Baseline — `NEXTVAL` works outside any function | returned `1` | **PASS** |
| T1.2 | Does the UDF **create** with a sequence in its body? | "Function W6_SEQ_IN_UDF successfully created." | **PASS** |
| T1.3 | **Decisive** — distinct value per row, 10 rows | 10 distinct: `101`–`110` | **PASS** |
| T1.4 | Machine-checked, 100 rows | 100 rows / 100 distinct / **0 duplicates**, min `201`, max `300` | **PASS** |
| T1.5 | Consumption after 100 rows | returned `2` — see below, **the test was wrong, not the result** | n/a |
| T1.6 | Inside a `MERGE` projection, mirroring Q2 line 50 | 3 rows inserted, 3 distinct IDs | **PASS** |

The outcome that mattered most was T1.3's trap case — 10 *identical* values would have meant the body
was folded to a constant, a silent failure that T1.2 passing would have masked. It did not happen:
ten distinct values came back.

## Invocation count: exactly one per row

T1.4 is the real measure. 100 rows produced 100 distinct keys spanning **exactly** `201`–`300` —
a span of 100 for 100 rows, with no gaps inside it. Had the UDF been invoked twice per row, 200
values would have been consumed and the span would have been roughly double. So on this plan the
function runs **once per row**, which is what R10 needs.

*Caveat*: one plan, one warehouse size, 100 rows. Re-check at production volume as part of
`04_r10_concurrency.sql` rather than treating this as settled for all plans.

## T1.5 returned `2`, and my test was built on a false assumption

Observed order of generated values across the session:

```
T1.1  direct NEXTVAL        -> 1
T1.3  UDF, 10 rows          -> 101 .. 110
T1.4  UDF, 100 rows         -> 201 .. 300
T1.5  direct NEXTVAL        -> 2          <- looks wrong, is not
```

`01_r3_sequence_in_udf.sql` expected T1.5 to come back "roughly 100 ahead of T1.4's max_key". That
expectation assumed a sequence is a single monotonic counter. **It is not**, and Snowflake documents
the exact behaviour observed:

> **NOORDER** specifies that the values are not guaranteed to be in increasing order. For example,
> if a sequence has `START 1 INCREMENT 2`, the generated values might be **`1`, `3`, `101`, `5`,
> `103`**, etc.
> — *CREATE SEQUENCE*

The documentation's own illustration is the pattern seen here: a low value, a jump to a high block,
then back to a low value. The default is set by the account parameter
**`NOORDER_SEQUENCE_AS_DEFAULT`**, so `CREATE SEQUENCE … START 1 INCREMENT 1` picked up NOORDER in
this account.

**This is a correction to the test, not a finding against the design.** T1.5 as written cannot
measure consumption, because direct and UDF-path calls draw from different reserved ranges. The
script has been fixed to say so and to point at T1.4 as the real measure.

### Why NOORDER is the behaviour we want

Three consequences, all favourable:

1. **R10 benefits.** The docs: "NOORDER can improve performance when multiple INSERT operations are
   performed concurrently (for example, when multiple clients are executing multiple INSERT
   statements)." That is exactly W6's parallel-load scenario.
2. **Uniqueness is untouched.** NOORDER weakens *ordering*, never uniqueness — "Concurrent queries
   never observe the same value." A surrogate key needs uniqueness, not monotonicity.
3. **Gaps are larger than anyone will expect.** The `101`–`200` range was reserved and only ten
   values used; ninety were burned. Anything downstream that reads a key as a row count, or a
   missing key as a lost row, is wrong — and wrong by a wide margin, not by a rounding error.

**Carry into the build standard**: do not specify `ORDER` on these sequences to "tidy up" the keys.
It would cost concurrent-load performance to buy a property the design does not need.

## What this closes, and what it does not

**Closes** — R3, and with it G2. Also confirms R1's call site works in a real `MERGE` (T1.6), and
gives R10 its per-row invocation evidence.

**Does not close** — still open and unchanged by this run:

| | Where |
|---|---|
| Does the branch selector work, and do untaken `CASE` arms consume values? | `02_r2_sequence_name_binding.sql` |
| Does a body-level `CAST` deliver the declared type, given the declaration is ignored? | R6 / C7 — script still to write |
| Does the guarantee hold through the wrapper under real concurrency, and do `IMMUTABLE`/`MEMOIZABLE` fold? | `04_r10_concurrency.sql` |

Note that T1.2's function was declared `VOLATILE` explicitly, as the build rule requires. The
`IMMUTABLE` and `MEMOIZABLE` negative tests are deliberately **not** part of this run.
