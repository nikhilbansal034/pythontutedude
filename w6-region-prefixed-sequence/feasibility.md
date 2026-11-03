# W6 — requirement-by-requirement feasibility

One pass over all thirteen requirements. For each: what it asks, what Snowflake's documentation
actually says, how that reads, what can be built, and what needs a workaround.

Every Snowflake quotation here was read directly from the documentation. Pages are listed in
`requirement.md` §9.

---

## Verdict at a glance

| # | Requirement | Verdict |
|---|---|---|
| R1 | ETL calls a reusable function instead of `<seq>.NEXTVAL` | **Achievable**, conditional on R3 |
| R2 | Signature takes region name **and** sequence name | **Achievable with a workaround** — branch selector, not an identifier. Registry table viable as a *generator* input, not as run-time indirection |
| R3 | Function gets the next value from the named sequence | **UNKNOWN — the one blocking test** |
| R4 | Function resolves region code from region name | **Achievable, cleanly** |
| R5 | Function combines region code with sequence value | **Achievable** — scheme choice open (C3) |
| R6 | Function returns the target's datatype; cast inside the function | **Achievable with a workaround** — the declaration is ignored, the body must cast |
| R7 | Mapping lives in a table | **Achievable** — watch per-row lookup cost |
| R8 | One code base across environments, region name an input | **Achievable** — and Snowflake's schema resolution helps |
| R9 | Region applied Zone 1 → Zone 2, not later | **Already satisfied** — confirm intent |
| R10 | Correct when called concurrently by multiple tables | **Already guaranteed** for the sequence; simulated clean locally; wrapper + volatility still to test |
| R11 | Mapping accommodates further regions without code change | **Achievable for regions**; new *sequences* do need a function edit |
| R12 | Every key unique across regions, for all time | **Achievable with fixed-width offset**; fails with concatenation |
| R13 | Region recoverable from the key without a join | **Achievable with fixed-width offset**; weak with concatenation |

Net: **one blocking unknown (R3)**, two requirements needing a workaround (R2, R6), two already
met (R9, R10), two depending on a scheme decision (R12, R13).

---

## R1 — The ETL calls a reusable function instead of `<seq>.NEXTVAL`

**Asks**: replace the direct sequence call in Q2 line 50 with one function call.

**Docs**: nothing prohibits calling a scalar UDF inside a `MERGE … USING` projection. A SQL UDF
"evaluates an arbitrary SQL expression and returns the results of the expression", and UDFs are
called like any other function in an expression.

**Reading**: the *call site* is not the problem. The shape of the swap is exactly as it looks:

```sql
CAST(CASE WHEN stg.CHANGE_FLAG = '0'
          THEN GET_REGIONAL_SEQ('North America', 'EMPLOYEE_SEQ')
          ELSE stg.EMPLOYEE_ID END AS NUMBER(38,0)) AS EMPLOYEE_ID,
```

**Can be achieved**: yes — the `CASE`, the flag gating and the `ELSE` passthrough all stay.

**Workaround needed**: none of its own. R1 inherits whatever R3 turns out to need.

---

## R2 — The signature takes region name *and* sequence name

**Asks**: `function(region_name, sequence_name)` — confirmed as the required signature (D1).

**Docs** — *SQL UDF limitations*, verbatim:

> **Dynamic SQL is not supported when referring to database objects.** Referring to database
> objects using dynamic SQL will produce an error that includes text such as the following:
> `Compilation of SQL UDF failed: SQL compilation error: syntax error... unexpected
> '<variable_name>'` […] If you need to construct dynamic SQL statements that use different
> database objects, consider writing a stored procedure instead.

The page's own failing example is this exact pattern — a UDF taking an object name as `VARCHAR`
and reaching it through `IDENTIFIER(table_name_parameter)`.

**Reading**: there are two different things one might do with `sequence_name`, and the docs
separate them sharply.

- **Resolve it as an identifier** — "go find the object with this name". **Impossible in a SQL
  UDF**, by name, with a quoted error message.
- **Compare it as a value** — "which of the sequences I already know is this?". **Untouched by
  this limitation**, because no identifier is ever constructed.

So the *signature* is fine. What is constrained is what the function may do with the second
argument.

**Can be achieved**: yes, via the branch-selector shape:

