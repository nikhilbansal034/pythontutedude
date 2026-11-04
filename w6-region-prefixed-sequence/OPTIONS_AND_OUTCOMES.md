# W6 — every requirement, every alternative tried, and what happened

Built for the deck. For each requirement: what it asked, what Snowflake's documentation says, every
option we actually tested, the measured outcome of each, and the final position.

> **Read [`SCHEMES_EXPLAINED.md`](SCHEMES_EXPLAINED.md) first.** Nidwika's feedback was that the
> duplicate counts here are quoted without the rationale behind them, and she is right. That
> document explains what each scheme *is* and *why* one breaks; this one records the options and
> outcomes. **The deck should lead with the mechanism and use these numbers as confirmation.**

Nine Snowflake runs, 2026-11-03/04. Evidence: the `*.json` run logs in this folder and
`poc/R*_RESULTS.md`. Where an option was *rejected*, the measurement that rejected it is quoted —
those are the slides worth building.

---

## Headline

| | |
|---|---|
| **Closed** | R1, R2, R3, R4, R5, R6, R7, R8, R10, R11, R12, R13 — **12 of 13** |
| **Closed as already satisfied** | R9, pending one confirmation from Nidwika |
| **Decided by data** | C3 → fixed-width offset, width 15 · C6 → leave legacy keys alone |
| **Informed, not decided** | C5 (IDMC mechanism only — the Snowflake side is closed) |
| **Decided 4 Nov** | **D5 — Scheme B, fixed-width offset, sequence field 15.** See "The scheme decision" below |

---

## R1 — The ETL calls a reusable function instead of `<seq>.NEXTVAL`

**Docs**: "A SQL UDF evaluates an arbitrary SQL expression." Nothing restricts calling one in a
`MERGE … USING` projection.

| Option | Outcome |
|---|---|
| Call the function in Q2's `MERGE` projection | **WORKS** — R3 T1.6: 3 rows, 3 distinct IDs, mirroring Q2 line 50 |

**Final: CLOSED.** No alternatives needed.

---

## R2 — Signature takes region name **and** sequence name

**Docs**: *SQL UDF limitations* — "**Dynamic SQL is not supported when referring to database
objects**." `IDENTIFIER()` accepts only "a string literal, session variable, bind variable, or
Snowflake Scripting variable".

| Option tried | Outcome | Evidence |
|---|---|---|
| **A.** `IDENTIFIER(parameter).NEXTVAL` | **FAILED at CREATE** — `syntax error … unexpected 'seq_name'` | R2 T2.2b |
| **B.** Registry table holding the full sequence name, read inside the UDF | **FAILED at CREATE** — same error class | R2 T2.2a |
| **C.** Branch selector — `CASE sequence_name WHEN 'EMPLOYEE_SEQ' THEN …` | **WORKS**, including the name varying **per row** | R2 T2.3a/b: 5/5/5 |

**Why B is worth a slide.** It is the intuitive design — put the name in config, read it, use it.
It cannot work, and the reason is not where the string comes from: **no run-time value can become an
object reference.** T2.2b proves it by removing the table entirely and still failing.

**Cost of C, stated plainly**: the function must name every sequence literally, so onboarding a new
table edits the function. Still *one place*, which is what §1 asked for — but not the fully generic
thing the signature implies.

**Final: CLOSED via option C.** The registry survives as a **code generator** for the `CASE` arms,
not as a run-time indirection.

---

## R3 — The function gets the next value from the named sequence

**Docs**: **silent**. The word "sequence" appears nowhere in *CREATE FUNCTION*, *Introduction to SQL
UDFs* or *SQL UDF limitations*; *Using Sequences* never mentions UDFs. Not excluded by "DDL and DML
operations are not supported in UDFs", since consuming a sequence is neither.

| Option | Outcome |
|---|---|
| `seq.NEXTVAL` inside a SQL UDF body | **WORKS** — 100 rows → 100 distinct, 0 duplicates, and valid inside a `MERGE` |
| *Fallback, not needed:* pass the value in, `f(region_name, seq_value)` | untested — R3 passed |
| *Fallback, not needed:* stored procedure via `TABLE(proc(…))` | untested — R3 passed |

