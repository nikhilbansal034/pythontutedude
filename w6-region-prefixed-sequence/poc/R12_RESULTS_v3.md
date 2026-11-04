# R12 — **PROVEN**. Fourth attempt, and the first where the test could have failed.

**Run**: 2026-11-03 22:43 UTC. **Evidence**:
`../R12v3_07_r12_qualified_sequences_20261103-224310.json` — 56 statements.
**Script**: `07_r12_qualified_sequences.sql`.

| Test | Checked | Result | Verdict |
|---|---|---|---|
| T7.0 | Qualified/unqualified asymmetry | qualified drew NA, unqualified drew EU | **CONFIRMED** |
| T7.1 | **Sensitivity** — do regions issue the same raw numbers? | all three drew `1–500`; 1500 rows, **500 distinct, 1000 collisions** | **GATE OPENED** |
| T7.2 | Caller-schema independence | NA advanced, EU and APAC untouched | **PASS** (after correction) |
| T7.3a | Prefixed keys, 3 concurrent sessions | **30,000 / 30,000 / 0 duplicates / 3** | **PASS** |
| T7.3b | Measured overlap | started within 115 ms, overlapped **1092 ms** | **PASS** |
| T7.4 | **Sensitivity** — was the prefix load-bearing? | **10,000 raw values each shared by all 3 regions** | **SOUND** |
| T7.5 | Every key decodes to its region | 10,000 × 3, zero misattribution | **PASS** |

## Why this one counts and the previous three did not

For the first time, **both the precondition and the postcondition hold**.

```
raw value 1  ->  1000000000000001   (North America)
                 2000000000000001   (EU)
                 3000000000000001   (APAC)
```

Raw value `1` was issued in **all three regions** and became three distinct keys. Same for 2, 5000
and 10000. **Without the prefix, the 30,000 keys would have contained 20,000 duplicates.** With it,
zero.

That is D4's intent realised literally — "North America's employee 1 and EU's employee 1 both exist"
— and it is the property §3 of the transcript asks for.

| Attempt | Premise established? | Result |
|---|---|---|
| `04` T4.7 | No — one shared sequence | vacuous PASS |
| `05` T5.2 | No — sequences in lockstep | vacuous PASS |
| `06` T6.1 | No — unqualified sequences followed the caller | halted at gate |
| **`07` T7.1** | **Yes — 1000 collisions** | **genuine PASS** |

**R13 is also reconfirmed, and more strongly than before**: the earlier confirmations (`04` T4.7b,
`05` T5.3) ran on data where raw values never collided. This one decodes correctly *while* the raw
values collide.

## F23 — the resolution rule, now stated properly

`06` found that sequences follow the caller. This run refines it into one rule that explains
everything, including two CREATE failures:

> **Unqualified names are resolved against the session's current schema at CREATE time.** Tables are
> then **permanently bound** to what was resolved. Sequences are **not bound** — the identifier is
> **re-resolved on every invocation** against the caller's current schema.

Evidence: creating a function in `W6V7_NA` while sitting in `POC_SCHEMA` failed twice — once on the
unqualified table (`Object 'LM_POC_DB.POC_SCHEMA.REGION_MAP_V7' does not exist`) and once on the
unqualified sequence (`invalid identifier 'EMP_SEQ_V7.NEXTVAL'`). Both succeeded unchanged once the
session's current schema was the function's own.

`06`'s "tables resolve to the function's schema" only *looked* that way because `06` created each
function while sitting in its own schema.

**Two build-standard rules follow, not one:**

1. **Always fully qualify the sequence** inside a UDF body.
2. **Create each function while the session is in that function's own schema**, so unqualified
   tables bind where intended — or qualify the table too.

Rule 2 is a real deployment hazard, not a nicety: if the deploying session's schema happens to hold
a same-named table, the function binds to **that** one silently and the CREATE succeeds.

## F24 — a defect in my own script, fixed

T7.2's verdict flagged EU and APAC as `FAIL - a foreign sequence advanced` on a `NEXT_VALUE > 1`
test. They read `601` because T7.1 had legitimately drawn 500 from each, and the script reset only
NA. **An absolute threshold where a before/after comparison was needed.**

The corrected measurement (reset all three, then call from three different caller schemas) gives the
real answer:

| | after three calls from EU, APAC and POC_SCHEMA |
|---|---|
| `W6V7_NA` | `201` — **advanced; the function's own sequence** |
| `W6V7_EU` | `1` — untouched |
| `W6V7_APAC` | `1` — untouched |

**Caller-schema independence holds.** That is the property that makes qualification safe to ship.
The script is fixed so a future reader does not see a false FAIL.

## F26 — the process changes worked

`06`'s near-miss (a leftover `W6_EMPLOYEE_SEQ` from the R2 run being silently consumed) did not
recur. The `_V7` suffixes and the opening cleanup block prevented it **by design rather than by
luck**. Retain both for future packs.

## What this leaves open

**R11 — still never tested.** Every run, including this one, used exactly North America, EU and
APAC. No run has ever added a fourth region.

**C3 — still a decision.** This run proves the *fixed-width offset* scheme end to end under the
colliding topology. Digit concatenation has only ever been tested where region codes are single
digits and so cannot collide. The two are indistinguishable at three regions and diverge at a tenth.