```sql
CASE sequence_name
    WHEN 'EMPLOYEE_SEQ' THEN EMPLOYEE_SEQ.NEXTVAL
    WHEN 'JOB_SEQ'      THEN JOB_SEQ.NEXTVAL
    WHEN 'OFFICE_DEPARTMENT_SEQ' THEN OFFICE_DEPARTMENT_SEQ.NEXTVAL
END
```

**Workaround needed**: yes, and it has a real cost worth stating plainly — **the function must
know every sequence by name**. Onboarding a new table means editing the function, not just
inserting a config row. That is still *one place* rather than per-ETL, which is what §1 asked for,
but it is not the fully generic thing the signature implies.

**Evidenced caveat** — *Using Sequences*:

> Sequences may be accessed in queries as expressions of the form `seq_name.NEXTVAL`. **Each
> occurrence of a sequence generates a set of distinct values.** This is different from what many
> other databases provide, where multiple references to NEXTVAL of a sequence return the same
> value for each row.

A `CASE` naming several sequences may therefore consume a value from branches not taken — burning
numbers from unrelated sequences. Tolerable (gaps are never guaranteed anyway) but it must be
measured, and it argues for one function per sequence if the branch list grows long.

---

### Nikhil's two questions on R2

**(a) Will `CASE … THEN DB.SCHEMA.SEQUENCE.NEXTVAL` accept a fully-qualified name?**

Yes — a fully-qualified sequence reference is an ordinary identifier, and Q2 line 50 already
writes one. **But note why that is not evidence of anything dynamic**: Q2's `$$inout_param_*`
markers are substituted by the **orchestrator** before Snowflake ever sees the SQL. Snowflake
receives literal object names. It proves qualification works; it says nothing about run-time
naming.

There is a catch that cuts the other way, and it bears on R8. A fully-qualified body **hard-codes
the database and schema**, so the same function text is not portable across environments. An
*unqualified* reference resolves "in the schema containing the function", so identical text
deployed to dev, SIT and prod each binds its own objects. **Prefer unqualified inside the
function.** Test `T2.1` vs `T2.1b` in `poc/02_r2_sequence_name_binding.sql` settles it either way.

**(b) Can a second mapping table hold the full sequence name, so new entries are data not code?**

**No — not inside a UDF.** This is the part worth being precise about, because the idea is
reasonable and the reason it fails is not obvious.

The prohibition is not about *where the string comes from*. It is about turning any run-time value
into an object reference at all. Two independent pieces of evidence:

- Snowflake's `IDENTIFIER()` syntax accepts **only** "a string literal, session variable, bind
  variable, or Snowflake Scripting variable". A value read from a table is **none of those** — and
  neither is a UDF argument. *SQL UDF limitations* then closes it explicitly: "Dynamic SQL is not
  supported when referring to database objects."
- DuckDB, a completely unrelated engine, refuses the same thing in the same terms. From
  `explore/r2_sequence_name_binding.py`:

  ```
  Nikhil's proposal: look the full name up from a mapping table, pass it in
    FAILED -> Binder Error: The "sequence_name" argument in function "nextval"
              must be a constant expression
  ```

  Two engines enforcing the same invariant is good evidence it is intrinsic: **a sequence must be
  identifiable before the query runs.** Storing the name in a table makes the *name* data; it does
  not make the name *usable*.

**But the registry table is still worth building** — as a registry, not an indirection. Two shapes
deliver what you are after, which is "onboarding a table is a data change":

1. **Generate the function from the registry.** The registry is the source of truth; a small
   generator emits the `CASE` arms and the function is replaced on deploy. Onboarding becomes
   *insert a row, re-run the generator* — no hand-editing, and the registry stays authoritative.
   This fits W6 unusually well, because **these queries are already generated** rather than
   hand-written, so a generation step is not new machinery. It is the option I would put forward.
2. **Use a stored procedure instead of a UDF.** A procedure *can* do dynamic SQL, so it can read
   the full name from the registry and use it — exactly your design, working. The cost is the call
   site: per *CALL*, "you cannot use a stored procedure CALL as part of an expression", so it
   cannot sit in Q2's projection. It would have to come in through `TABLE(proc(…))` in the `MERGE`
   source, which *Selecting from a stored procedure* does permit for `MERGE` — subject to the open
   question of whether consuming a sequence counts as a modifying operation.

Option 1 keeps the simple call site and pays with a build step. Option 2 keeps your exact design
and pays with a restructured `MERGE`. Both are real; neither is a UDF reading a name from a table.

## R3 — The function gets the next value from the named sequence

**Asks**: `NEXTVAL` happens *inside* the function.