**The trap that did not spring**: ten *identical* values at T1.3 would have meant a constant-folded
body — a silent failure that `CREATE` succeeding would have masked. Ten distinct values came back.

**Final: CLOSED.** This was the blocker; everything else depended on it.

---

## R4 / R7 — Resolve the region code from a mapping table

**Docs**: a UDF body may query a table. "The invoker of the function need not have access to the
objects referenced in the function definition, but only needs the privilege to use the function."

| Option | Outcome |
|---|---|
| Mapping table read inside the function body | **WORKS** — exercised in R6, R10, R12 v3 and R11/C3; every one of 30,000+ keys decoded correctly |

**Bonus**: the privilege model means ETL roles need `USAGE` on the function but **no grant on the
mapping table**, so a load cannot edit the mapping.

**Condition (F23)**: create the function while the session is in its own schema, or the unqualified
table binds elsewhere — see R8.

**Final: CLOSED.**

---

## R5 + C3 — How the region code combines with the sequence value

**Docs**: no constraint on the arithmetic. The relevant limit is that a sequence value is a **64-bit**
integer and exceeding that range fails the query.

### The two candidates, measured over the same 4,800 keys at twelve regions

| | Digit concatenation | Fixed-width offset |
|---|---|---|
| Duplicate primary keys | **198** | **0** |
| Keys that decode correctly | 3,600 of 4,800 | **4,800 of 4,800** |
| Key width | 2–5 digits, varies with value | 16–17, varies only with region code |
| Legacy-key coexistence | **999 collisions** | 0 — eleven orders of magnitude apart |
| Needs a cast back | yes (`VARCHAR`) | no |

**The collision, concretely** — this is the slide:

```
key 111  ->  Benelux       employee 1    (concat(11, 1))
             North America employee 11   (concat(1, 11))
```

Two different employees, two different regions, **one primary key**.

**Two independent failures.** Concatenation fails on *region growth* (198 duplicates) **and** on
*legacy coexistence* (999 collisions). Eliminating it does not rest on a single test.

### Field width

| Width | Keys per region | 64-bit downstream consumer |
|---|---|---|
| 12 | 10¹² | safe |
| **15** | **10¹⁵ (a quadrillion)** | **safe — region 12 key is 1.3% of the ceiling** |
| 18 | 10¹⁸ | **overflows a Java `long` / BIGINT at a two-digit region code** |
| 19 | — | exceeds the 64-bit **sequence** ceiling |

**`NUMBER(38,0)` is never the binding constraint.** The binding constraints are the 64-bit sequence
ceiling and any **downstream 64-bit consumer** — which is why 15 beats 18.

**Final: C3 DECIDED BY DATA — fixed-width offset, field width 15.** Pin the width now; changing it
later renumbers every key ever issued.

---

## R6 + C7 — The function returns the target's datatype

**Docs**: *SQL UDF limitations* — "the received value may be used as received whether or not it
conforms to constraints specified in the declaration… ignored for UDFs whose logic is written in SQL:
Precision and scale for … NUMBER; Length for … VARCHAR."

| Option | Outcome |
|---|---|
| **A.** Rely on `RETURNS NUMBER(38,0)` | **FAILS** — `RETURNS NUMBER(3,0)` happily returned a 15-digit value; `RETURNS VARCHAR(1)` returned 10 characters |
| **B.** `CAST` inside the function body | **WORKS** — delivers `NUMBER(38,0)`, lands intact in the target column |

**The finding that surprised us, in a good way.** We predicted a concatenating UDF would silently
return `VARCHAR` despite `RETURNS NUMBER(38,0)`. It did not — Snowflake **refused the CREATE**:

```
Declared return type 'NUMBER(38,0)' is incompatible with
actual return type 'VARCHAR(134217728)'
```

So there are **two layers**: the **base type is enforced at CREATE**, while precision, scale and
length are not. The §4 datatype problem therefore **cannot ship silently** — it surfaces as a refused
deployment.

**Final: CLOSED via option B.** The cast is mandatory, for correctness of *magnitude* rather than to
avoid a silent type mismatch.

---

