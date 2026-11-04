# W6 POC pack

Four scripts, run in order. Each is self-contained: it creates what it needs in a scratch
schema, numbers every test, and tears down after itself.

| Script | Requirement | Status |
|---|---|---|
| [`01_r3_sequence_in_udf.sql`](01_r3_sequence_in_udf.sql) | **R3** — may a UDF body read a sequence? | **DONE — passed 2026-11-03.** [`R3_RESULTS.md`](R3_RESULTS.md) |
| [`02_r2_sequence_name_binding.sql`](02_r2_sequence_name_binding.sql) | **R2** — can the sequence be chosen by a run-time name? | **DONE — satisfied.** [`R2_RESULTS.md`](R2_RESULTS.md) |
| [`03_r6_return_datatype.sql`](03_r6_return_datatype.sql) | **R6 / C7** — does the function return the target's datatype? | **DONE — satisfied.** [`R6_RESULTS.md`](R6_RESULTS.md) |
| [`04_r10_concurrency.sql`](04_r10_concurrency.sql) | **R10** — concurrency and volatility | **DONE — validated.** [`R10_RESULTS.md`](R10_RESULTS.md) |
| [`05_r12_per_region_sequences.sql`](05_r12_per_region_sequences.sql) | **R12/R13** — first attempt | **DEFECTIVE — superseded by 06.** R13 proven, R12 not. [`R12_RESULTS.md`](R12_RESULTS.md) |
| [`06_r12_independent_region_deployments.sql`](06_r12_independent_region_deployments.sql) | **R12** — three region schemas | **HALTED at its gate — superseded by 07.** Refuted the unqualified-sequence premise. [`R12_RESULTS_v2.md`](R12_RESULTS_v2.md) |
| [`07_r12_qualified_sequences.sql`](07_r12_qualified_sequences.sql) | **R12** — fully-qualified sequences | **DONE — R12 PROVEN.** [`R12_RESULTS_v3.md`](R12_RESULTS_v3.md) |
| [`08_r11_c3_region_growth.sql`](08_r11_c3_region_growth.sql) | **R11 + C3** | **DONE — R11 proven, C3 settled.** [`R11_C3_RESULTS.md`](R11_C3_RESULTS.md) |
| [`09_c6_legacy_key_coexistence.sql`](09_c6_legacy_key_coexistence.sql) | **C6** | **DONE — leave them; backfill is harmful.** [`C6_RESULTS.md`](C6_RESULTS.md) |
| [`10_c5_region_name_provenance.sql`](10_c5_region_name_provenance.sql) | **C5** | **DONE — informed, not decided.** [`C5_RESULTS.md`](C5_RESULTS.md) |
| [`11_c4_q1_vs_q2_placement.sql`](11_c4_q1_vs_q2_placement.sql) | **C4** | **CLOSED by Nidwika — Q2 is the right place.** [`C4_RESULTS.md`](C4_RESULTS.md) |
| [`12_q3_variable_target_datatype.sql`](12_q3_variable_target_datatype.sql) | **Q3 / R6 reopened** — target type varies and can be VARCHAR | Ready to run |

### What these four can and cannot settle

**`08` and `09` are real validations** — R11, C3 and C6 are decided by what comes back.

**`10` cannot choose C5's mechanism** — that is an IDMC decision. It tests all three candidates and,
more usefully, characterises what happens when the region name is *wrong*: a typo returns NULL
silently, and a valid name for the wrong region returns a plausible, wrong, undetectable key.

**`11` cannot settle C4** — that is a question for Nidwika. It quantifies the trade so the question
can be asked precisely.

`08` and `09` can run in any order. `10` and `11` are independent of both. None needs concurrency.

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

**Create each function while the session is in that function's own schema.** Unqualified names are
resolved against the *current* schema at **CREATE** time. Tables then bind permanently to what was
resolved; sequences do not bind and re-resolve per call. Creating a function from the wrong schema
either fails, or — if a same-named table happens to be there — binds to it silently.

**Always fully qualify a sequence inside a UDF body.** An *unqualified* sequence reference resolves in
the **caller's current schema** at run time, not the function's — proven in `06` by calling a function
from a schema with no same-named sequence and getting `invalid identifier`. A table in the same body
resolves in the function's schema, so the two are asymmetric. This contradicts the *Name resolution*
page and is worth raising with Snowflake support. Practical effect: an unqualified sequence makes key
correctness depend on session configuration.

**An assertion that cannot fail proves nothing — this has now bitten three times.** `04`'s T4.7 passed
while all regions shared one sequence; `05`'s T5.2 passed while three nominally separate sequences
moved in lockstep. Both reported `PASS` with zero duplicates, and in both cases removing the region
prefix entirely would have changed nothing. Neither script's guard caught it, because both guards
checked that the test *ran*, not that it *could have failed*. `06` adds explicit sensitivity checks
(T6.1, T6.3) and reports `VACUOUS` rather than `PASS` when the premise is not established. **Build
that check into any future test whose result is "no duplicates".**

**The three-worksheet procedure is not sufficient on its own.** The R10 run measured sessions
connecting up to **4 seconds apart** while a 20,000-row insert takes ~1.5s — so three worksheets
started by hand can run consecutively while looking parallel. Worse, `sessions_involved` still
returns 3, so that guard does **not** catch it. Any concurrency claim must come with a measured
overlap (start/end timestamps per session, intersected), or be reported as unmeasured. This applies
to `04` and `05` alike.
