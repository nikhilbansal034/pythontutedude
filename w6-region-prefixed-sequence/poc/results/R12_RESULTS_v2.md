# R12 v2 — **still NOT PROVEN**, and the reason refutes a documented Snowflake behaviour

**Run**: 2026-11-03 22:09 UTC. **Evidence**:
`../R12v2_06_r12_independent_region_deployments_20261103-220901.json` — 29 statements, five added as
diagnostics. **Script**: `06_r12_independent_region_deployments.sql`.

**Halted at the T6.1 sensitivity gate.** T6.2 onward were correctly not run.

## The gate worked — that is the one unambiguous success

| Run | Premise | Caught? |
|---|---|---|
| `04` T4.7 | one shared sequence | **No** — reported PASS |
| `05` T5.2 | three sequences in lockstep | **No** — reported PASS |
| `06` T6.1 | deployments not independent | **Yes — halted before any claim** |

Three runs, three broken premises, and only the third caught itself. The difference is that `06`
asserts a **precondition**, not only a postcondition. Keep this pattern.

## F19 — sequence and table references resolve by *different* rules, and the docs say they shouldn't

Five observations, ending in a prediction test:

| Seq | Observation |
|---|---|
| 30 | After 1500 rows through the three regional functions, **all three regional sequences still at `NEXT_VALUE = 1`**, while `POC_SCHEMA`'s sequence reached `1901` |
| 31 | NA's function called from EU's schema → key decoded to region **1** (NA's *table*), raw values from **EU's** sequence |
| 32 | NA's function asked for `'APAC'` returned **NULL**, though APAC's own map contains APAC → the table read was **NA's**, not the caller's |
| 33 | After calls from EU and APAC: their sequences at `101`; **NA's own sequence still at `1`** |
| 34 | Called from `GOLD_POC` (no such sequence): `invalid identifier 'W6_EMPLOYEE_SEQ.NEXTVAL'` — **even though `W6_RGN_NA.W6_EMPLOYEE_SEQ` exists beside the function** |

So in one function body:

- **unqualified TABLE** → resolved in the **function's** schema
- **unqualified SEQUENCE** → resolved in the **caller's current schema**, at run time, and errors if absent there

### This is stronger than the run log states — it contradicts the documentation

I had cited *Introduction to SQL UDFs*: "If a function definition refers to an unqualified **table**,
then that table is resolved in the schema containing the function" — and generalised it to sequences,
which that sentence does not cover.

But the **Name resolution** page does generalise it, verbatim:

> The SEARCH_PATH is not used inside views or UDFs.
> **All unqualified objects in a view or UDF definition will be resolved in the view's or UDF's
> schema only.**

Observed sequence behaviour **does not comply with that sentence**. So this is not simply my
over-reading: Snowflake documents the general rule and sequences are an undocumented exception to it.

A plausible mechanism — not confirmed — is that SQL UDF bodies are inlined into the calling query
plan and the sequence identifier is bound during that inlining, using the caller's context, whereas
the table reference is bound at definition scope. **Worth raising with Snowflake support**, since
either the docs or the behaviour is wrong.

## What this does to R8 — and the correction to R2's T2.1b

**R2's T2.1b did not establish what I took it to establish.** In that test the function, the sequence
and the caller were *all* in `POC_SCHEMA`, so caller-schema and function-schema resolution coincided
and the test could not distinguish them. **That is the third insensitive test in this pack.**

My build-standard line — "use the unqualified sequence name inside the function body, for R8
portability" — is **wrong, and should be reversed**:

> **The sequence reference inside the function body must be FULLY QUALIFIED.**

An unqualified one does not travel with the function. It binds to whatever the caller's session is
pointing at, which means the same function invoked from two differently-configured sessions silently
draws from **two different sequences**, or fails outright. For a surrogate key that is a correctness
hazard, not an inconvenience.

**R8's intent survives**, but as *one template*, not one literal unchanged text — which is exactly
how Q2 already works: `$$inout_param_hr_database_name.$$inout_param_hr_main_schema_name.EMPLOYEE_SEQ`
is substituted by the orchestrator before Snowflake sees it. The function DDL needs the same
treatment.

## Why I am not taking F21's route

F21 proposes each session run `USE SCHEMA` for its own region, so caller-schema resolution lands on
the right sequence. That **would** open the gate — and the run is right that it mirrors how a regional
ETL would connect.

But it makes key correctness depend on session configuration. A job that connects with the wrong
default schema would quietly draw from another region's sequence, and nothing in the key would show
it. **Qualifying the reference removes the dependency instead of managing it**, so `07` does that and
additionally asserts caller-schema *independence* as a test in its own right.

## F20 — the skipped teardown nearly converted a loud failure into a quiet wrong answer

T6.1 produced 1500 clean rows and a confident verdict **only because R2's leftover
`POC_SCHEMA.W6_EMPLOYEE_SEQ` happened to exist at `NEXT_VALUE = 101`** — which is exactly where NA's
probe started. Without it, seq 34's `invalid identifier` would have fired immediately and been
investigated at once.

That is a direct cost of the standing decision to skip teardown. `07` uses **run-scoped object names**
so a cross-pack name collision cannot happen again.

## Housekeeping

This run created objects **outside** the usual scratch area — three new schemas in `LM_POC_DB`:
`W6_RGN_NA`, `W6_RGN_EU`, `W6_RGN_APAC`, plus `W6_GLOBAL_KEYS` (empty) and `W6_RAW_PROBE` in
`POC_SCHEMA`. `07`'s teardown removes them all.

## Unchanged by this run

**R13** proven (`05` T5.3, `04` T4.7b). **C3** width evidence holds (`05` T5.4: 2–5 digits vs the
offset scheme's uniform 16). **R12** remains the one open requirement.
