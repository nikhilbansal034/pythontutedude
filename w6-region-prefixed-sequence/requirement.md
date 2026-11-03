# W6 — Region-prefixed sequence generation — requirement

**Status**: **FROZEN** as of 2026-11-03. Decisions D1–D4 taken; C8 answered. The thirteen
requirements are grouped into five tracking groups (below).

**R2, R3, R6, R10 and R13 are PROVEN in Snowflake** (2026-11-03) — see `poc/R*_RESULTS.md`.

**R12 remains open after three attempts**, and the third was the most informative:

- `poc/04` T4.7 — vacuous: one sequence shared by all regions.
- `poc/05` T5.2 — vacuous: three per-region sequences moved in lockstep, because one function body
  named all three (R2's F4 at function scope).
- `poc/06` T6.1 — **halted at its own sensitivity gate**, and in doing so refuted a design assumption:
  an **unqualified SEQUENCE inside a UDF body resolves in the CALLER'S current schema**, while a table
  in the same body resolves in the function's schema. This contradicts Snowflake's *Name resolution*
  page ("All unqualified objects in a view or UDF definition will be resolved in the view's or UDF's
  schema only") and **reverses R8's build-standard decision**: the sequence reference must be **fully
  qualified**. See `poc/R12_RESULTS_v2.md`.

`poc/07_r12_qualified_sequences.sql` fully qualifies the sequence, adds a regression test for the
asymmetry (T7.0) and a caller-schema-independence test (T7.2), and keeps the sensitivity gates.

**R3 is PROVEN and G2 is CLOSED** — tested in Snowflake on 2026-11-03, all six tests passed. A SQL
UDF body *may* contain `seq.NEXTVAL`, it returns one distinct value per row, and it works inside a
`MERGE` projection. Results and the NOORDER finding: [`poc/R3_RESULTS.md`](poc/R3_RESULTS.md);
evidence: [`R3_evidence.docx`](R3_evidence.docx). The blocker is gone — eight of thirteen
requirements now close, and C3–C6 remain open decisions that do not reopen the requirement.

**Deck**: [`requirement_deck.html`](requirement_deck.html) — 12 slides, the frozen requirement as
presented. **Per-requirement analysis**: [`feasibility.md`](feasibility.md).

**Baseline**: `sources/requirement_region_prefixed_sequence.txt` — the transcript summary of the
*[Internal] TD MOD — US/USI Daily Connect*. Where this document and the transcript disagree, the
transcript wins and this document is wrong.

---

## 1. Problem

Zone 2 surrogate keys are currently minted from a plain Snowflake sequence, so each region
generates the same low integers — `1, 2, 3, …`. When regions are later consolidated into the
global database, the region has to be mixed into the identifier to keep rows apart. Doing it there
means the global identifier **no longer matches what Zone 2 stored**, so tracing a record back
needs the UUID, or logic to strip the prefix before comparing.

The fix is to make the key region-qualified **at the moment it is created**, moving Zone 1 → Zone 2,
so the identifier never changes afterwards. Cindy MacFarlane's stated preference, per §3.

A second, independent problem: prefixing a region code to a sequence value in Snowflake
**changes the datatype** and needs an explicit cast back (§4). Left to each ETL, the
`nextval → prefix → cast` sequence gets reimplemented — and mis-implemented — per table.

## 2. Scope

**In scope** — a reusable callable that mints region-qualified surrogate keys, the region
name → region code mapping table behind it, and the change to the Zone 1 → Zone 2 ETL that calls it.

**Out of scope** — whether the physical target table also needs a separate region-code *column*.
Parked with Abhi and team per §6, and explicitly must not block this work.

**Not in scope, stated to avoid doubt** — the existing SCD-2 split logic, change-flag derivation,
and the two-query load shape. W6 changes how one value is produced, nothing else.

---

## 3. Requirements

| # | Requirement | Source |
|---|---|---|
| R1 | The ETL stops calling `<seq>.NEXTVAL` directly and calls a reusable function instead | §1 |
| R2 | The function signature takes **region name** and **sequence name** — `function(region_name, sequence_name)` | §1, **D1** |
| R3 | The function gets the next value from the named sequence | §1 |
| R4 | The function resolves the region **code** from the region **name** passed to it | §1, §2 |
| R5 | The function combines the region code with the sequence value | §1 |
| R6 | The function returns the value in the datatype the target key column expects; the cast happens inside the function, not in each ETL | §1, §4 |
| R7 | Region name → region code lives in a **mapping table**, not in the function body and not in the ETL | §2 |
| R8 | One code base, unchanged across environments; the region name is an input, never hard-coded | §2 |
| R9 | The key is region-qualified while moving **Zone 1 → Zone 2**, not at Zone 2 → Zone 3 consolidation | §3 |
| R10 | The function must be correct when **called concurrently by multiple tables** | §5 |
| R11 | Region codes allocated today: North America → 1, EU → 2, APAC → 3. The mapping must accommodate further regions without code change | §2 |
| R12 | *(derived)* Every key issued must be unique across all regions, for all time, under any future region count. A surrogate key is a primary key | implied by §3 |
| R13 | *(derived)* The region must be recoverable from the key without consulting another table, or §3's traceability goal is not met | implied by §3 |

R12 and R13 are not in the transcript. They are the properties §3's traceability argument depends
on, written down so the prefix scheme can be judged against them. **Flag them for confirmation.**

### Tracking groups

The thirteen are tracked as five groups, each sharing a single closing condition, so progress reads
at group level rather than as thirteen separate threads.

| Grp | Group | Holds | What closes it | Status |
|---|---|---|---|---|
| **G1** | Function interface & contract | R1, R2, R6 | **CLOSED — proven 2026-11-03** (branch selector + body cast) | Closed |
| **G2** | Sequence access | R3 | One short Snowflake test | **CLOSED — proven 2026-11-03** |
| **G3** | Region configuration | R4, R7, R8, R11 | R4/R7/R11 closed; **R8 needs re-confirming** — unqualified sequences follow the caller, so the body must be fully qualified | Open |
| **G4** | Key composition & integrity | R5, R12, R13 | R13 proven; **R12 still open** — `poc/06`; plus decision C3 | Open |
| **G5** | Placement & concurrency | R9, R10 | **CLOSED — 90,000 keys, 0 duplicates, measured overlap** | Closed |

G2 stood alone because nothing else could be built until it was answered. **It now is**: R3 passed
in Snowflake on 2026-11-03, so G2 is closed and the branch-selector design in D1 is viable.

---

## 4. Decisions taken

**D1 — the signature keeps both inputs.** `function(region_name, sequence_name)`. Confirmed by
Nikhil Bansal. A narrower alternative was considered — pass the already-generated sequence value
in, `f(region_name, seq_value)`, keeping `NEXTVAL` in the query — and **rejected as the primary
design**. It is retained only as the fallback if C1 resolves against us, because it is the shape
that survives if a function cannot reference a sequence.

**D2 — mapping lives in a table.** Not in the function, not in the ETL, not in an environment
variable. Satisfies R7 and R8 together: the same deployed code behaves correctly in every
environment because the region arrives as an argument and the code is looked up at run time.

**D4 — each table has its own sequence, per region.** Confirmed by Nikhil Bansal, answering C8.
Every region runs its own Zone 2 with its own `EMPLOYEE_SEQ`, `JOB_SEQ` and so on, each starting at
1. **Consequence**: the region prefix is **load-bearing for integrity**, not merely traceability —
it is the only thing keeping North America's employee 1 apart from EU's. Measured in
`explore/r10_concurrency_sim.py` §7: 6,000 of 9,000 keys collide with no prefix at all. This raises
what is at stake in C3 considerably.

**D3 — simulate in DuckDB first.** Logic, arithmetic and datatype questions get answered locally
before asking for Snowflake time. See `explore/prefix_schemes.py`. The limitation is explicit:
DuckDB cannot answer C1 or C2, which are the blocking ones.

---

## 5. Findings and open questions

Ordered by how much they can change the design. C1's remaining test should be run before any
build. One requirement turns out to be **already guaranteed**, and one turns out **not to work as
written** (C7).

### Resolved — C8: one sequence per table, per region

**Answered by Nikhil Bansal: each table has its own sequence.** Combined with each region running
its own Zone 2, every region's `EMPLOYEE_SEQ` starts at 1. Recorded as **D4**. The prefix therefore
carries **integrity**, not just traceability, which is why C3's scheme choice is not cosmetic.

### Resolved — R10's parallel safety is largely guaranteed, not something to prove

*Using Sequences* states it outright:

> All values generated by a sequence are globally unique as long as the sign of the sequence
> interval does not change (e.g. by changing the step size). **Concurrent queries never observe
> the same value, and values within a single query are always distinct.**

So the concern behind R10 — multiple tables calling this concurrently and colliding — is answered
for the **sequence itself** by documentation. What remains to test is narrower and worth stating
precisely: that the *function wrapping it* does not break a guarantee the sequence already
provides, which is C2's volatility question, not a concurrency question.

Three caveats the same page attaches, all worth recording:

- changing the interval's sign "may result in duplicates" — so the sequence's `INCREMENT` must
  never be flipped once keys are issued
- "There is no guarantee that values from a sequence are contiguous (gap-free) or that the sequence
  values are assigned in a particular order" — gaps are expected and must not be treated as loss
- `currval` is **not supported** in Snowflake, so nothing may be built on reading back the last
  issued value

### C1 — Can a Snowflake function take a sequence *name* and return that sequence's next value?

> **RESOLVED 2026-11-03 — YES.** The one untested unknown below (may a SQL UDF body contain
> `seq.NEXTVAL`?) was tested in Snowflake and **passed**: the function created, returned 100
> distinct keys for 100 rows with zero duplicates, and worked inside a `MERGE` projection. See
> [`poc/R3_RESULTS.md`](poc/R3_RESULTS.md). The analysis below stands as written; only its final
> open question is now answered, in the affirmative.

**Resolved, except for one test.** Snowflake's docs were read directly (see §9), and the answer is
more definite than either earlier draft of this section.

**A SQL UDF cannot resolve a database object named by a parameter.** From *SQL UDF limitations*:

> **Dynamic SQL is not supported when referring to database objects.** Referring to database
> objects using dynamic SQL will produce an error that includes text such as the following:
> `Compilation of SQL UDF failed: SQL compilation error: syntax error... unexpected
> '<variable_name>'` […] If you need to construct dynamic SQL statements that use different
> database objects, consider writing a stored procedure instead.

The page's own failing example is this exact pattern — a UDF taking an object name as a `VARCHAR`
argument and reaching it through `IDENTIFIER(table_name_parameter)`. So the first draft's instinct
was right and the second draft's hedge was unnecessary: **R2 cannot be satisfied by resolving the
sequence name as an identifier.** That route is closed, officially and by name.

What survives is the **branch-selector** route, which this limitation does not touch, because the
parameter is compared as a *value* and every sequence is named literally:

```sql
CASE sequence_name
    WHEN 'EMPLOYEE_SEQ' THEN EMPLOYEE_SEQ.NEXTVAL
    WHEN 'JOB_SEQ'      THEN JOB_SEQ.NEXTVAL
END
```

Ways out, re-ranked on what the docs now confirm:

1. **UDF with a static `CASE` over known sequences** — the only inline-callable shape that keeps
   the literal `(region_name, sequence_name)` signature. Needs no dynamic SQL.
   **Evidenced caveat**: *Using Sequences* states "Each occurrence of a sequence generates a set of
   distinct values. This is different from what many other databases provide, where multiple
   references to NEXTVAL of a sequence return the same value for each row." So a `CASE` naming
   several sequences may consume a value from branches not taken. Tolerable — gaps are never
   guaranteed — but it must be measured, and it argues for one function per sequence if the branch
   count grows.
2. **Stored procedure called as `TABLE(proc(…))` in the `MERGE` source** — **upgraded, and an
   earlier draft of this document was wrong to call this closed for `MERGE`.** *Selecting from a
   stored procedure* states the procedure "must be called in the `FROM` clause of a `SELECT` block
   in one of the following statements: `SELECT`; `INSERT`, `UPDATE`, `DELETE`, or `MERGE`;
   `CREATE TABLE AS SELECT`". `MERGE` is explicitly on that list, which is exactly where Q2 needs
   it. Two constraints decide whether it actually works: only procedures performing
   "SELECT, SHOW, DESCRIBE, or CALL" are allowed and those "that make modifications using DDL or
   DML operations aren't allowed" — **so the open question is whether consuming a sequence counts
   as a modification**, which the docs do not say; and the procedure must return tabular data with
   a static, named, typed schema. Note that a `CALL` still "cannot be used as part of an
   expression", so this works only through `TABLE(…)`, never in the projection.
3. **Fall back to `f(region_name, seq_value)`** with `NEXTVAL` in the query — D1's rejected
   alternative, still the shape that works whatever C1 turns out to be.

**The one remaining untested unknown**: whether a SQL UDF body may contain `seq.NEXTVAL` at all.
The word "sequence" appears **nowhere** in *CREATE FUNCTION*, *Introduction to SQL UDFs*, or
*SQL UDF limitations*, and *Using Sequences* never mentions UDFs. It is not excluded by the
DDL/DML prohibition, since consuming a sequence is neither. One short test in the account settles
it, and it decides between option 1 and options 2–3.

### C2 — Volatility, not invocation count

**This supersedes an earlier version of C2 that was wrong.** It claimed Snowflake "does not
guarantee a scalar UDF is evaluated exactly once per row". That was overstated; the concern as
written does not exist. The real hazard is volatility, and it is now confirmed verbatim from
*CREATE FUNCTION*:

> **VOLATILE**: UDF might return different values for different rows, even for the same input
> (e.g. due to non-determinism and statefulness).
> **IMMUTABLE**: UDF assumes that the function, when called with the same inputs, will always
> return the same result. **This guarantee is not checked.** Specifying IMMUTABLE for a UDF that
> returns different values for the same input will result in **undefined behavior**.
> Default: VOLATILE

**Every row passes this function identical arguments** — the same region name and sequence name
for the whole statement. So an `IMMUTABLE` region-prefixed sequence UDF invites Snowflake to hand
every new row the same surrogate key, with no error raised. `VOLATILE` is the default, so an
unannotated function is correct, but it is a one-word footgun for whoever later adds `IMMUTABLE`
as a performance tweak.

**`MEMOIZABLE` is a second footgun.** The *CREATE FUNCTION* SQL-handler syntax accepts
`[ MEMOIZABLE ]` alongside the volatility keyword. A memoized result is the same failure by a
different route. It must never be set on this function.

**Therefore**: declare `VOLATILE` explicitly with a comment saying why, never `IMMUTABLE` or
`MEMOIZABLE`, and assert that N input rows receive N distinct keys. W3 recorded the adjacent trap
— calling `NEXTVAL` twice on one row and assuming one value — in
`w3-scd-effective-date-split/poc_v2/scenarios/S14.sql`; "each occurrence of a sequence generates a
set of distinct values" confirms it.

### C3 — Which prefix scheme, and what datatype? *(R5, R6, R12, R13)*

Two candidates, explored with worked numbers in `explore/prefix_schemes.md`. On the evidence
there, **fixed-width offset is the stronger option** and digit concatenation has a latent
duplicate-key defect. Needs your decision, not mine.

If fixed-width offset is chosen, the sequence field width must be **fixed once and never
changed** — changing it renumbers every key ever issued. Pin it in this document.

**Confirmed constraint on the sequence half.** *Using Sequences*: "A sequence value can represent a
64-bit two's complement integer (-2^63 to 2^63 - 1). If the internal representation of a
sequence's next value exceeds this range (in either direction) an error results and the query
fails." The 18-digit field used in `explore/` sits just under that ceiling (10^18 against
~9.22×10^18), so it is sound — but it is near the boundary, and the limit applies to the
sequence's *internal* next value, which gaps can push ahead of the values actually returned.

### C4 — Is R9 already satisfied by the current placement?

Both queries already sit inside the Zone 1 → Zone 2 journey: Q1 is Zone 1 → staging, Q2 is
staging → Zone 2 target, and `EMPLOYEE_ID` is minted in Q2 at `sources/employee_q2_staging_to_zone2_target.txt`
line 50 — before anything reaches Zone 3. Read literally, **R9 looks already met** and there is
nothing to relocate; the work is R1–R8 and R10–R13. Confirm with Nidwika Vedanaparthi that the
intent was not to mint the key earlier still, in Q1.

### C5 — What is the region name's provenance?

R8 says the region name is passed in, never hard-coded. Nothing in the transcript says where the
ETL gets it. Candidates: an orchestrator parameter alongside the existing
`$$inout_param_*` set, derived from the Zone 1 source schema (`LEGACY_NA_MM_CM_ADW_HR_T_D` carries
`NA`), or a per-job config row. This decides whether R8 is actually met in practice — a region
name hard-coded in a job definition is a hard-coded region with extra steps.

### C6 — What happens to keys that already exist?

The EMPLOYEE target may already hold rows with unprefixed keys. Are existing keys left as they
are, with the prefix applied only to new ones — giving a table with two key formats — or is a
backfill required? The transcript does not say. Affects R12: `1` unprefixed and `1` as a region-1
key must not be confusable.

---

### C7 — R6 does not work the way it reads *(new, and it matters)*

R6 says the function returns the key already cast, so no ETL repeats the cast. That was the whole
motivation in §4. But *SQL UDF limitations* says the declaration will not enforce it:

> **Argument and return type constraints are sometimes ignored.** Certain type characteristics
> declared for an argument or return value will be ignored when the UDF is called. In these cases,
> **the received value may be used as received whether or not it conforms to constraints specified
> in the declaration.** The following are ignored for UDFs whose logic is written in SQL:
> Precision and scale for arguments and return values of type NUMBER; Length for arguments and
> return values of type VARCHAR.

So `RETURNS NUMBER(38,0)` on a SQL UDF is **not** a guarantee. R6 is still achievable, but only if
the **body** performs an explicit `CAST` — the signature cannot be relied on to do it. Write the
cast inside the function, and have the acceptance test assert the returned value's actual type and
scale rather than trusting the declaration.

This also sharpens C3: under digit concatenation the body *must* cast, because concatenation
genuinely produces text. Under fixed-width offset the arithmetic is numeric throughout, so there
is nothing for the ignored declaration to get wrong.

## 6. Where the change lands

`sources/employee_q2_staging_to_zone2_target.txt` line 50 — the only place a surrogate key is
minted, inside the `MERGE … USING` projection:

```sql
CAST(CASE WHEN stg.CHANGE_FLAG = '0'
          THEN $$inout_param_hr_database_name.$$inout_param_hr_main_schema_name.EMPLOYEE_SEQ.NEXTVAL
          ELSE stg.EMPLOYEE_ID END AS NUMBER(38,0)) AS EMPLOYEE_ID,
```

Q1 deliberately leaves the key unresolved, so Q2 is the whole surface area:

- flag `0` (new) rows carry `EMPLOYEE_ID = NULL` into `STG_EMPLOYEE`
- flags `1`, `3`, `4` carry the incumbent `CATCHUP_OLD_EMPLOYEE_ID` forward
- a flag-`4` correction emits **two** staged rows — the retirement keeps the old key, the
  replacement arrives as a fresh flag-`0` row and takes a new one

The `CASE`, the flag gating and the `ELSE` passthrough all stay as they are. Only the `THEN`
branch changes.

---

## 7. Acceptance criteria

The work is done when, for the EMPLOYEE table:

1. Q2 mints keys through the agreed callable, with no prefix or cast logic in the query itself
2. the region code comes from the mapping table, and adding a region needs no code change
3. the same deployed code runs unchanged in every environment
4. keys are unique across regions, demonstrated against a region population larger than three
5. the region is recoverable from a key without a join *(pending R13 confirmation)*
6. concurrent loads of several tables produce no duplicate keys **and** no unintended extra
   sequence consumption, with invocation count evidenced, not assumed
7. the function is explicitly declared `VOLATILE`, with neither `IMMUTABLE` nor `MEMOIZABLE` set,
   and a test asserts that N input rows receive N distinct keys — per C2 either keyword makes this
   function undefined behaviour
8. the cast is performed **inside the function body**, and a test asserts the returned value's
   actual type and scale rather than trusting the declaration — per C7 a SQL UDF's declared
   `NUMBER` precision and scale are ignored
9. evidence is recorded for each of the above, in the W5 tracker style

---

## 8. Reading order

| Path | What it is |
|------|-----------|
| `sources/requirement_region_prefixed_sequence.txt` | **The baseline.** The transcript. Wins over everything here |
| `requirement.md` | This document — scope, R1–R13, D1–D3, C1–C6, acceptance criteria |
| `explore/prefix_schemes.md` | C3 worked through: the two schemes, with evidence |
| `explore/prefix_schemes.py` | The runnable DuckDB demonstration behind it |
| `sources/employee_q2_staging_to_zone2_target.txt` | Line 50 — the only place a key is minted |
| `sources/employee_q1_zone1_to_staging.txt` | Q1, for why the key arrives `NULL` |

---

## 9. Sources

Every Snowflake behaviour quoted in this document was read **directly** from Snowflake's own
documentation. An earlier revision relied on search-relayed quotations because the docs host was
unreachable from the authoring session; `docs.snowflake.com` has since been allowed, the pages were
fetched and read, and the quotations were verified. Two of them were corrected in the process (see
C1 option 2, and the note below).

| Claim | Page |
|---|---|
| "Dynamic SQL is not supported when referring to database objects", with the `IDENTIFIER(param)` failure example; `NUMBER` precision/scale and `VARCHAR` length ignored on SQL UDFs | [SQL UDF limitations](https://docs.snowflake.com/en/developer-guide/udf/sql/udf-sql-limitations) |
| `VOLATILE`/`IMMUTABLE` semantics, "This guarantee is not checked", "undefined behavior", "Default: VOLATILE", and `MEMOIZABLE` in the SQL-handler syntax | [CREATE FUNCTION](https://docs.snowflake.com/en/sql-reference/sql/create-function) |
| "you cannot use a stored procedure CALL as part of an expression"; `SELECT * FROM (call proc1(1))` not allowed | [CALL](https://docs.snowflake.com/en/sql-reference/sql/call) |
| `TABLE(proc(…))` permitted in `SELECT`/`INSERT`/`UPDATE`/`DELETE`/`MERGE`/`CTAS`; only SELECT/SHOW/DESCRIBE/CALL procedures; no modifying procedures; static named typed schema; not usable in a view or UDF body | [Selecting from a stored procedure](https://docs.snowflake.com/en/developer-guide/stored-procedure/stored-procedures-selecting-from) |
| "Concurrent queries never observe the same value"; no gap-free or ordering guarantee; interval sign change may duplicate; 64-bit range; "Each occurrence of a sequence generates a set of distinct values"; `currval` not supported; `GETNEXTVAL` | [Using Sequences](https://docs.snowflake.com/en/user-guide/querying-sequences) |
| A SQL UDF "evaluates an arbitrary SQL expression"; a UDF body may query tables | [Introduction to SQL UDFs](https://docs.snowflake.com/en/developer-guide/udf/sql/udf-sql-introduction) |
| "DDL and DML operations are not supported in UDFs" | [DDL for user-defined functions…](https://docs.snowflake.com/en/sql-reference/ddl-udf) |

**What a search-relayed reading got wrong**, recorded so the method is not over-trusted next time:
it reported that a `SELECT` calling a stored procedure cannot be used in a UDF or view body and
left the impression that the `TABLE(proc(…))` route was closed generally. Read directly, the page
*also* lists `MERGE` among the statements where it is explicitly permitted — which is precisely
where Q2 needs it. The relayed quote was accurate; the omission changed the conclusion.

**Still unverifiable without a Snowflake account** — and the only thing C1 now turns on: whether a
SQL UDF body may contain `seq.NEXTVAL`. The word "sequence" appears nowhere in *CREATE FUNCTION*,
*Introduction to SQL UDFs* or *SQL UDF limitations*, and *Using Sequences* never mentions UDFs.
Not excluded by the DDL/DML prohibition, since consuming a sequence is neither.

A secondary unknown, for C1 option 2: whether consuming a sequence counts as "making
modifications using DDL or DML operations" for the purpose of `TABLE(proc(…))` eligibility. Also
undocumented, also a short test.