## R8 — One code base, unchanged across environments

**Docs**: *Name resolution* — "All unqualified objects in a view or UDF definition will be resolved in
the view's or UDF's schema only." **Sequences do not comply with this sentence.**

| Option | Outcome |
|---|---|
| **A.** Unqualified sequence name, relying on the documented rule | **FAILS** — resolves in the **caller's** current schema at run time. Calling from a schema with no same-named sequence gives `invalid identifier`, *though the function's own schema has one* |
| **B.** Fully-qualified sequence name | **WORKS** — three calls from three different caller schemas advanced only the function's own sequence |

**Why this matters more than portability.** Option A does not merely make the function less portable:
the same function invoked from two differently-configured sessions **silently draws from two
different sequences**. For a surrogate key that is a data-integrity defect, and nothing in the key
reveals it.

**The full rule (F23)**, which is cleaner than our first reading:

> Unqualified names resolve against the session's **current schema at CREATE time**. Tables are then
> **permanently bound**. Sequences are **not bound** — re-resolved on every call.

**This contradicts documented behaviour and is worth raising with Snowflake support.**

**Final: CLOSED via option B**, as **one template substituted at deploy time** rather than one literal
text — which is exactly how Q2 already deploys via `$$inout_param_*`.

---

## R9 + C4 — Mint the key in Q1 or Q2?

**Docs**: not a Snowflake question.

| Option | Keys minted | Orphaned | Flag-4 problem | §3 satisfied? |
|---|---|---|---|---|
| **Q2 (today)** | 1,500 for 1,500 inserts | 0 | none | **yes** |
| **Q1** | 10,000 for 1,500 inserts | **8,500 (85%)** | **500 retirement rows get a key they must not use** | **yes** |

**The key result: both satisfy §3.** Q1 and Q2 both sit inside the Zone 1 → Zone 2 journey, so the
identifier is region-qualified before Zone 3 either way. **C4 is not a correctness question.**

**The substantive objection to Q1** is not the waste — 8,500 keys against 10¹⁵ is immaterial. It is
that **flag-4 corrections carry two candidate keys**, so Q1 would need the SCD-2 change-flag logic
that currently lives in Q2. *That is a redesign, not a relocation.*

**Final: recommend closing C4 as "already satisfied"**, pending Nidwika's confirmation that Q1 was not
meant specifically.

---

## R10 — Correct when called concurrently by multiple tables

**Docs**: "**Concurrent queries never observe the same value**, and values within a single query are
always distinct." `IMMUTABLE` — "This guarantee is not checked… will result in **undefined
behavior**." Default is `VOLATILE`.

| Option | Outcome |
|---|---|
| **`VOLATILE`** | **CORRECT** — 60,000 keys, 3 concurrent sessions with measured overlap, **0 duplicates** |
| `IMMUTABLE` | **PROHIBITED** — did not fold on the test run, but every row passes identical arguments, which is exactly the folding condition. Undefined behaviour that happens not to bite is still undefined |
| `MEMOIZABLE` | **PROHIBITED** — same failure by another route |

**The CI trap worth a slide**: a memoizable function reports `VOLATILITY = 'VOLATILE'`. **A release
check asserting volatility alone would wave it straight through.** Assert both columns.

**Final: CLOSED**, with `VOLATILE` mandatory and the other two banned.

---

## R11 — New regions without a code change

| Option | Outcome |
|---|---|
| Add a region by inserting a mapping row | **WORKS** — grew from 3 to 12 regions with **zero lines of code**; the function's `CREATED` equals its `LAST_ALTERED` to the millisecond |

**Final: CLOSED.** The `CREATED = LAST_ALTERED` query is worth lifting into a release check.

---

## R12 — Every key unique across regions, for all time

Four attempts. **Three could not have failed** — the single most important lesson in this pack.

| Attempt | Premise established? | Result | Why |
|---|---|---|---|
| `04` T4.7 | No | vacuous PASS | one sequence shared by all regions |
| `05` T5.2 | No | vacuous PASS | three per-region sequences moved in **lockstep** |
| `06` T6.1 | No | **halted at its gate** | unqualified sequences followed the caller |
| **`07` T7.1** | **Yes — 1000 collisions** | **genuine PASS** | fully-qualified sequences |

