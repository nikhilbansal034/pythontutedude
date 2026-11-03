# W6 — Region-prefixed sequence generation — requirement

**Status**: being finalised. Decisions D1–D3 taken. C1 is narrowed to one short Snowflake test;
C2 is resolved into a concrete implementation rule; C3–C6 need your decisions. Nothing built,
nothing tested in Snowflake.

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

**D3 — simulate in DuckDB first.** Logic, arithmetic and datatype questions get answered locally
before asking for Snowflake time. See `explore/prefix_schemes.py`. The limitation is explicit:
DuckDB cannot answer C1 or C2, which are the blocking ones.

---

## 5. Open questions

Ordered by how much they can change the design. **C1 and C2 should be settled before any build.**

### C1 — Can a Snowflake function take a sequence *name* and return that sequence's next value?

**Narrowed to a single testable unknown.** An earlier draft of this document concluded that R2 as
worded "cannot be met by anything inline-callable". **That was too strong** — it assumed the
sequence name had to be resolved as an *identifier*, which would need dynamic SQL. It does not: the
name can be used as a **branch selector** over sequences the function already names literally, and
then no dynamic SQL is involved and the signature is satisfied as written.

What the documentation confirms (all official Snowflake docs, reached through search because the
docs host is unreachable from this session — see §9):

| Confirmed | Consequence |
|---|---|
| A sequence is read as `seq_name.NEXTVAL` — the name is written literally | An object name still cannot be *parameterised* in static SQL, so a genuinely dynamic name needs dynamic SQL |
| "DDL and DML operations are not supported in UDFs" | Does **not** settle this: consuming a sequence is neither DDL nor DML |
| "You cannot use a stored procedure CALL as part of an expression"; `SELECT * FROM (call proc1(1))` fails | A procedure cannot mint the key inline where Q2 needs it |
| `SELECT … FROM TABLE(proc(…))` exists, but only for procedures performing SELECT/SHOW/DESCRIBE/CALL — "stored procedures that make modifications … aren't allowed" — and such a SELECT "can't be used in the body of a view, a user-defined function (UDF), a user-defined table function (UDTF)" | The stored-procedure escape route is **closed more firmly** than the earlier draft argued, not less |
| "Each occurrence of a sequence generates a set of distinct values" — unlike engines that return one value per statement | Two references to a sequence in one expression yield two values. Bears directly on option 1 below |
| Sequence values are 64-bit; a next value beyond that range fails the query | Caps the sequence half of the key. Relevant to the field width in C3 |
| `GETNEXTVAL` is a one-row table function alternative; its position in the `FROM` clause determines what it generates over, and it belongs at the end | An alternative shape, but its sequence name is still a literal |

**The one thing documentation does not state either way**: whether a SQL UDF body may contain
`seq.NEXTVAL` at all. Snowflake's sequence page does not mention UDFs, and the UDF pages do not
mention sequences. It is not excluded by the DDL/DML prohibition. **This is now the whole of C1,
and a single short test in the account settles it.**

Ways out, re-ordered on the evidence:

1. **UDF with a static `CASE` over known sequences** — *now the leading candidate.* Keeps the
   literal `(region_name, sequence_name)` signature, stays inline-callable, needs no dynamic SQL.
   The sequence name selects a branch rather than naming an object to resolve. Each new table adds
   one line to one function — still a single place, which is what §1 asked for.
   **Caveat, now evidenced rather than guessed**: because each occurrence of a sequence generates
   distinct values, a `CASE` naming several sequences may consume a value from branches not taken.
   That burns values from unrelated sequences — tolerable, since Snowflake already does not
   guarantee gap-free sequences, but it must be measured, and it is a reason to prefer one
   function per sequence if the branch count grows.
2. **Fall back to `f(region_name, seq_value)`** with `NEXTVAL` left in the query — D1's rejected
   alternative, retained for the case where a UDF body cannot reference a sequence.
3. **Procedure reserving a key range per batch**, ETL distributing values by `ROW_NUMBER()`.
   Genuinely parallel-safe and a well-established pattern, but now clearly **cannot** be called
   inline, so it changes the ETL shape; and a procedure that consumes a sequence is a modifying
   procedure, which bars it from `TABLE(…)` as well.

### C2 — Volatility, not invocation count

