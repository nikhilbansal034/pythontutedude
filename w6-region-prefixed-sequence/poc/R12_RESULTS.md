# R12 — RESULT: **NOT PROVEN**. The test could not create the condition it exists to test.

**Run**: 2026-11-03 21:47 UTC, `LM_POC_DB.POC_SCHEMA`.
**Evidence**: `../R12_05_r12_per_region_sequences_20261103-214743.json` — 31 statements, four added as
diagnostics when T5.1 hit its own UNEXPECTED branch.
**Script**: `05_r12_per_region_sequences.sql` — **defective, superseded by `06`**.

| Test | Checked | Result | Verdict |
|---|---|---|---|
| T5.1 | Do the regions collide without a prefix? | 1500 rows, **0 collisions** | **PREMISE FAILED** |
| T5.2a | Prefixed keys, 3 concurrent sessions | 30,000 / 30,000 / 0 dups | **PASS, BUT VACUOUS** |
| T5.2c | Did the regions reuse sequence numbers? | disjoint ranges | **PREMISE FAILED** |
| T5.3 | Does every key decode to its region? | 10,000 × 3, zero misattribution | **PASS — sound** |
| T5.4 | Concatenation width spread | keys 2–5 digits wide | **PASS — sound** |

**R13 is proven.** **R12 is not**, and `05` cannot prove it.

## What went wrong — and it is my script's fault, not Snowflake's

The regions were meant to issue overlapping raw numbers so the prefix would be the only separator.
They never did:

| | raw range drawn |
|---|---|
| North America | 1 – 500 |
| EU | 601 – 1100 |
| APAC | 1101 – 1600 |

Only one region ever started at 1. The cause is visible in the sequence metadata — after 1500 rows
(500 per region) **all three sequences stood at exactly `NEXT_VALUE = 2601`**, and after T5.4's 6,000
rows all three stood at exactly `7101`.

They moved in **lockstep**, because `05`'s function names all three sequences in one `CASE`:

```sql
+ CASE region_name
      WHEN 'North America' THEN w6_emp_seq_na.NEXTVAL
      WHEN 'EU'            THEN w6_emp_seq_eu.NEXTVAL
      WHEN 'APAC'          THEN w6_emp_seq_apac.NEXTVAL
  END
```

R2's finding F4 already established that **every sequence referenced in a statement reserves a block
regardless of which arm is taken**. So every row advanced all three. The sequences were per-region in
name only; in behaviour they were one counter consumed three times.

## The vacuous pass, and why the guard missed it

T5.2a returned `30000 / 30000 / 0 / 3 / PASS`. The added diagnostic at seq 22 shows what that was
worth: of 30,000 raw sequence values, **zero were shared by more than one region**. Strip the prefix
entirely and you still get 30,000 unique keys.

**This is the same defect as `04`'s T4.7, arriving by a different route** — T4.7 was vacuous because
one sequence was shared by design; T5.2 was vacuous because three nominally separate sequences
behaved as one. In both cases the assertion was *insensitive to the thing being tested*.

Note that T5.2a's own `INVALID` guard did not catch it. It checks session count, which was
legitimately 3. **A guard that checks the test ran is not a guard that the test could have failed.**

## Correcting finding F16 — the design alarm is overstated

The run log concludes that "the single-function branch selector cannot deliver per-region numbering,
and the signature `f(region_name, sequence_name)` would need one function per region-sequence pair or
a different mechanism entirely."

**That reads the problem back into a design that does not have it.** The branch selector R2 settled on
cases over **table sequences**, not regions:

```sql
CASE sequence_name
    WHEN 'EMPLOYEE_SEQ' THEN w6_employee_seq.NEXTVAL
    WHEN 'JOB_SEQ'      THEN w6_job_seq.NEXTVAL
END
```

The three-arm case over *regions* was something I invented for `05`, and it is not how the design
works. In production each region runs **its own Zone 2 deployment**. The same function text is
deployed to each, and because the sequence reference is unqualified it resolves "in the schema
containing the function" (R8, proven at T2.1b). **North America's function never names EU's
sequence**, so no cross-region lockstep can occur.

What F14 *does* carry into production is narrower and already known: within one deployment, every
**table** sequence named in the function advances together — R2's F4, bounded at ~100 × arms per
statement. Tolerable, and already in the build standard.

So the fix is to the test, not to the design: **the test must simulate separate deployments.**

## What `06` does differently

`06_r12_independent_region_deployments.sql` gives each region **its own schema**, its own sequence and
its own copy of the identical function text — which is what deployment actually looks like, and which
exercises R8's unqualified-resolution rule at the same time. Each function body names exactly one
sequence, so all three genuinely sit at 1 and issue overlapping raw values.

It also carries the lesson from both failures: **T6.1 and T6.3 are sensitivity checks that must pass
before any uniqueness result is believed.** If the raw values do not overlap, `06` reports `VACUOUS`
rather than `PASS`.

## Also worth fixing: F17

`05` says "THREE SESSIONS NEEDED for T5.2 and T5.4" but writes T5.4 as a single `UNION ALL` statement.
The script was followed correctly; the inconsistency is mine. T5.4's purpose was the width spread, not
concurrency, so nothing is lost — but a future reader would have believed it carried concurrency
evidence. Corrected in `06`.
