# W6 — Region-prefixed sequence generation

Make Zone 2 surrogate keys region-qualified **at the moment they are created**, moving
Zone 1 → Zone 2, so the identifier never has to change during later global consolidation. A
reusable function takes a region name and a sequence name, resolves the region code from a mapping
table, combines it with the sequence's next value, and returns the key already cast to the target
column's type — so `nextval → prefix → cast` is not reimplemented in every DTTL/ETL.

**Status** — requirement being finalised. D1–D3 taken. Snowflake behaviour verified against the
docs directly: R10 turns out largely guaranteed, C2 resolved into an implementation rule, C7 found
(R6 does not work as written), C1 down to one short account test. C3–C6 await your decisions.
Nothing built.

---

## Where to start

| Read | For |
|---|---|
| [`feasibility.md`](feasibility.md) | **Start here for the detail.** All thirteen requirements, one at a time: what each asks, what Snowflake's docs say, how it reads, what can be built, what needs a workaround |
| [`requirement.md`](requirement.md) | The requirement itself. Scope, R1–R13, decisions D1–D3, open questions C1–C7, acceptance criteria |
| [`explore/prefix_schemes.md`](explore/prefix_schemes.md) | C3 worked through on evidence — concatenation vs fixed-width offset |
| [`sources/`](sources/) | The raw inputs. `requirement_region_prefixed_sequence.txt` is the baseline and wins over everything derived from it |

Snowflake behaviour cited below was read **directly** from the documentation; `requirement.md` §9
lists every page each claim traces to, and records the one conclusion a search-relayed reading got
wrong before the docs host was reachable.

## Layout

```
feasibility.md                              per-requirement analysis and verdicts
poc/
  01_r3_sequence_in_udf.sql                 THE BLOCKER - run this first
  02_r2_sequence_name_binding.sql           qualified names, registry, branch selector
  04_r10_concurrency.sql                    R10 validated thoroughly
requirement.md                              scope, R1-R13, D1-D3, C1-C7, acceptance
explore/
  prefix_schemes.md                         C3 answered with worked numbers
  prefix_schemes.py                         the runnable DuckDB demonstration
  r2_sequence_name_binding.py               R2: why a registry lookup cannot work in a UDF
  r10_concurrency_sim.py                    R10: 14k keys, 7 parallel workers, 0 collisions
sources/
  requirement_region_prefixed_sequence.txt  THE BASELINE - transcript summary
  employee_q1_zone1_to_staging.txt          Q1: Zone 1 -> STG_EMPLOYEE, leaves the key NULL
  employee_q2_staging_to_zone2_target.txt   Q2: staging -> Zone 2. Line 50 mints the key
```

The two queries are the W3-shaped two-query historical load for `EMPLOYEE` (SCD Type 2, 38 target
columns, business key `EMPLOYEE_PIN + ROW_EFFECTIVE_DATETIME`). They are the concrete example the
work has to land in, not themselves the deliverable.

---

## C1 — resolved bar one test

Snowflake's docs were read directly. The answer is more definite than either earlier note here.

**A SQL UDF cannot resolve a database object named by a parameter.** *SQL UDF limitations*:
"Dynamic SQL is not supported when referring to database objects", and the page's own failing
example is exactly this pattern — a UDF taking an object name as `VARCHAR` and reaching it via
`IDENTIFIER(param)`. So R2 cannot be met by resolving the sequence name as an identifier. That
route is closed by name.

What survives is the **branch-selector** shape — the parameter is compared as a value, every
sequence named literally — which the limitation does not touch:

```sql
CASE sequence_name WHEN 'EMPLOYEE_SEQ' THEN EMPLOYEE_SEQ.NEXTVAL
                   WHEN 'JOB_SEQ'      THEN JOB_SEQ.NEXTVAL END
```

