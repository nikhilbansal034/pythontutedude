# R10 — RESULT: **VALIDATED**, with one gap this run did not close

**Run**: 2026-11-03 21:18 UTC, `LM_POC_DB.POC_SCHEMA`.
**Evidence**: `../R10_04_r10_concurrency_20261103-211858.json` — 23 statements, verbatim.
**Script**: `04_r10_concurrency.sql`.

**90,000 keys across six concurrent sessions in two phases. Zero duplicates.**

| Test | Checked | Result | Verdict |
|---|---|---|---|
| T4.2 | 3 tables, 1 function, 1 sequence, concurrent | 60,000 / 60,000 distinct / **0 dups** / 3 sessions | **PASS** |
| T4.2b | Any key issued twice? | zero rows | **PASS** |
| T4.3 | Consumption vs rows | 99,300 values for 60,000 rows → **1.655/row** | RECORDED |
| T4.4 | `IMMUTABLE` negative test | created; 1000 rows → 1000 distinct, **no folding** | RECORDED |
| T4.5 | `MEMOIZABLE` negative test | created; 1000 rows → 1000 distinct, **no folding** | RECORDED |
| T4.6 | Shipping function declaration | `VOLATILE` / `IS_MEMOIZABLE = NO` | **PASS** |
| T4.7 | 3 regions, concurrent, one target table | 30,000 / 30,000 / **0 dups** | **PASS** |
| T4.7b | Does every key decode to its region? | 10,000 × 3, zero misattribution | **PASS** |

## Concurrency was measured, not assumed — and that mattered

The script told you to open three worksheets. **That procedure would have silently proved nothing.**
Three CLI sessions launched together established their connections **up to 4 seconds apart**, while a
20,000-row insert takes ~1.5 seconds. The inserts would have run consecutively while looking parallel.

Worse, my own guard would not have caught it: `sessions_involved` still returns 3, because three
distinct sessions did contribute rows.

A barrier table was used instead — each session logs `CONNECTED`, polls until released, then all three
resume within one 250 ms poll interval. Measured overlap:

| Phase | Started within | Overlap | Individual durations |
|---|---|---|---|
| T4.1 | 231 ms | **1319 ms** | 1398 / 1586 / 1476 ms |
| T4.7 | 18 ms | **890 ms** | 908 / 991 / 961 ms |

**Carry this into the script**: the overlap measurement must become a mandatory part of the procedure.
A human clicking Run in three Snowsight worksheets introduces exactly the stagger described, and the
existing `sessions_involved` guard will report PASS regardless. That is a defect in the script as
written, not in the result.

## Invocation count: narrowed, not fully closed

60,000 rows consumed 99,300 sequence values — **1.655 per row**.

- 60,000 distinct keys landed, so the function ran **at least** once per row.
- Two invocations per row would have required **≥120,000** values. It consumed 99,300.
  **Double invocation is therefore ruled out.**
- The residual 39,300 is consistent with block reservation across three concurrent sessions
  (see R2's 100-value blocks), not with discarded extra calls.

So invocation is bounded in **[1.0, 1.655]** per row. The exact figure cannot be separated from
reservation waste by this method. For R10's purposes that is enough: no clean multiple, no duplicates.

## The negative tests did not reproduce — and that is not permission

`IMMUTABLE` and `MEMOIZABLE` both **created without error** and both returned 1000 distinct keys for
1000 rows. **No folding on this run.**

**This must not be read as IMMUTABLE being safe.** Snowflake documents that the guarantee "is not
checked" and that misdeclaring it "will result in **undefined behavior**". Undefined behaviour that
happens not to bite on one warehouse, at one scale, on one release, is still undefined — and every
row in this workload passes *identical arguments*, which is precisely the condition that invites
folding.

The prohibition rests on the documentation plus the T4.6 check, **not** on an observed failure.

## `MEMOIZABLE` is orthogonal to volatility — a CI check must test both columns

| Function | `VOLATILITY` | `IS_MEMOIZABLE` |
|---|---|---|
| `W6_REGIONAL_KEY` (shipping) | VOLATILE | NO |
| `W6_REGIONAL_KEY_IMMUTABLE` | IMMUTABLE | NO |
| `W6_REGIONAL_KEY_MEMO` | **VOLATILE** | **YES** |

A memoizable function reports `VOLATILITY = 'VOLATILE'`. **A release check asserting volatility alone
would wave it straight through.** T4.6's query tests both and should be lifted verbatim into CI.

## The gap this run did not close

`w6_regional_key` reads **one shared sequence** for all three regions. So T4.7's zero duplicates were
guaranteed by the sequence itself — the prefix contributed nothing to uniqueness.

**Under decision D4 the production topology is the opposite**: each table has its own sequence per
region, every one starting at 1. There, the prefix is the *only* thing separating North America's
employee 1 from EU's.

T4.7 as run therefore validates the plumbing — concurrent calls, one function, correct decode — but
**not** the case where the prefix is load-bearing. That needs a short follow-up: three sequences each
starting at 1, one per region, run concurrently, asserting zero duplicates and correct decode. The
arithmetic is already simulated locally (`explore/r10_concurrency_sim.py` §7) but has never run in
Snowflake.

## Conditions on the verdict

1. The function **must** be `VOLATILE`; `IMMUTABLE` and `MEMOIZABLE` are prohibited.
2. `INCREMENT` must never change sign once keys are issued.
3. Sequences must stay `NOORDER` — do not set `ORDER` later to tidy the values.
4. Keys are unique but **not ordered and not gapless**. They must never be used to infer insertion
   order, as a high-water mark, or as a row count.
