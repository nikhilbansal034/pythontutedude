# W6 — where each of the 13 requirements stands

As at 2026-11-04, after **nine** Snowflake runs (R3, R2, R6, R10, R12 ×3, R11/C3, C6, C5, C4).
Sources: `poc/R*_RESULTS.md` and the run logs in this folder. `requirement.md` is the spec;
`feasibility.md` is the per-requirement analysis against documentation; this file is the rollup.

## Summary

| | |
|---|---|
| **Proven in Snowflake** | R1, R2, R3, R4, R5, R6, R7, R10, **R11**, R12, R13 |
| **Resolved, with a condition** | **R8** — works, but only with a fully-qualified sequence |
| **Closed as already satisfied** | **R9** — pending one confirmation from Nidwika |
| **Decided by measurement** | **C3** → fixed-width offset, width 15 · **C6** → leave legacy keys alone |
| **Informed, not decided** | **C5** (IDMC choice) · **C4** (question for Nidwika) |

**All 13 requirements are closed.** Nothing further is blocked on a test.

Two companion documents carry the detail:
[`OPTIONS_AND_OUTCOMES.md`](OPTIONS_AND_OUTCOMES.md) — every alternative tried, its measured outcome,
and what the docs say, per requirement. Built for the deck.
[`QUESTIONS_FOR_NIDWIKA.md`](QUESTIONS_FOR_NIDWIKA.md) — the seven things we need from her.

---

## Requirement by requirement

| # | Requirement | Status | Evidence / why |
|---|---|---|---|
| **R1** | ETL calls a reusable function instead of `<seq>.NEXTVAL` | **PROVEN** | R3 T1.6 — the function inside a `MERGE … USING` projection mirroring Q2 line 50 inserted 3 rows, 3 distinct IDs. Exercised again throughout R6 and R10 |
| **R2** | Signature takes region name **and** sequence name | **SATISFIED, with a workaround** | R2 T2.3a/b — branch selector works, including the name varying per row. T2.2a/b — registry indirection refused at CREATE. **Cost:** the function must name every sequence literally, so a new table edits the function |
| **R3** | Function gets the next value from the named sequence | **PROVEN** | R3 T1.2–T1.4, T1.6. 100 rows → 100 distinct keys, 0 duplicates. The silent-failure case (constant-folded body) did not occur |
| **R4** | Function resolves region code from region name | **PROVEN** | Exercised in R6 T3.4, R10 and R12 v3, where all 30,000 keys decoded to the correct region. **Condition (F23):** create the function while the session is in its own schema, or the unqualified table binds elsewhere |
| **R5** | Function combines region code with sequence value | **PROVEN** | R6 T3.4 (offset) and T3.5b (concatenation). Both produce a valid key. **Which scheme is C3, still open** |
| **R6** | Returns the target's datatype; cast inside the function | **PROVEN** | R6 T3.1–T3.6b. Declared precision/scale **ignored**; declared **base type enforced at CREATE**; body cast delivers the type; key lands intact in `NUMBER(38,0)` |
| **R7** | Mapping lives in a table | **PROVEN** | Same evidence and the same F23 condition as R4 |
| **R8** | One code base, unchanged across environments | **RESOLVED, with a condition** | Works **only with a fully-qualified sequence**. R12 v3 T7.2: three calls from three different caller schemas, and only the function's own sequence advanced. The text is then not *literally* identical per region — which is exactly how Q2 already deploys, via `$$inout_param_*` substitution |
| **R9** | Region applied Zone 1 → Zone 2, not later | **SETTLED, no test needed** | Q2 line 50 already mints the key inside the Zone 1 → Zone 2 journey. Nothing to relocate. Needs only C4 — Nidwika confirming Q2 was meant, not Q1 |
| **R10** | Correct when called concurrently by multiple tables | **PROVEN** | R10 T4.2 — 60,000 keys, 3 concurrent sessions with **measured overlap**, 0 duplicates. Invocation bounded to [1.0, 1.655]/row. Conditions attached (below) |
| **R11** | New regions without a code change | **PROVEN** | Grew 3 → 12 regions with **zero lines of code**; the function's `CREATED` equals its `LAST_ALTERED` to the millisecond. Adding a **table**, by contrast, does edit the function's `CASE` |
| **R12** | Every key unique across regions, for all time | **PROVEN** | R12 v3. All three regions drew raw `1–500` (**1000 collisions**, so the prefix had real work to do); 30,000 prefixed keys, 3 measured-concurrent sessions, **0 duplicates**; 10,000 raw values each issued in **all three** regions. Without the prefix: 20,000 duplicates |
| **R13** | Region recoverable from the key without a join | **PROVEN (strongest form)** | R12 v3 T7.5 — 10,000 × 3, zero misattribution, **while the raw values collide**. The earlier confirmations ran on non-colliding data |

