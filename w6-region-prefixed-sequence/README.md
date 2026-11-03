# W6 — Region-prefixed sequence generation

Make Zone 2 surrogate keys region-qualified **at the moment they are created**, moving
Zone 1 → Zone 2, so the identifier never has to change during later global consolidation. A
reusable function takes a region name and a sequence name, resolves the region code from a mapping
table, combines it with the sequence's next value, and returns the key already cast to the target
column's type — so `nextval → prefix → cast` is not reimplemented in every DTTL/ETL.

**Status** — requirement being finalised. Decisions D1–D3 taken; C1–C6 open, and C1 can change the
shape of the solution. Nothing built, nothing tested in Snowflake.

---

## Where to start

| Read | For |
|---|---|
| [`requirement.md`](requirement.md) | **The requirement.** Scope, R1–R13, decisions D1–D3, open questions C1–C6, acceptance criteria |
| [`explore/prefix_schemes.md`](explore/prefix_schemes.md) | C3 worked through on evidence — concatenation vs fixed-width offset |
| [`sources/`](sources/) | The raw inputs. `requirement_region_prefixed_sequence.txt` is the baseline and wins over everything derived from it |

## Layout

```
requirement.md                              scope, R1-R13, D1-D3, C1-C6, acceptance
explore/
  prefix_schemes.md                         C3 answered with worked numbers
  prefix_schemes.py                         the runnable DuckDB demonstration
sources/
  requirement_region_prefixed_sequence.txt  THE BASELINE - transcript summary
  employee_q1_zone1_to_staging.txt          Q1: Zone 1 -> STG_EMPLOYEE, leaves the key NULL
  employee_q2_staging_to_zone2_target.txt   Q2: staging -> Zone 2. Line 50 mints the key
```

The two queries are the W3-shaped two-query historical load for `EMPLOYEE` (SCD Type 2, 38 target
columns, business key `EMPLOYEE_PIN + ROW_EFFECTIVE_DATETIME`). They are the concrete example the
work has to land in, not themselves the deliverable.

---

## The two things that decide whether this design works

**C1 — can a Snowflake function take a sequence *name* and return that sequence's next value?**
Unverified, and everything rests on it. An object name cannot be parameterised in static SQL, so a
runtime sequence name needs dynamic SQL; a SQL UDF body is a single static expression; JavaScript
and Python UDFs cannot execute SQL at all; and a stored procedure, which can, is not callable
inside a `SELECT` or `MERGE` projection — which is exactly where the key is minted. If that
reasoning holds, **R2 as worded cannot be met by anything inline-callable** and the requirement
changes, not the implementation. `requirement.md` §5 lists the three ways out in the order to try
them. Settle this before building anything.

**C2 — how many times is a scalar UDF invoked per row?** Snowflake does not guarantee exactly once.
Harmless for a pure function; a correctness bug for one that consumes a sequence. The R10 test has
to count invocations, not just check for duplicate keys.

Neither can be answered from this session: `docs.snowflake.com` is outside its allowed network
domains, and web sources were inconclusive. Both need Snowflake account access or that host
allowed.

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