Also confirmed, and it **reopens** an option I had written off: `TABLE(proc(…))` is explicitly
permitted in `MERGE` — the docs list "`SELECT`; `INSERT`, `UPDATE`, `DELETE`, or `MERGE`;
`CREATE TABLE AS SELECT`" — which is exactly where Q2 needs it. Whether it applies here turns on
whether consuming a sequence counts as a modifying operation, which is undocumented.

**The one untested unknown**: whether a SQL UDF body may contain `seq.NEXTVAL` at all. "sequence"
appears nowhere in *CREATE FUNCTION*, *Introduction to SQL UDFs* or *SQL UDF limitations*. One
short test settles it.

## C2 — the hazard is volatility, and I had it wrong

**This corrects an earlier claim here** that Snowflake "does not guarantee a scalar UDF is
evaluated once per row". That concern does not exist as written.

The real hazard is specific to this function: **every row passes it identical arguments**.
*CREATE FUNCTION* on `IMMUTABLE` — "This guarantee is not checked. Specifying IMMUTABLE for a UDF
that returns different values for the same input will result in undefined behavior." So an
`IMMUTABLE` version invites one surrogate key for every new row, silently. `MEMOIZABLE`, also
accepted by the SQL handler, is the same failure by another route.

`VOLATILE` is the default, so an unannotated function is correct — but declare it explicitly, and
never set the other two.

## C7 — R6 does not work the way it reads

New, and it undercuts §4's motivation. *SQL UDF limitations*: for SQL UDFs, "Precision and scale
for arguments and return values of type NUMBER" are **ignored**, and "the received value may be
used as received whether or not it conforms to constraints specified in the declaration."

So `RETURNS NUMBER(38,0)` guarantees nothing. R6 is still reachable, but the **body** must do the
`CAST` — the signature cannot. Test the returned value's actual type, not the declaration.

## R10 — largely guaranteed already, not something to prove

*Using Sequences*: "Concurrent queries never observe the same value, and values within a single
query are always distinct." The parallel-safety concern is answered for the sequence itself. What
remains is only that the wrapper does not break that guarantee — which is C2, not concurrency.

Caveats from the same page: gaps and ordering are never guaranteed, flipping the interval's sign
"may result in duplicates", and `currval` is not supported.

## What is already settled

**D1 — the signature keeps both inputs**, `function(region_name, sequence_name)`. A narrower
alternative — pass the already-generated value in, keeping `NEXTVAL` in the query — was considered
and **rejected as the primary design**. It survives only as the fallback if C1 resolves against us,
because it is the shape that works whether or not a function may reference a sequence.

**D2 — the region mapping lives in a table.** North America → 1, EU → 2, APAC → 3 today, extensible
without code change. This is what lets one deployed code base run unchanged in every environment.

**D3 — DuckDB first.** Logic, arithmetic and datatype questions answered locally before asking for
Snowflake time. `explore/prefix_schemes.py` is that work; its limits are stated in the file.

## The prefix scheme, on evidence

`explore/prefix_schemes.md` recommends **fixed-width offset** over digit concatenation. The
deciding result, reproducible with `python3 explore/prefix_schemes.py`:

```
population tested          4,389 keys (11 regions x 399 values)
CONCAT duplicate keys      99
OFFSET duplicate keys      0
```

Digit concatenation is collision-free *today* only because there are three regions with
single-digit codes. `concat(1, 23)` and `concat(12, 3)` are both `123`, so it fails **silently**
the day a tenth region is onboarded — no error, just two identities merging. Fixed-width offset
also keeps the arithmetic numeric throughout, which means §4's datatype problem never arises
rather than being centralised.

Your call, not mine — R5 and R6 stay open until you take it.

## Parked, and not blocking

Whether the physical target table also needs its own region-code **column** (§6, Abhi and team).
Explicitly separated from this work in the meeting.

## Not W3, not W4

W3 is the multi-source SCD-2 effective-date split that generates these two queries. W4 is the
generic config-driven ETL framework that runs them. W6 changes how **one value** inside the
generated Q2 is produced, plus the mapping table and function behind it.