**The proof:**

```
raw value 1  ->  1000000000000001 (NA) | 2000000000000001 (EU) | 3000000000000001 (APAC)
```

All three regions issued raw value `1`. 10,000 raw values were each issued in **all three** regions.
**Without the prefix the 30,000 keys would have held 20,000 duplicates.** With it, zero.

**Final: CLOSED.**

---

## R13 — Region recoverable from the key without a join

| Option | Outcome |
|---|---|
| Fixed-width offset — decode by `key / 10^15` | **WORKS** — 10,000 × 3 regions, zero misattribution, *while raw values collide* |
| Digit concatenation — decode by first character | **FAILS** — 1,200 of 4,800 keys misdecode, exactly the three two-digit regions |

**Final: CLOSED, under the offset scheme only.**

---

## C5 — Where does the region name come from?

**Not decided here** — the mechanism is an IDMC choice. What the run established:

| Candidate | Works? | Trade-off |
|---|---|---|
| **A.** Literal argument | yes | Pushes the question to whoever writes the call site. **Keeps R2's agreed signature** |
| **B.** Derived from the deployment | yes | No caller input, so no caller can get it wrong — but function text differs per region, and it changes R2's signature |
| **C.** One config row per deployment | yes | **Only candidate that is both caller-proof and identical text everywhere** — but also changes R2's signature |

### The failure modes are the real finding

| Input | Result | Caught? |
|---|---|---|
| Typo — `'Noth America'` | `NULL` key, **no error** | only by `NOT NULL` |
| Wrong case — `'NORTH AMERICA'` | `NULL` — **matching is case-sensitive** | only by `NOT NULL` |
| `NULL` region name | `NULL` | only by `NOT NULL` |
| **Valid name, wrong region — `'EU'` in the NA deployment** | **`2000000000000007` — structurally perfect, passes every test in this pack, and wrong** | **nothing** |

A nullable key column loaded **10 rows with 10 NULL keys and raised nothing**. With `NOT NULL`:
`DML operation … failed on column EMPLOYEE_ID with error: NULL result in a non-nullable column`.

**Two cheap controls close both holes, and they compose:**

1. **`NOT NULL` on the key column** — turns silent corruption into a failed load.
2. **A per-deployment guard** — the function verifies the requested region against a config row.
   Turns "wrong" into "nothing", which `NOT NULL` then turns into "stop".

**Final: INFORMED, NOT DECIDED.** Adopt both controls regardless of which candidate is chosen — which
means the mechanism decision does not block anything.

---

## C6 — What happens to keys that already exist?

| Option | Outcome under **offset** | Outcome under **concatenation** |
|---|---|---|
| **Leave them** | **SAFE** — 11,000/11,000/0; legacy keys all decode to region **0**, which does not exist; one magnitude test separates the eras with **zero misclassification** | **UNSAFE** — 999 collisions; new keys land *inside* the legacy range |
| **Backfill** | **HARMFUL — 3,000 duplicates** | n/a |

**Backfill failed worse than predicted.** We expected it to collide with *future* keys. It collided
with keys **already issued**: legacy key `1` backfills to `1000000000000001`, which a prefixed row
already holds. Advancing the sequence fixes only the forward half — it cannot undo the collision with
the 3,000 keys already out.

**Final: C6 DECIDED — leave legacy keys alone.** The cheapest option is also the correct one.
**Caveat for the build standard: region code 0 must never be allocated**, or legacy keys would start
decoding to a real region and lose their self-identifying property.

---

## The build standard this produces

1. `VOLATILE` mandatory; **never** `IMMUTABLE` or `MEMOIZABLE`.
2. Release check must assert **both** `VOLATILITY = 'VOLATILE'` **and** `IS_MEMOIZABLE = 'NO'`.
3. **Fully qualify the sequence** inside the function body.
4. **Create each function while the session is in its own schema**, or qualify the table too.
5. **Cast in the body**, never in the `RETURNS` clause.
6. Keys are unique but **not ordered and not gap-free** — never a row count, ordering or high-water
   mark. Do not set `ORDER` later.
