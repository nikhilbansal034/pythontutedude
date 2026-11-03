# W6 — Region-prefixed sequence generation

Replace the direct `<TABLE>_SEQ.NEXTVAL` call in the Zone 1 → Zone 2 ETL with a **reusable
function** that takes a region name and a sequence name, looks the region code up from a
configuration table, prefixes it to the sequence's next value, and returns the value already cast
to the surrogate key's datatype.

**Status** — requirement captured from the *[Internal] TD MOD — US/USI Daily Connect* transcript.
Nothing investigated, built or tested yet. Two action items are assigned to Nikhil Bansal.

---

## Layout

| Path | What it is |
|------|-----------|
| `sources/requirement_region_prefixed_sequence.txt` | The transcript-derived requirement. **The baseline** — if anything here disagrees with it, it wins |
| `sources/employee_q1_zone1_to_staging.txt` | EMPLOYEE Q1 of 2 — historical/catch-up load, Zone 1 source → transformations → `STG_EMPLOYEE` |
| `sources/employee_q2_staging_to_zone2_target.txt` | EMPLOYEE Q2 of 2 — `STG_EMPLOYEE` → Zone 2 target, single SK-keyed `MERGE`. **Holds the line that changes** |

The two queries are the W3-shaped two-query historical load pattern for `EMPLOYEE` (SCD Type 2,
38 target columns, business key `EMPLOYEE_PIN + ROW_EFFECTIVE_DATETIME`). They are the concrete
example the POC has to work against, not themselves the deliverable.

---

## What the requirement asks for

| # | Requirement | Source |
|---|---|---|
| R1 | The ETL stops calling `<seq>.NEXTVAL` directly and calls `function(region_name, sequence_name)` instead | §1 |
| R2 | The function gets the next value from the named sequence | §1 |
| R3 | The function resolves the region **code** from the region **name** it was passed | §1, §2 |
| R4 | The function prefixes the region code to the sequence value | §1 |
| R5 | The function returns the value in the datatype the target column expects — the cast happens inside the function, not in each ETL | §1, §4 |
| R6 | Region name → region code lives in a **mapping table**, not in the function body and not in the ETL. Known mappings: North America → 1, EU → 2, APAC → 3 | §2 |
| R7 | One code base, unchanged across environments; the region name is an input | §2 |
| R8 | The region prefix is applied while moving **Zone 1 → Zone 2**, not later at Zone 2 → Zone 3 global consolidation | §3 |
| R9 | The function must be safe when **called in parallel by multiple tables** | §5 |

**Why R8 matters** (§3): if Zone 2 stores plain `1, 2, 3` and the region is only prefixed when
regions are merged into the global database, the global identifier no longer matches what Zone 2
stored. Tracing a bad record back would then need the UUID, or logic to strip the prefix before
comparing. Attributed to Cindy MacFarlane's preference: treat the region on the left-hand side so
the identifier never has to change downstream.

**Why a function and not inline SQL** (§4): Nidwika Vedanaparthi found that prefixing the region
code to a sequence value in Snowflake **changed the datatype** and needed an explicit cast back.
Centralising `nextval → prefix → cast` avoids repeating that in every DTTL/ETL.

### Explicitly out of scope

Whether the physical target table also needs a separate region-code **column** is a *separate*
design question (§6), parked with Abhi and team. It must not block the function investigation.

---

## Where the change actually lands in the two queries

`sources/employee_q2_staging_to_zone2_target.txt` line 50 — inside the `MERGE … USING` projection:

```sql
CAST(CASE WHEN stg.CHANGE_FLAG = '0'
          THEN $$inout_param_hr_database_name.$$inout_param_hr_main_schema_name.EMPLOYEE_SEQ.NEXTVAL
          ELSE stg.EMPLOYEE_ID END AS NUMBER(38,0)) AS EMPLOYEE_ID,
```

This is the **only** place a surrogate key is minted. Q1 deliberately leaves it unresolved:

- new rows (`CHANGE_FLAG = '0'`) carry `EMPLOYEE_ID = NULL` into `STG_EMPLOYEE`
- existing rows (`'1'`, `'3'`, `'4'`) carry the incumbent `CATCHUP_OLD_EMPLOYEE_ID` forward
- a flag-`4` correction emits **two** staged rows: the retirement keeps the old SK, the replacement
  comes through as a fresh flag-`0` row and so gets a brand-new SK

So the shape of the change is a like-for-like swap of the `THEN` branch — the `CASE`, the
flag gating and the `ELSE` passthrough all stay as they are.

