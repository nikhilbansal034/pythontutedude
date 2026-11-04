# W6 — Region-prefixed sequence generation

Make Zone 2 surrogate keys region-qualified **at the moment they are created**, moving
Zone 1 → Zone 2, so the identifier never has to change during later global consolidation. A
reusable function takes the region name, resolves its code from a mapping table, combines it with
the sequence's next value, and the call site casts to the target column's type — so
`nextval → prefix → cast` is not reimplemented in every DTTL/ETL.

**Status.** Requirement **frozen** 2026-11-03. All **13 requirements closed** against the original
scope after **ten Snowflake runs**. Decisions D1–D5 taken, C1–C8 answered.

**The scheme is decided — D5, 2026-11-04: Scheme B, fixed-width offset.**

```
key = region_code * 10^15 + seq.NEXTVAL
```

The sequence field is fixed at 15 digits and must never change. Digit concatenation was rejected:
it satisfies uniqueness and decode only while every region code stays one digit, and it fails
legacy-key coexistence and lexical ordering regardless of region count. Slide 6 of the deck and the
head-to-head in `analysis/OPTIONS_AND_OUTCOMES.md` carry the argument.

**Still open** — none of it changes D5: `poc/scripts/12` has not been run (Q3, variable target
datatype); whether anything orders, ranges or watermarks on the surrogate key; whether R13 is a
requirement or a convenience; and the IDMC provenance mechanism, which is not a Snowflake question.

---

## Where to start

| Read | For |
|---|---|
| [`STATUS.md`](STATUS.md) | **Where each of the 13 requirements stands.** All 13 closed against the original scope |
| [`requirement.md`](requirement.md) | The requirement itself — scope, R1–R13, decisions D1–D5, open questions C1–C8, acceptance criteria, and §9's source register |
| [`requirement_deck.html`](requirement_deck.html) | **The deck.** 11 slides, mechanism-first: how a key is built, each scheme worked through, the A-vs-B head-to-head on slide 6, then the evidence and the build standard. Opens in a browser, no build step |
| [`analysis/SCHEMES_EXPLAINED.md`](analysis/SCHEMES_EXPLAINED.md) | **How the prefix schemes work, mechanism first.** Written after Nidwika asked for rationale rather than duplicate counts |
| [`analysis/OPTIONS_AND_OUTCOMES.md`](analysis/OPTIONS_AND_OUTCOMES.md) | **Every alternative tried, its measured outcome, and what the docs say** — per requirement, plus the D5 head-to-head |
| [`analysis/SCHEME_A_AND_VARCHAR.md`](analysis/SCHEME_A_AND_VARCHAR.md) | Scheme A under single-digit region codes, and how a `VARCHAR` target is handled — why the assumption did not change the decision |
| [`analysis/feasibility.md`](analysis/feasibility.md) | **The detail.** All thirteen requirements one at a time: what each asks, what the docs say, how it reads, what can be built, what needs a workaround |
| [`poc/README.md`](poc/README.md) | The POC pack — run order, what each script proves, how evidence is captured |
| [`clarifications/`](clarifications/) | The seven questions put to Nidwika, and her answers |
| [`sources/`](sources/) | The raw inputs. `requirement_region_prefixed_sequence.txt` is the baseline and wins over everything derived from it |

Snowflake behaviour cited below was read **directly** from the documentation; `requirement.md` §9
lists every page each claim traces to, and records the one conclusion a search-relayed reading got
wrong before the docs host was reachable.

## Layout

Four kinds of thing, kept apart: what was **asked for** (root), what was **reasoned**
(`analysis/`), what was **run** (`poc/`), and what it all **came from** (`sources/`,
`clarifications/`).

```
README.md                                   this file
STATUS.md                                   THE ROLLUP - where each of the 13 requirements stands
requirement.md                              scope, R1-R13, D1-D5, C1-C8, acceptance, source register
requirement_deck.html                       THE DECK - 11 slides, mechanism-first, A vs B

analysis/                                   reasoning, not runs
  feasibility.md                              per-requirement analysis against the documentation
  SCHEMES_EXPLAINED.md                        how each scheme works, mechanism before numbers
  SCHEME_A_AND_VARCHAR.md                     single-digit regions, and VARCHAR targets
  OPTIONS_AND_OUTCOMES.md                     every alternative tried, and what it measured

poc/                                        everything executed against Snowflake
  README.md                                   run order, what each script proves, capture format
  scripts/   01..12                           the SQL, numbered in the order they were run
  results/   *_RESULTS.md                     one record per run: what it established, and its limits
  evidence/  *.json, R3_evidence.docx         the raw captured output, unedited

explore/                                    DuckDB, before Snowflake
  prefix_schemes.md / .py                     C3 worked through with numbers
  r2_sequence_name_binding.py                 why a registry lookup cannot work inside a UDF
  r10_concurrency_sim.py                      14k keys, 7 parallel workers, 0 collisions

clarifications/                             the human loop
  QUESTIONS_FOR_NIDWIKA.md                    the seven questions, with why each one matters
  NIDWIKA_RESPONSES.md                        her answers, what each settles and what it reopened

sources/                                    the inputs, unmodified
  requirement_region_prefixed_sequence.txt    THE BASELINE - transcript summary
  employee_q1_zone1_to_staging.txt            Q1: Zone 1 -> STG_EMPLOYEE, leaves the key NULL
  employee_q2_staging_to_zone2_target.txt     Q2: staging -> Zone 2. Line 50 mints the key
```

**Naming.** A script, its results record and its evidence file share a number and a requirement id,
so `poc/scripts/07_r12_qualified_sequences.sql` runs to `poc/results/R12_RESULTS_v3.md` on the
evidence in `poc/evidence/R12v3_07_r12_qualified_sequences_*.json`. Nothing in `evidence/` is ever
edited — a correction goes in the results record, naming what it corrects.

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
