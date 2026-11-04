# W6 — where each of the 13 requirements stands

As at 2026-11-03, after five Snowflake runs (R3, R2, R6, R10, R12 ×2).
Sources: `poc/R*_RESULTS.md` and the run logs in this folder. `requirement.md` is the spec;
`feasibility.md` is the per-requirement analysis against documentation; this file is the rollup.

## Summary

| | |
|---|---|
| **Proven in Snowflake** | R1, R2, R3, R5, R6, R10, R13 — and R4, R7 exercised within those runs |
| **Settled without a test** | R9 (true by reading Q2) — needs Nidwika's confirmation only |
| **Broken, needs rework** | **R8** — the mechanism it relied on does not exist for sequences |
| **Never tested** | **R11** — no run ever added a fourth region |
| **Not proven after 3 attempts** | **R12** — and it is the requirement the whole design exists to deliver |

---

## Requirement by requirement

| # | Requirement | Status | Evidence / why |
|---|---|---|---|
| **R1** | ETL calls a reusable function instead of `<seq>.NEXTVAL` | **PROVEN** | R3 T1.6 — the function inside a `MERGE … USING` projection mirroring Q2 line 50 inserted 3 rows, 3 distinct IDs. Exercised again throughout R6 and R10 |
| **R2** | Signature takes region name **and** sequence name | **SATISFIED, with a workaround** | R2 T2.3a/b — branch selector works, including the name varying per row. T2.2a/b — registry indirection refused at CREATE. **Cost:** the function must name every sequence literally, so a new table edits the function |
| **R3** | Function gets the next value from the named sequence | **PROVEN** | R3 T1.2–T1.4, T1.6. 100 rows → 100 distinct keys, 0 duplicates. The silent-failure case (constant-folded body) did not occur |
| **R4** | Function resolves region code from region name | **PROVEN (exercised)** | No dedicated test, but the function body reads the mapping table in R6 T3.4 and R10, and every key decoded to the correct region. Working, not merely documented |
| **R5** | Function combines region code with sequence value | **PROVEN** | R6 T3.4 (offset) and T3.5b (concatenation). Both produce a valid key. **Which scheme is C3, still open** |
| **R6** | Returns the target's datatype; cast inside the function | **PROVEN** | R6 T3.1–T3.6b. Declared precision/scale **ignored**; declared **base type enforced at CREATE**; body cast delivers the type; key lands intact in `NUMBER(38,0)` |
| **R7** | Mapping lives in a table | **PROVEN (exercised)** | Same evidence as R4 |
| **R8** | One code base, unchanged across environments | **BROKEN — needs rework** | The mechanism relied on ("unqualified objects resolve in the function's schema") **does not hold for sequences** — they resolve in the **caller's** schema. R2 T2.1b could not detect this because function, sequence and caller shared a schema. See below |
| **R9** | Region applied Zone 1 → Zone 2, not later | **SETTLED, no test needed** | Q2 line 50 already mints the key inside the Zone 1 → Zone 2 journey. Nothing to relocate. Needs only C4 — Nidwika confirming Q2 was meant, not Q1 |
| **R10** | Correct when called concurrently by multiple tables | **PROVEN** | R10 T4.2 — 60,000 keys, 3 concurrent sessions with **measured overlap**, 0 duplicates. Invocation bounded to [1.0, 1.655]/row. Conditions attached (below) |
| **R11** | New regions without a code change | **NEVER TESTED** | Every run used exactly North America, EU, APAC. No run has ever added a fourth region. Logically it is an `INSERT`, but that is an assumption, not a result |
| **R12** | Every key unique across regions, for all time | **NOT PROVEN** | Three attempts, each failing to create the condition it tests. See below |
| **R13** | Region recoverable from the key without a join | **PROVEN** | R10 T4.7b and R12 T5.3 — 30,000 keys across three regions under measured concurrency, zero misattribution, twice |

---

## Why the three pending items matter, against the original requirement

### R12 — this *is* the requirement

Everything else is machinery. The transcript's §3 asks for one thing: that the identifier stored in
Zone 2 **still works when regions are consolidated into the global database**, so a bad record can be
traced back without the UUID or prefix-stripping logic.

**We have thoroughly proven the machinery and never once proven the outcome it exists for.**