**Open point against R8:** both queries already sit inside the Zone 1 → Zone 2 journey (Q1 is
Zone 1 → staging, Q2 is staging → Zone 2 target). The key is already minted before anything
reaches Zone 3. Read literally, R8 looks **already satisfied** by the current placement, which
would mean the real work is R1–R7 and R9 only, with no relocation of the `NEXTVAL` call. Worth
confirming whether the intent was instead to mint the key earlier still, in Q1.

---

## The risks this POC exists to settle

1. **Can a Snowflake function reference a sequence at all?** The whole design rests on
   `nextval` living *inside* a callable function. This is unverified — it was not possible to
   confirm from Snowflake documentation, and it is a hard failure for the design if unsupported.
   **Test this first**; everything else is wasted effort until it is settled. If it is not
   supported, the fallbacks to evaluate are minting the raw value in the calling query and passing
   it to a pure formatting function, `GETNEXTVAL`, or a column `DEFAULT`.
2. **Return datatype and prefix scheme.** On `NUMBER(38,0)` a prefix is arithmetic, not
   decoration: region `1` over sequence value `1` is `11`, and over `11` is `111`, so key
   magnitude grows with the sequence. Digit concatenation is *decodable* while every region code
   is a single digit — the first digit is the region, the rest is the sequence value — but it
   stops being decodable the moment a region code reaches two digits, because `concat(1, 23)` and
   `concat(12, 3)` are both `123`. Three codes are allocated today (1, 2, 3) and the mapping table
   is designed to grow, so the scheme needs to survive a fourth-to-tenth region. A fixed-width
   scheme such as `region_code * 10^18 + nextval` has no such cliff, stays decodable by division,
   and keeps keys monotonic within a region. Decide this alongside whether the target column stays
   `NUMBER(38,0)` or becomes `VARCHAR` — R5 depends on it.
3. **Parallel safety (R9).** Snowflake sequence values are unique but not gap-free, and ordering is
   not guaranteed across concurrent statements. The test has to cover several tables calling the
   same function concurrently and check for duplicates, not just that it returns.
   A sharper concern sits underneath R9: Snowflake does not guarantee **how many times** a UDF is
   invoked per row — the optimiser may evaluate a scalar expression more or fewer times than there
   are rows. That is harmless for a pure function and a correctness bug for one that consumes a
   sequence. Verify invocation count, not just uniqueness.
4. **One call per row.** W3 already recorded the trap of calling `NEXTVAL` twice on one row and
   assuming the same value — see `w3-scd-effective-date-split/poc_v2/scenarios/S14.sql`. The
   same caution applies to a function wrapping it.
5. **`NEXTVAL` inside `MERGE … WHEN NOT MATCHED`.** Flagged in W3's context pack as expected to
   work but never confirmed. A function call in that position inherits the same uncertainty.

## A narrower shape worth weighing first

*Proposed here, not agreed in the meeting, and not yet tested.*

The stated motivation in §1 and §4 is **not** "the function must own the sequence" — it is "do not
reimplement the prefix/casting logic in every DTTL/ETL". That goal is met without ever putting
`nextval` inside a function:

```sql
-- the ETL keeps the sequence call it already has, and wraps only the part worth centralising
CAST(CASE WHEN stg.CHANGE_FLAG = '0'
          THEN GET_REGIONAL_KEY('North America', EMPLOYEE_SEQ.NEXTVAL)
          ELSE stg.EMPLOYEE_ID END AS NUMBER(38,0)) AS EMPLOYEE_ID,
```

`GET_REGIONAL_KEY(region_name, seq_value)` looks the region code up from the mapping table,
applies the prefix and returns the target datatype. It is **pure and deterministic**, so:

- R3–R7 are all still satisfied, and the prefix/cast logic still lives in exactly one place
- risk 1 disappears — the function never touches a sequence, so whether a Snowflake function *may*
  reference one stops being load-bearing
- R9 becomes trivial rather than something to prove: a deterministic function has no shared state
  to contend over, and repeated invocation is harmless
- the one-call-per-row discipline stays visible in the query, where W3's S14 already handles it

The cost is that each ETL still names its own sequence inline — which it does today anyway, so
nothing regresses. The trade to put to Nidwika Vedanaparthi is whether R1's literal
`function(region_name, sequence_name)` signature is the requirement, or whether it was shorthand
for "centralise the prefix and the cast". If the signature is genuinely required, risk 1 has to be
settled first and this folder's test order stands as written.

---

## Not W3, not W4

W3 is the multi-source SCD-2 effective-date split that produces these two queries. W4 is the
generic config-driven ETL framework. W6 changes **one expression** inside the generated Q2 — how
the surrogate key is minted — and the mapping table and function that back it.