---

## Why the three pending items matter, against the original requirement

### R12 — closed, and it was the requirement

§3 asks for one thing: the identifier stored in Zone 2 must still work when regions consolidate into
the global database. Everything else is machinery.

It took four attempts because the first three could not fail:

| Attempt | Premise established? | Result |
|---|---|---|
| `04` T4.7 | No — one shared sequence | vacuous PASS |
| `05` T5.2 | No — three sequences in lockstep | vacuous PASS |
| `06` T6.1 | No — unqualified sequences followed the caller | halted at its gate |
| **`07` T7.1** | **Yes — 1000 collisions** | **genuine PASS** |

The proof in one line:

```
raw value 1  ->  1000000000000001 (NA) | 2000000000000001 (EU) | 3000000000000001 (APAC)
```

All three regions issued raw value `1`. Without the prefix the 30,000 keys would have held **20,000
duplicates**; with it, zero. D4's intent realised literally.

### R8 — resolved, but the promise changed

R8 read as "one code base, unchanged". The mechanism assumed — unqualified objects resolving in the
function's schema — **does not hold for sequences**: they re-resolve against the caller's current
schema on every call, so an unqualified reference would make the key depend on session
configuration.

Fully qualified, R12 v3 T7.2 shows the key is caller-independent: three calls from three different
schemas, only the function's own sequence moved.

R8 is met — as **one template substituted at deploy time**, not one literal text. Q2 already works
that way, so nothing new is introduced; it just needs saying rather than assuming.

### R11 — proven, and it settled C3 with it

Growing from three regions to twelve took **twelve rows of data and zero lines of code**. The
objective half is that `CREATED = LAST_ALTERED` on the function, to the millisecond.

Because that run introduced **two-digit region codes** for the first time, it also discriminated the
two prefix schemes, which had been indistinguishable at three single-digit codes:

| | Digit concatenation | Fixed-width offset |
|---|---|---|
| Duplicate primary keys at 12 regions | **198** | **0** |
| Keys decoding correctly | 3,600 / 4,800 | **4,800 / 4,800** |

```
key 111  ->  Benelux employee 1  |  North America employee 11
```

**C3 is therefore decided by data: fixed-width offset, width 15.**

One consequence to carry: adding a **region** is a data change, but adding a **table** edits the
function's `CASE` arms. Still one place, but someone owns it — see Q6 in
[`QUESTIONS_FOR_NIDWIKA.md`](QUESTIONS_FOR_NIDWIKA.md).

## What is left to conclude the POC

**Nothing is blocked on a test.** What remains is decisions and packaging:

| | Owner |
|---|---|
| Confirm C4 (Q1 vs Q2), and that R12/R13 are genuine requirements | **Nidwika** |
| Name the downstream consumers of `EMPLOYEE_ID` and their datatypes — this pins the field width permanently | **Nidwika / team** |
| Choose the C5 provenance mechanism, and adopt the two controls | **Nidwika / IDMC** |
| Ratify C3, C6 and "region code 0 is never allocated" | **team** |
| Decide whether the release checks become standing gates | **team** |
| Rebuild the deck from `OPTIONS_AND_OUTCOMES.md` | us, on request |
| Clean up the leftover POC objects in `LM_POC_DB` | us |
| Raise the sequence name-resolution discrepancy with Snowflake support | us |

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
7. **Create each function while the session is in that function's own schema** — or qualify the table
   too. Unqualified names resolve against the *current* schema at CREATE time, so a same-named table
   in the deploying session's schema would be bound silently (F23).

---

## A caveat on the word "proven"

Three assertions in this pack passed while being **insensitive to the thing under test** — R2's
T2.1b, R10's T4.7, R12's T5.2. Two underpinned conclusions reported as settled, and one (T2.1b)
produced a build-standard decision since reversed. A fourth, R12 v3's T7.2, produced a **false FAIL**
for the mirror-image reason: an absolute threshold where a before/after comparison was needed. Both
script defects are now fixed.

R10's overall verdict is unaffected: its headline result, T4.2, is a genuine concurrency test of the
wrapper. Only T4.7's cross-region claim was vacuous, and that claim belongs to R12.

The lesson is in the pack README: **assert the precondition, not just the postcondition.** Only `06`
did, and only `06` caught itself.