**Docs**: this is the gap. The word "sequence" appears **nowhere** in *CREATE FUNCTION*,
*Introduction to SQL UDFs*, or *SQL UDF limitations*. *Using Sequences* never mentions UDFs. The
one adjacent rule — *DDL for user-defined functions*: "DDL and DML operations are not supported in
UDFs" — does **not** settle it, because consuming a sequence is neither DDL nor DML.

**Reading**: undocumented either way. Not prohibited, not permitted. It cannot be resolved by
reading more; it needs one statement run in the account.

**Was this validated in DuckDB? No — and DuckDB cannot validate it.** Worth stating plainly,
because a DuckDB test here would not merely be inconclusive, it would be **actively misleading**:

| | DuckDB | Snowflake |
|---|---|---|
| How a sequence is read | `nextval('seq_name')` — a **string** argument | `seq_name.NEXTVAL` — an **identifier** |
| Wrapping it in a function with a name parameter | **Works** (macros inline the literal) | The open question |

So "a function that takes a sequence name and returns its next value" *succeeds in DuckDB* and
tells you nothing about Snowflake. `explore/r2_sequence_name_binding.py` §1 demonstrates exactly
this false positive, deliberately, so nobody later mistakes it for evidence.

What DuckDB *can* corroborate is the deeper rule — that the sequence must be fixed at compile time
— which it enforces in its own words, and which is what settles R2(b) above. For R3 itself the
only instrument is `poc/01_r3_sequence_in_udf.sql`.

**The test** — this is the whole of the blocking unknown:

```sql
CREATE OR REPLACE SEQUENCE test_seq START 1 INCREMENT 1;

CREATE OR REPLACE FUNCTION test_seq_in_udf()
RETURNS NUMBER(38,0) VOLATILE
AS $$ test_seq.NEXTVAL $$;

-- If the CREATE succeeds, does it return distinct values per row?
SELECT test_seq_in_udf() FROM TABLE(GENERATOR(ROWCOUNT => 5));
```

Three possible outcomes, each with a known consequence:

| Outcome | Consequence |
|---|---|
| `CREATE` fails | R3 impossible in a SQL UDF. Fall back (below) |
| `CREATE` succeeds, 5 distinct values | **R3 achieved.** Proceed with the branch-selector design |
| `CREATE` succeeds, 5 identical values | Worse than failure — silent. Means the body was folded to a constant; R3 unusable as a scalar UDF |

**Workaround if it fails** — two, in order of preference:

1. **Pass the value in instead of the name**: `f(region_name, seq_value)` with `NEXTVAL` left in
   the query. Loses half of R2's signature; keeps everything else, including R6's centralised cast.
2. **Stored procedure via `TABLE(…)` in the `MERGE` source.** *Selecting from a stored procedure*
   confirms the procedure "must be called in the `FROM` clause of a `SELECT` block in one of the
   following statements: `SELECT`; `INSERT`, `UPDATE`, `DELETE`, or **`MERGE`**; `CREATE TABLE AS
   SELECT`" — which is where Q2 needs it. But two constraints bite: only procedures performing
   "SELECT, SHOW, DESCRIBE, or CALL" qualify and those "that make modifications using DDL or DML
   operations aren't allowed" (**is consuming a sequence a modification? undocumented — a second
   short test**), and the procedure must return tabular data with a static, named, typed schema.
   Also, per *CALL*, "you cannot use a stored procedure CALL as part of an expression", so this
   works only through `TABLE(…)`, never in the projection.

---

## R4 — The function resolves the region code from the region name

**Asks**: look up North America → 1 inside the function.

**Docs** — *Introduction to SQL UDFs* shows a UDF body querying a table
(`CREATE FUNCTION total_user_count() RETURNS NUMBER AS 'select count(*) from users'`), and states:

> If a function definition refers to an unqualified table, then that table is resolved in the
> schema containing the function. […] **The invoker of the function need not have access to the
> objects referenced in the function definition**, but only needs the privilege to use the
> function.

**Reading**: straightforward, and the privilege model is a genuine bonus — ETL roles need `USAGE`
on the function but no grant on the mapping table, so the mapping cannot be edited by whoever
happens to run a load.

**Can be achieved**: yes, cleanly. This is the least risky requirement in the set.

**Workaround needed**: none.

---

## R5 — The function combines the region code with the sequence value

**Asks**: put the region "in front of" the sequence value.