Three attempts, each passing or halting for a different reason:

| Attempt | What happened |
|---|---|
| `04` T4.7 | All regions shared one sequence → uniqueness came from the sequence; **the prefix contributed nothing**. Reported PASS |
| `05` T5.2 | Three per-region sequences moved in **lockstep** (one function body named all three), so they never issued the same raw number. Reported PASS |
| `06` T6.1 | **Halted at its own gate** — and found why: an unqualified sequence follows the *caller's* schema, so all three regional functions silently drew from one leftover sequence |

In the first two, **removing the region prefix entirely would not have changed the result.** That is
the definition of a test that proves nothing.

`poc/07` is the fourth attempt: fully-qualified sequences, so the three genuinely start at 1 and
collide; plus gates that report `VACUOUS` rather than `PASS` when the premise fails.

### R8 — a nice-to-have turned into a correctness hazard

R8 reads as portability: one function, deployable anywhere. We thought it was free, because
Snowflake's *Name resolution* page says "all unqualified objects in a view or UDF definition will be
resolved in the view's or UDF's schema only".

**Sequences do not obey that.** They resolve in the **caller's current schema at run time** — proven
by calling a function from a schema with no same-named sequence and getting `invalid identifier`,
while the function's own schema had one.

So the risk is not "the function is less portable than hoped". It is: **the same function, invoked
from two differently-configured sessions, silently draws from two different sequences** — or fails.
For a surrogate key that is a data-integrity defect, and nothing in the key would reveal it.

The fix is to fully qualify the sequence inside the body, which means the function DDL becomes a
**template substituted at deploy time** rather than one literal text. That is already how Q2 works
(`$$inout_param_hr_database_name...EMPLOYEE_SEQ`), so it is not new machinery — but it is a change to
what R8 promises, and it should be stated rather than assumed.

### R11 — untested, and coupled to the C3 decision

§2 says the mapping must accommodate further regions without code change. Every run used the same
three. Nobody has added a fourth.

It matters more than it looks because **R11 and C3 are coupled**:

- while region codes stay single-digit (1–9), digit concatenation and fixed-width offset behave
  identically
- at a **two-digit** region code, concatenation collides — `concat(1,11)` and `concat(11,1)` are both
  `111`

So "will there ever be a tenth region?" is not an idle question: it decides whether the prefix scheme
choice is cosmetic or load-bearing. Testing R11 is cheap (insert a row, draw keys) and it is the only
requirement with **no evidence at all** behind it.

---

## Conditions attached to the things that *are* proven

These came out of the runs and belong in the build standard regardless of what remains:

1. **`VOLATILE` is mandatory**; `IMMUTABLE` and `MEMOIZABLE` are prohibited. Neither folded on the
   test run, but Snowflake calls misdeclared `IMMUTABLE` "undefined behavior", and every row in this
   workload passes identical arguments — the exact folding condition.
2. **A CI check must assert both `VOLATILITY = 'VOLATILE'` and `IS_MEMOIZABLE = 'NO'`.** A memoizable
   function reports `VOLATILITY = VOLATILE`, so checking volatility alone passes it.
3. **Fully qualify sequences inside the function body.** See R8.
4. **The cast goes in the body**, never the `RETURNS` clause — declared precision and scale are
   ignored.
5. **Keys are unique but not ordered and not gap-free.** Sequences reserve ~100 values per referenced
   sequence per statement, and are `NOORDER` by default. Nothing downstream may read a key as a row
   count, an ordering, or a high-water mark. Do not set `ORDER` later to tidy them — `NOORDER` is
   what makes concurrent inserts fast.
6. **`INCREMENT` must never change sign** once keys are issued.

---

## A caveat on the word "proven"

Three assertions in this pack passed while being **insensitive to the thing under test** — R2's
T2.1b, R10's T4.7, R12's T5.2. Two of them underpinned conclusions reported as settled, and one
(T2.1b) produced a build-standard decision that has since been reversed.

R10's overall verdict is unaffected: its headline result, T4.2, is a genuine concurrency test of the
wrapper. Only T4.7's cross-region claim was vacuous, and that claim belongs to R12.

The lesson is in the pack README: **assert the precondition, not just the postcondition.** Only `06`
did, and only `06` caught itself.