**This supersedes an earlier version of C2 that was wrong.** It claimed Snowflake "does not
guarantee a scalar UDF is evaluated exactly once per row". The documentation actually states the
handler **is called once for each row**, and Query History reports handler invocation counts, so
this is both specified and measurable. That earlier concern was overstated.

The real hazard is sharper, and it is specific to this function:

**Every row passes the function identical arguments** — the same region name and the same sequence
name for the whole statement. Snowflake's `IMMUTABLE` keyword declares that a function "when
called with the same inputs, will always return the same result", and the docs are explicit that
this promise **is not verified** and that declaring it on a function which returns different
values for the same input "will result in undefined behavior".

So a region-prefixed sequence UDF declared `IMMUTABLE` invites Snowflake to hand **every new row
the same surrogate key**. `VOLATILE` is the default, so an unannotated function is correct — but
this is a one-word footgun: anyone later adding `IMMUTABLE` as a performance tweak silently
corrupts the keyspace, with no error.

**Therefore**: the function must be explicitly declared `VOLATILE` rather than relying on the
default, with a comment saying why, and a test must assert that N input rows receive N distinct
keys. W3 recorded the adjacent trap — calling `NEXTVAL` twice on one row and assuming one value —
in `w3-scd-effective-date-split/poc_v2/scenarios/S14.sql`; finding that each sequence occurrence
generates distinct values confirms it.

### C3 — Which prefix scheme, and what datatype? *(R5, R6, R12, R13)*

Two candidates, explored with worked numbers in `explore/prefix_schemes.md`. On the evidence
there, **fixed-width offset is the stronger option** and digit concatenation has a latent
duplicate-key defect. Needs your decision, not mine.

If fixed-width offset is chosen, the sequence field width must be **fixed once and never
changed** — changing it renumbers every key ever issued. Pin it in this document.

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
7. the function is explicitly declared `VOLATILE`, and a test asserts that N input rows receive
   N distinct keys — per C2, `IMMUTABLE` on this function is undefined behaviour
8. the returned value needs no cast at the call site
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

## 9. Sources, and what could not be checked

The Snowflake behaviour cited in C1 and C2 comes from Snowflake's own documentation, read
indirectly: `docs.snowflake.com` and the `docs.snowflake.cn` mirror are both outside this
session's allowed network domains, so pages could not be fetched. Web search *can* read them and
quote them, and that is the channel used — every "confirmed" row in C1 and every quoted phrase in
C2 is documentation text surfaced that way.

Pages the claims trace to:

| Claim | Page |
|---|---|
| `seq_name.NEXTVAL` form; each occurrence generates distinct values; 64-bit limit; `GETNEXTVAL` | *Using Sequences* — `docs.snowflake.com/en/user-guide/querying-sequences` |
| "DDL and DML operations are not supported in UDFs" | *DDL for user-defined functions…* — `docs.snowflake.com/en/sql-reference/ddl-udf` |
| A `CALL` cannot be part of an expression | *CALL* — `docs.snowflake.com/en/sql-reference/sql/call` |
| `TABLE(proc(…))` eligibility, and its exclusion from UDF/view/UDTF bodies | *Selecting from a stored procedure* — `docs.snowflake.com/en/developer-guide/stored-procedure/stored-procedures-selecting-from` |
| `VOLATILE` is the default; `IMMUTABLE` is unverified and misdeclaration is undefined behaviour | *CREATE FUNCTION* — `docs.snowflake.com/en/sql-reference/sql/create-function` |
| Handler called once per row; batch count and order may vary | *General Scala UDF handler coding guidelines* — `docs.snowflake.com/en/developer-guide/udf/scala/udf-scala-general` |

**Caveat on method.** These are quotations relayed by a search tool, not pages read directly. They
are consistent with each other and with the `CREATE FUNCTION` reference, so they are good enough
to narrow the design — but before anything is built on them, confirm the two load-bearing ones
directly: that a `CALL` cannot appear in an expression, and that `IMMUTABLE` misdeclaration is
undefined behaviour. Allowing `docs.snowflake.com` in the environment's network settings is enough
for that.

**Still unverifiable without a Snowflake account** — and the only thing C1 now turns on: whether a
SQL UDF body may contain `seq.NEXTVAL`. No documentation states it either way.