**Docs**: no constraint on the arithmetic itself. The relevant input is the sequence's own ceiling
— *Using Sequences*:

> A sequence value can represent a 64-bit two's complement integer (-2^63 to 2^63 - 1). If the
> internal representation of a sequence's next value exceeds this range (in either direction) an
> error results and the query fails.

**Reading**: "combine" is underspecified in the transcript, and the two readings behave very
differently. Fully worked in `explore/prefix_schemes.md`; the short version is in R12/R13 below.

**Can be achieved**: yes. **Open decision (C3)**: digit concatenation vs fixed-width offset.

**Workaround needed**: none, but note the 64-bit ceiling applies to the sequence's *internal* next
value, which gaps can push ahead of the values actually returned. An 18-digit field sits just
under it; 15–16 digits buys headroom for nothing (10^15 is still a quadrillion keys per region).

---

## R6 — The function returns the target's datatype, cast inside the function

**Asks**: the cast happens once, in the function — §4's stated motivation, since prefixing
changed the datatype and needed casting back.

**Docs** — *SQL UDF limitations*, verbatim:

> **Argument and return type constraints are sometimes ignored.** Certain type characteristics
> declared for an argument or return value will be ignored when the UDF is called. In these cases,
> **the received value may be used as received whether or not it conforms to constraints specified
> in the declaration.** The following are ignored for UDFs whose logic is written in SQL:
> Precision and scale for arguments and return values of type NUMBER; Length for arguments and
> return values of type VARCHAR.

**Reading**: this is the finding most likely to surprise the team. `RETURNS NUMBER(38,0)` on a SQL
UDF is **documentation, not enforcement**. Declaring the return type does not make the returned
value conform to it.

**Can be achieved**: yes — but only if the **body** performs the `CAST`:

```sql
-- the cast must be here, inside, not in the RETURNS clause
AS $$ CAST(<region_code> * 1000000000000000000 + <seq_value> AS NUMBER(38,0)) $$
```

**Workaround needed**: yes. Put the cast in the body, and have the test assert the *actual* type
and scale of the returned value rather than trusting the signature.

**Knock-on for C3**: under concatenation the body *must* cast, because concatenation genuinely
produces text. Under fixed-width offset the arithmetic never leaves the numeric domain, so there
is nothing for the ignored declaration to get wrong. The requirement that motivated centralising
the cast is best served by the scheme that removes the cast entirely.

---

## R7 — The mapping lives in a table

**Asks**: region name → region code in a table, not in the function and not in the ETL.

**Docs**: as R4 — a UDF body may query a table.

**Reading**: satisfied by the same mechanism as R4. Two practical notes the docs imply rather than
state:

- the lookup runs **per row**, since the function is called per row. A three-row mapping table is
  trivial for Snowflake to scan, but it is worth confirming in the plan rather than assuming
- the mapping table must live in, or be reachable from, the schema containing the function

**Can be achieved**: yes.

**Workaround needed**: none. If per-row lookup ever shows up in a query profile, the mapping is
small and static enough to be a good candidate for Snowflake's memoization — but **not on this
function**, see R10/C2, because memoizing a sequence-consuming function would be fatal. It would
have to be a separate, pure lookup function.

---

## R8 — One code base across environments, region name an input

**Asks**: the same deployed function in every environment; the region arrives as an argument.

**Docs** — *Introduction to SQL UDFs*: "If a function definition refers to an unqualified table,
then that table is resolved in the schema containing the function."

**Reading**: this is the mechanism that makes R8 work rather than an obstacle. If the function
references the mapping table **unqualified**, the identical function text deployed to dev, SIT and
prod each resolves its own mapping table, with no environment-specific literals anywhere.

**Can be achieved**: yes.

**Workaround needed**: none technically — but R8 is only genuinely met if the region name is not
hard-coded *upstream*. That is **C5**, still open: a region name hard-coded in a job definition is
a hard-coded region with extra steps. Candidates are an orchestrator parameter alongside the
existing `$$inout_param_*` set, derivation from the Zone 1 source schema (`LEGACY_NA_MM_CM_ADW_HR_T_D`
carries `NA`), or a per-job config row.

---

## R9 — Region applied Zone 1 → Zone 2, not at Zone 2 → Zone 3

**Asks**: qualify the key on the left-hand side, so the identifier never changes later.

**Docs**: not a Snowflake question.

