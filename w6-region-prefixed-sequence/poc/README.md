# W6 POC pack

Four scripts, run in order. Each is self-contained: it creates what it needs in a scratch
schema, numbers every test, and tears down after itself.

| Script | Requirement | Status |
|---|---|---|
| [`01_r3_sequence_in_udf.sql`](01_r3_sequence_in_udf.sql) | **R3** — may a UDF body read a sequence? | **DONE — passed 2026-11-03.** [`R3_RESULTS.md`](R3_RESULTS.md) |
| [`02_r2_sequence_name_binding.sql`](02_r2_sequence_name_binding.sql) | **R2** — can the sequence be chosen by a run-time name? | **DONE — satisfied.** [`R2_RESULTS.md`](R2_RESULTS.md) |
| [`03_r6_return_datatype.sql`](03_r6_return_datatype.sql) | **R6 / C7** — does the function return the target's datatype? | **DONE — satisfied.** [`R6_RESULTS.md`](R6_RESULTS.md) |
| [`04_r10_concurrency.sql`](04_r10_concurrency.sql) | **R10** — concurrency and volatility | **DONE — validated.** [`R10_RESULTS.md`](R10_RESULTS.md) |
| [`05_r12_per_region_sequences.sql`](05_r12_per_region_sequences.sql) | **R12/R13** — uniqueness when the prefix is load-bearing | Ready to run — closes 04's gap |

## Before you start

Each script begins with two lines to edit:

```sql
USE DATABASE LM_POC_DB;
USE SCHEMA POC_SCHEMA;
```

Point them at a **scratch** schema. Nothing touches real objects, and every script ends with a
teardown. You need `CREATE SEQUENCE`, `CREATE FUNCTION` and `CREATE TABLE` there.

`03` additionally hard-codes the field width `1000000000000000` (10^15) in several places. If C3
settles on a different width, change it everywhere in that file before running.

## How to capture evidence

Every test ends in a query with a **`VERDICT`** column, so one screenshot per numbered test is
enough — the verdict reads PASS or FAIL without interpretation.

Three places where **the failure is the result**, so please capture the error text itself rather
than skipping past it:

- **`02` T2.2a and T2.2b** — the registry-table indirection is *expected* to fail. The error message
  is the evidence that a run-time value cannot become an object reference.
- **`03` T3.1 and T3.2** — the declared return type is *expected* to be ignored. That is the
  documented behaviour R6 has to work around, not a defect.
- **`04` T4.4 and T4.5** — `IMMUTABLE` and `MEMOIZABLE` are *expected* to fold the result. Seeing it
  is what turns the prohibition from an assertion into evidence.

A `RECORD` ruler instead of `PASS/FAIL` means there is no right answer — note the number and move
on.

## Two things learned from the R3 run, applied throughout

**Never measure sequence consumption with a bare `NEXTVAL`.** R3's T1.5 did, and got a misleading
answer: direct calls and UDF calls draw from different reserved ranges under NOORDER, so the two
counters move independently. `02` and `04` read `INFORMATION_SCHEMA.SEQUENCES.NEXT_VALUE` instead,
which reports the next value without consuming one.

**`CREATE` succeeding is not a pass.** R3's real risk was the function creating cleanly and then
returning the *same* value for every row — a silent failure. Every test that could fail that way
counts distinct values against row count rather than just checking the statement ran.

## Order, and why

`01` ran first because everything else presupposed it. With R3 proven, the remaining three are
independent and can run in any order — though `04` is the longest and needs three worksheets open
at once for its concurrent parts.

**The three-worksheet procedure is not sufficient on its own.** The R10 run measured sessions
connecting up to **4 seconds apart** while a 20,000-row insert takes ~1.5s — so three worksheets
started by hand can run consecutively while looking parallel. Worse, `sessions_involved` still
returns 3, so that guard does **not** catch it. Any concurrency claim must come with a measured
overlap (start/end timestamps per session, intersected), or be reported as unmeasured. This applies
to `04` and `05` alike.
