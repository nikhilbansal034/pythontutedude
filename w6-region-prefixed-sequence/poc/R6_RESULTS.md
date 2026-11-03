# R6 — RESULT: **SATISFIED**, and the failure mode is louder than predicted

**Run**: 2026-11-03 21:07 UTC, `LM_POC_DB.POC_SCHEMA`.
**Evidence**: `../R6_03_r6_return_datatype_20261103-210716.json` — 20 statements, verbatim.
**Script**: `03_r6_return_datatype.sql`.

| Test | Checked | Result | Verdict |
|---|---|---|---|
| T3.1 | Is declared `NUMBER` precision/scale ignored? | `RETURNS NUMBER(3,0)` returned 123456789012345 | **IGNORED — as documented** |
| T3.2 | Is declared `VARCHAR` length ignored? | `RETURNS VARCHAR(1)` returned 10 chars | **IGNORED — as documented** |
| T3.3 | Does a body-level `CAST` deliver the type? | `NUMBER(38,0)` | **PASS** |
| T3.4 | Fixed-width offset, end to end | NA `1000000000000001`–`…005`, EU `…006`–`…010` | **PASS** |
| T3.5a | Concatenation **without** a body cast | **CREATE REFUSED** | **UNANTICIPATED — see below** |
| T3.5b | Concatenation **with** a body cast | `1101`, `NUMBER(38,0)` | **PASS** |
| T3.6 | Key lands in a real `NUMBER(38,0)` column | 20 / 20 / 20 decode correctly | **PASS** |

**R6 is closed** — but only because the cast is in the **body**. The `RETURNS` clause does not deliver
the datatype.

## The correction: the *base type* IS enforced, even though the modifiers are not

My script predicted T3.5a would return `VARCHAR` despite `RETURNS NUMBER(38,0)`, proving the
declaration inert. Snowflake did something different and better:

```
Declared return type 'NUMBER(38,0)' is incompatible with
actual return type 'VARCHAR(134217728)'
```

**The CREATE was refused.** So the documented sentence — "argument and return type constraints are
sometimes ignored" — is precise in a way I read too broadly. There are two layers:

| Layer | Enforced? |
|---|---|
| Base type (`NUMBER` vs `VARCHAR`) | **Yes, at CREATE** |
| Precision, scale, length *within* that type | **No, not at all** |

**This is better news than the requirement assumed.** A UDF that concatenates without casting cannot
be shipped silently — it will not create. The datatype problem from transcript §4 therefore cannot
reach a target as a wrong value; it surfaces as a refused deployment.

The body cast is still **mandatory**, but for correctness of *magnitude*, not to avoid a silent type
mismatch. C7 remains live: precision and scale really are ignored, so `RETURNS NUMBER(38,0)` is
documentation and the body must do the work.

## Evidence for C3: concatenation produces variable-width keys

Same scheme, same run, side by side:

| Scheme | Key produced | Width |
|---|---|---|
| Fixed-width offset (T3.4) | `1000000000000001` | always 16 digits, region in a fixed position |
| Digit concatenation (T3.5b) | `1101` | 4 digits, and grows with the sequence value |

**A correction to the run log's finding F8.** It illustrates the collision as "region 11 with sequence
01 would also give 1101". That particular example is not achievable — a sequence yields `1`, never
`01`. The conclusion is right but the demonstration should be:

```
concat(1, 11)  = 111
concat(11, 1)  = 111     <- same key, two different regions
```

Across 12 regions × 400 sequence values there are **198 colliding key strings**. Worth fixing the
example, because anyone who checks the stated one will find it does not reproduce and may dismiss a
finding that is actually sound.

## A caveat that limits what T3.4 proved

`w6_key_offset` reads **one shared sequence** for all regions, so EU continued at 6–10 rather than
restarting at 1. That is **not the production topology**: per decision D4, each table has its own
sequence *per region*, every one starting at 1.

Consequence: in this test, cross-region uniqueness came from the sequence, and the prefix only
carried traceability. In production the prefix is the **only** separator. T3.4 validates the
arithmetic and the datatype handling; it does not exercise the case where the prefix is load-bearing.
See `R10_RESULTS.md` for the same gap at T4.7, and the follow-up it calls for.