**Reading**: read against the actual queries, **this already holds.** Q1 is Zone 1 → `STG_EMPLOYEE`
and leaves `EMPLOYEE_ID` as `NULL` for new rows; Q2 is `STG_EMPLOYEE` → the Zone 2 target and
mints the key at line 50. Both sit inside the Zone 1 → Zone 2 journey, and the key exists before
anything reaches Zone 3.

**Can be achieved**: already met at the current placement.

**Workaround needed**: none — but **confirm the intent (C4)**. If Nidwika meant the key should be
minted in *Q1* rather than Q2, that is a different and larger change: Q1 would have to allocate
keys for rows the `MERGE` has not yet decided to insert, and the flag-`4` correction path (which
emits a retirement row plus a fresh flag-`0` replacement) would need rethinking.

---

## R10 — Correct when called concurrently by multiple tables

**Asks**: your assigned action item — prove the function is safe called in parallel.

**Docs** — *Using Sequences*, verbatim:

> All values generated by a sequence are globally unique as long as the sign of the sequence
> interval does not change (e.g. by changing the step size). **Concurrent queries never observe
> the same value, and values within a single query are always distinct.**

**Reading**: the concern behind R10 is **already answered by Snowflake for the sequence itself**.
Two tables calling the same sequence concurrently cannot receive the same value. This meaningfully
shrinks the action item: it is not "prove sequences are concurrency-safe", it is "prove the
*wrapper* does not break a guarantee the sequence already provides".

**Can be achieved**: yes, and most of it is guaranteed rather than tested.

**What still needs testing** — and it is a volatility question, not a concurrency one:

*CREATE FUNCTION*, verbatim:

> **IMMUTABLE**: UDF assumes that the function, when called with the same inputs, will always
> return the same result. **This guarantee is not checked.** Specifying IMMUTABLE for a UDF that
> returns different values for the same input will result in **undefined behavior**.
> Default: VOLATILE

**Every row passes this function identical arguments** — same region name, same sequence name, all
statement long. So an `IMMUTABLE` version invites Snowflake to hand every new row the same
surrogate key, silently. The SQL handler syntax also accepts `[ MEMOIZABLE ]`, which is the same
failure by another route.

**Rule to carry into the build**: declare `VOLATILE` explicitly with a comment saying why, never
`IMMUTABLE`, never `MEMOIZABLE`, and assert that N input rows receive N distinct keys.

**Validated so far, and what remains.** You asked for R10 to be validated thoroughly, so it is
split into what is already evidenced and what still needs Snowflake.

*Simulated locally* — `explore/r10_concurrency_sim.py`, 7 parallel workers across 3 regions and 3
tables drawing from one shared sequence:

```
keys issued      14,000
distinct keys    14,000
duplicates       0        <- PASS
keys shared by >1 region  0        <- PASS
every key decodes to its issuing region   PASS (all 3 regions)
```

It also makes the gap behaviour visible — each region's keys are scattered across the shared
range, with thousands of gaps, which is **correct** and must not be read as missing rows.

*What the simulation cannot touch*, and what `poc/04_r10_concurrency.sql` exists for: Snowflake's
own guarantee holding **through the function wrapper**, invocation counts per row, and the
`IMMUTABLE`/`MEMOIZABLE` folding tests — which have no DuckDB equivalent and are the real hazard.
That pack runs three concurrent sessions over 30,000 keys, then 15,000 across three concurrent
regions, with negative tests for both volatility keywords and a check that the shipping function
declares what we think it declares.

**Three caveats from the same page**, worth recording as design constraints:

- "There is no guarantee that values from a sequence are contiguous (gap-free) or that the
  sequence values are assigned in a particular order" — gaps are expected, not data loss
- changing the interval's sign "may result in duplicates" — so `INCREMENT` must never be flipped
  once keys are issued
- `currval` is **not supported** in Snowflake — nothing may be built on reading back the last
  issued value

---

### C8 — One shared sequence, or one per region? *(new, and it changes what the prefix is for)*

The simulation surfaced a question nothing in the transcript settles, and it changes the stakes of
the C3 decision.

If all regions draw from **one shared sequence**, the sequence alone already separates every row —
measured in `explore/r10_concurrency_sim.py` §6, zero duplicate sequence parts across 14,000 keys
with the prefix ignored entirely. The prefix would then carry **traceability only** (R13), not
uniqueness.

But §3 of the transcript describes regions being consolidated into a *global* database later,
which implies each region runs its own Zone 2 with its **own sequence** — each starting at 1.
Modelled in §7 of the same script:

