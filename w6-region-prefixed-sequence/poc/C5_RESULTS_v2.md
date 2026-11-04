# C5 v2 — two live deployments, side by side

**Evidence:** `C5v2_12_c5_multi_deployment_guard_20261104-025918.json`
**Script:** `SQL/12_c5_multi_deployment_guard.sql` (authored outside this repo, run 2026-11-04 02:59 UTC)
**Shape:** 34 statements, 33 executed, 32 succeeded, 1 deliberate error, teardown skipped.

Script 10 tested C5 on one deployment. This run stands two up — `W6V12_NA` (region 1, "North
America") and `W6V12_EU` (region 2, "EU") — plus a third neutral schema `W6V12_RPT` to call from.

---

## 1. What the run establishes

| Test | Claim | Verified against the rows? |
|---|---|---|
| T12.2 | Each guarded function mints only its own region's keys | **Yes.** NA returned `1000000000000001` for "North America" and `NULL` for both `'EU'` and the typo `'Noth America'`. EU the mirror image. |
| T12.3 | NA and EU key spaces are disjoint | **Yes, by construction.** NA ceiling `1,999,999,999,999,999`, EU floor `2,000,000,000,000,001`. Holds as long as no sequence passes 10¹⁵. |
| T12.4 | Zero cross-region collisions | **Yes, and the test could have failed** — see §2. 1000 rows, 1000 distinct, 0 duplicates. |
| T12.5 | Every key decodes to the region that issued it | **Yes.** 500/500 NA decode to 1, 500/500 EU decode to 2, 0 wrong. |
| T12.6 | F35 (valid-but-wrong region name) is closed | **Yes, in two parts.** The guard turned `key_na_v12('EU')` into `NULL`; the `NOT NULL` column then refused the load outright: *"NULL result in a non-nullable column"*. Follow-up count of `REGION = 'EU'` rows in the NA table: **0**. |
| T12.7 | F36 (case sensitivity) is addressed | **Yes.** Unmodified guard: `'NORTH AMERICA'` and `'north america'` both `NULL`. With `UPPER()` on both sides: 709, 710, 711 — three distinct keys — while `'EU'` still returns `NULL`. |
| T12.8 | R8 portability survives the F23 fix | **Yes.** From `W6V12_RPT`, where neither function lives, both resolved by FQN and decoded correctly (1 and 2). Wrong-region calls by FQN still returned `NULL` — the FQN route is not a bypass. |

## 2. The sensitivity question, which this run passes

Three earlier runs produced assertions that passed while being incapable of failing. This one is not
one of them, and the proof is in T12.4's gate rather than its assertion.

The gate (seq 21) recorded NA keys spanning `…000101`–`…000600` and EU keys `…000101`–`…000600`.
**The two regions drew the same 500 raw sequence values.** Strip the prefix and 500 of the 1000 keys
are duplicates. The prefix is the only thing producing the 0.

That is the shape every uniqueness test in this pack should have, and it is worth saying plainly:
the assertion is meaningful *because* the raw values overlapped, not because the count came back 0.

## 3. What the guard actually buys, and what it costs

The F35 fix is two controls, and it only works as a pair:

1. **The guard** — the UDF's `WHERE` clause requires the caller's region name to match the row in
   this deployment's own `deployment_config` table. A wrong region yields no row, so the scalar
   subquery yields `NULL`, so the whole expression is `NULL`.
2. **`NOT NULL` on the target key column** — converts that `NULL` into a rejected load.

Drop either one and F35 reopens. Without the guard, script 10 showed this exact call returning
`2000000000000007`: a perfectly well-formed EU key sitting in the NA deployment. Without `NOT NULL`,
the guard's `NULL` lands as a row with no key.

**The cost, stated honestly:** a wrong-region call now aborts the whole DML statement, not just the
row. For a nightly SCD2 catch-up load that is the right trade — a failed batch you investigate beats
a silently mis-attributed key — but it is a behaviour change someone should sign off on, not a
free win.

**The constraint it imposes:** one deployment can mint for exactly one region. That is a design
decision (it matches D4's one-sequence-per-table-per-region shape), but it means a single IDMC
deployment serving two regions is no longer possible without relaxing the guard. Worth confirming
that is the intended topology.

## 4. Smaller observations

- **`UPPER()` is the right normalisation and not quite complete.** It fixes case. It does not fix
  leading/trailing whitespace or accents/diacritics. `UPPER(TRIM(…))` costs nothing more and closes
  whitespace too — recommend that form rather than bare `UPPER()`.
- **Rejected calls appear to consume sequence values.** Between seq 28 (`…000704`) and seq 30
  (`…000709`) four values went missing, and block reservation makes the exact attribution
  unreadable. Functionally harmless — gaps are already permitted — but it means a guard rejection
  is not free of side effects.
- **`CHECK` constraints will not help.** Snowflake accepts but does not enforce them, so "region
  code must be 1–9" (see the Scheme A note) cannot be enforced declaratively on `region_map`. It has
  to live in the UDF or in the map's load process.

## 5. Status after this run

**C5 is closed on the Snowflake side.** The build standard, as proven:

- Candidate A signature — `f(region_name VARCHAR)`
- Deployment guard against a local `deployment_config` row, with `UPPER(TRIM(…))` on both sides
- Sequence referenced by **full** FQN inside the body (F19/F23)
- Function **created while the session is in its home schema**, so unqualified table references bind
  locally (F23)
- Target key column declared `NOT NULL`, without exception (F37)
- Called from the ETL by FQN

**Still open, and not a Snowflake question:** where `region_name` originates in the IDMC job.
Nidwika's Q4 answer says IDMC supplies it against a mapping table, which settles the *source*; what
remains is the mechanism — job parameter, connection attribute, or lookup — and that is her call.
