# R2 — RESULT: **SATISFIED**, by the branch selector only

**Run**: 2026-11-03 21:02 UTC, `LM_POC_DB.POC_SCHEMA`, Snowflake 10.39.101, role `POC_ROLE`.
**Evidence**: `../R2_02_r2_sequence_name_binding_20261103-210217.json` — 20 statements, verbatim.
**Script**: `02_r2_sequence_name_binding.sql`.

| Test | Checked | Result | Verdict |
|---|---|---|---|
| T2.1a | Fully-qualified name in the body | 5 / 5 distinct | **PASS** |
| T2.1b | Unqualified name in the body | 5 / 5 distinct | **PASS** |
| T2.2a | Registry lookup via `IDENTIFIER()` | refused at CREATE | **FAILED AS EXPECTED** |
| T2.2b | `IDENTIFIER()` on the parameter | refused at CREATE | **FAILED AS EXPECTED** |
| T2.3a | Branch selector, one name per statement | EMPLOYEE 201–205, JOB 1005–1009 | **PASS** |
| T2.3b | Branch selector, name varying **per row** | 5 / 5 / 5 | **PASS** |
| T2.4 | Do untaken `CASE` arms consume values? | **yes** — see below | RECORDED |

**R2 is closed.** The signature `f(region_name, sequence_name)` works, but only in the branch-selector
shape where every sequence is named literally.

## The registry idea is refused by the parser, not at run time

Both T2.2 variants failed at **CREATE**, not on first call:

```
Compilation of SQL UDF failed: SQL compilation error:
syntax error line 2 at position 15 unexpected 'seq_name'.
```

T2.2b takes the registry table out of the picture entirely and still fails, which isolates the cause:
**the parameter is the blocker, so no amount of table indirection can help.** Useful in one respect —
the failure is loud and immediate. Nobody can ship this by accident.

## Build-standard decision: use the **unqualified** name

Both forms work (T2.1a and T2.1b), so the choice is made on R8, not on capability. An unqualified
reference resolves "in the schema containing the function", so identical function text deployed to
dev, SIT and prod binds its own objects. A fully-qualified body hard-codes database and schema and
is not portable.

## T2.4 — untaken arms DO consume, but the cost is bounded

Reset both sequences, then drew **20 rows all requesting `EMPLOYEE_SEQ`**. `JOB_SEQ` was never selected:

| | before | after | rows issued |
|---|---|---|---|
| `W6_EMPLOYEE_SEQ` | 1 | **101** | 20 |
| `W6_JOB_SEQ` | 1000 | **1100** | **0** |

`JOB_SEQ` advanced 100 without issuing a single key.

**The shape of the cost matters, and it is better than "every arm, every row".** Both sequences moved
by *exactly* 100 for a 20-row draw. That is **block reservation of 100 values per referenced sequence
per statement**, not a per-row charge. A function with N arms costs at most ~100 × N values per
statement regardless of row count — trivial against a 10^15 field, but it does mean:

- the untaken sequences develop gaps that correlate with nothing
- **prefer one function per sequence as the arm list grows** — not because the waste matters
  numerically, but because a reader of `JOB_SEQ`'s gaps has no way to know an unrelated load caused them

This also explains R3's T1.3/T1.4 values (101–110, then 201–300): each statement took a fresh
100-block.

## ORDERED = NO on both sequences

T2.4a returned `ORDERED = NO`, independently confirming the NOORDER property that explained R3's
apparently non-monotonic T1.5. This is the documented default and is the property this design wants.

## Caveat on the evidence

**Teardown was not run** — the objects remain in `LM_POC_DB.POC_SCHEMA`, and the R6 and R10 runs
inherited that state. Harmless here (every script uses `CREATE OR REPLACE`), but it is why sequence
values in later runs do not start where a clean run would put them.