```
every region issued 1..3000 independently
duplicate keys with NO prefix at all:            6,000  of 9,000
duplicate keys with FIXED-WIDTH OFFSET prefix:       0
duplicate keys with DIGIT CONCATENATION prefix:      0
```

Under that topology the prefix is **load-bearing for integrity**, not decoration: it is the only
thing keeping North America's employee 1 apart from EU's employee 1. Which is presumably why the
requirement exists at all.

**Why it matters for C3**: both schemes cope at three single-digit region codes. But if the prefix
is the sole separator between regions, digit concatenation's failure at a two-digit region code
stops being a tidiness argument and becomes **the loss of the only thing distinguishing two
regions' primary keys**. The same decision, with much more riding on it.

**Confirm the topology before settling C3.**

## R11 — The mapping accommodates further regions without code change

**Asks**: adding a region is a data change, not a code change.

**Docs**: not a Snowflake question.

**Reading**: holds for **regions**, via the mapping table. Two things leak, and they are worth
separating because they are often conflated:

- adding a **region** → insert a mapping row. No code change. R11 satisfied.
- adding a **table/sequence** → edit the function's `CASE`. This is a consequence of R2's
  workaround, not a failure of R11.

**Can be achieved**: yes for regions.

**Workaround needed**: none for R11 — but see R12. Adding regions is only safe *as data* if the
prefix scheme survives the region count growing, which digit concatenation does not.

---

## R12 — Every key unique across regions, for all time *(derived)*

**Asks**: a surrogate key is a primary key. **Not in the transcript** — derived from §3's
traceability argument. **Needs confirmation.**

**Docs**: sequence values are "globally unique" and "concurrent queries never observe the same
value" — so uniqueness of the *sequence half* is guaranteed. Uniqueness of the *composed key* is
not a Snowflake question; it depends entirely on the C3 scheme.

**Reading**: this is where the two schemes diverge decisively. Measured in
`explore/prefix_schemes.py`:

```
population tested          4,389 keys (11 regions x 399 values)
CONCAT duplicate keys      99
OFFSET duplicate keys      0
```

Digit concatenation is collision-free **today** only because the three allocated codes are single
digits. `concat(1, 23)` and `concat(12, 3)` are both `123`. At a tenth region, two employees in
different regions silently share a primary key — no error, no constraint violation.

**Can be achieved**: yes with fixed-width offset. **No** with digit concatenation, once region
codes reach two digits — which R11 explicitly anticipates.

**Workaround needed**: zero-padding the region code (`01`, `02`, …) removes the collision, but
then the padding width becomes the thing that must never change — which is the fixed-width scheme
wearing a disguise, and still as text.

---

## R13 — The region is recoverable from the key without a join *(derived)*

**Asks**: given a key, tell which region issued it. **Not in the transcript** — derived, because
§3's whole argument is that you should not need the UUID or prefix-stripping logic to trace a
record. **Needs confirmation**: if R13 is not actually required, concatenation's weakness matters
much less.

**Docs**: not a Snowflake question.

**Reading**:

- **fixed-width offset** decodes both halves with arithmetic, assuming nothing:
  `region = key / 10^18`, `seq_value = key % 10^18`
- **digit concatenation** recovers the region only by taking the first character — which works
  solely because codes are one digit — and **cannot recover the sequence value at all**, because
  nothing marks where the region ends

**Can be achieved**: yes with fixed-width offset.

**Workaround needed**: with concatenation, recovering the region means consulting the mapping
table to know how many leading digits to take — i.e. a join, which is exactly what R13 exists to
avoid.

---

## What the documentation volunteered that nobody asked about

Four things found while checking the above, each with a bearing on the design:

1. **`currval` is not supported.** Snowflake deliberately omits it, calling the pattern "contrary
   to Snowflake best practices". Nothing may read back the last issued key.
2. **`GETNEXTVAL`** is a one-row table function alternative to `seq.NEXTVAL`. "Joins may not
   reorder around GETNEXTVAL", it must be aliased, and its position in the `FROM` clause determines
   what it generates over. A possible shape if the scalar-UDF route fails, though its sequence name
   is still a literal.
3. **`MEMOIZABLE`** exists on SQL UDFs and would be fatal here. Worth an explicit prohibition in
   the build standard, not just this document.
4. **Gaps are guaranteed to be possible.** If anyone downstream treats a missing key as lost data,
   that assumption is wrong independently of this change.