7. `INCREMENT` must never change sign once keys are issued.
8. **`NOT NULL` on the key column.**
9. **Region code 0 must never be allocated.**
10. Field width **15**, pinned and never changed.


---

## The scheme decision — D5, taken 2026-11-04

**Chosen: Scheme B — fixed-width offset.** `region_code * 10^15 + seq.NEXTVAL`.

Three candidates were carried. They differ in one property only: **whether the region field has a
fixed width.** Everything below follows from that, and `SCHEMES_EXPLAINED.md` works each one
through step by step.

| Property a surrogate key needs | A. Digit concatenation | B. Fixed-width offset | C. Zero-padded text |
|---|---|---|---|
| **Unique across regions (R12)** | conditional — only while codes stay one digit | **by construction** | by construction |
| **Decodes to its region (R13)** | conditional — `LEFT(key,1)` breaks at two digits | **by construction** — `FLOOR(key/10^15)` | by construction — `LEFT(key,2)` |
| **Coexists with legacy keys (C6)** | **fails** — first key minted is `11`, 999 collisions | **passes** — smallest key is 10^15+1 | passes |
| **Orders by issue order in a VARCHAR column** | **fails** — `"110" < "19"` | **passes** — constant width | passes |
| **Survives a new region (R11)** | **fails silently** — no error raised | **non-event** | non-event |
| **Round-trips through `NUMBER`** | passes | **passes** | **fails** — loses the pad |
| **Enforced, not merely intended** | **fails** — needs codes ≤ 9 and a `START` floor, neither enforceable (`CHECK` is ignored) | **passes** | passes |

### Where A lacks, and what B does instead

**1. A's uniqueness is a property of the current data, not of the construction.** `"11"||"1"` and
`"1"||"11"` are both `111`. Nothing inside a key marks where the region ends, so the two parts can
only be separated if one has a known constant length — and under concatenation neither does. B
reserves 15 digit positions for the sequence, so the boundary is fixed by arithmetic.

**2. A fails two tests that have nothing to do with region count.** This is the part the
"codes will never exceed 9" assumption does not rescue:

- **C6.** A's first key is region 1, sequence 1 → `"11"` → **11**, which is already an existing
  `EMPLOYEE_ID`. Measured: 999 collisions with rows already in the table, in a **one-region** run.
  Fixable with a sequence `START` floor — but that fix is a hand-built minimum width, which is the
  property A is defined by not having.
- **Ordering in a `VARCHAR` column.** A's width varies with the value, so lexical order stops
  agreeing with issue order. `MAX(key)` is not the newest key and `WHERE key > :last_max` silently
  skips rows. B's width is constant, so the two orders agree.

**3. A's failure mode on a tenth region is silent.** New keys collide with region 1's, the insert
succeeds, no error is raised, and the damage sits in a primary key where it cannot afterwards be
told apart. Under B a tenth region is a non-event.

**4. A needs two permanent constraints that nothing enforces.** Snowflake accepts `CHECK` and does
not enforce it, so "region code ≤ 9" has to live in the UDF guard or in the map's load process, and
the `START` floor in a deployment convention. B needs neither.

### What A wins, stated fairly

A produces no leading zeros, so it round-trips through `NUMBER` losslessly. That is a real
advantage over **C**, which loses the pad. It is **not** an advantage over B, which has no leading
zeros either — so choosing B gives up nothing A offered.

### How B serves a non-numeric target

Q3 established the target column type varies. B handles it by casting the same expression at the
call site, beside the 27 casts Q2 already performs:

```sql
CAST(key_b(:region) AS NUMBER(38,0))   -- numeric target
CAST(key_b(:region) AS VARCHAR(20))    -- text target
```

The cast cannot move inside the function: the return type is declared and cannot be a parameter
(`IDENTIFIER()` takes a literal, session variable or bind, never an argument), and a declared
`VARCHAR(n)` length is accepted and then ignored, so the width is enforced by the target column.

**Open, and it does not change D5:** whether anything orders, ranges or watermarks on the surrogate
key. A yes confirms the fourth row above as a live defect rather than a latent one.
