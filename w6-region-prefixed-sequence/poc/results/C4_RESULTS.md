# C4 — **QUANTIFIED, NOT DECIDED.** §3 is satisfied either way.

**Run**: 2026-11-04 02:11 UTC. **Evidence**:
`../C4_11_c4_q1_vs_q2_placement_20261104-021146.json` — 23 statements.

## The key result: both placements satisfy §3

| Placement | Rows reaching the target | Region-qualified before Zone 3 |
|---|---|---|
| **Q2 (today)** | 1,500 | **1,500 — PASS** |
| **Q1** | 1,500 | **1,500 — PASS** |

Both Q1 and Q2 sit inside the Zone 1 → Zone 2 journey, so the identifier is region-qualified before
consolidation either way. **C4 is not a correctness question** — it is cost and complexity.

## What Q1 would cost

On a representative catch-up profile (1,000 new, 2,000 updates, 6,000 no-ops, 500 correction pairs):

| | Q2 (today) | Q1 |
|---|---|---|
| Keys minted | 1,500 | **10,000** |
| Rows carrying a key they must discard | 0 | **8,500 (85%)** |
| Flag-4 rows given a key they must not use | 0 | **500** |

**The waste is not the objection** — 8,500 keys against 10¹⁵ is immaterial.

**The objection is the flag-4 path.** Every correction pair emits a retirement row (which must keep
its incumbent key) and a replacement row (which needs a new one). Under Q1 the retirement row
receives *both* — an `EXISTING_ID` it must keep and a freshly minted key it must ignore. Q1 would
have to mint **conditionally**, which means **Q1 needs the SCD-2 change-flag logic that currently
lives in Q2**.

That is a redesign of where the SCD-2 decision is made, not a relocation of one call.

## An incidental finding that matters for both (F39)

**A `VOLATILE` UDF inside a `CASE` consumes a sequence value even when its branch is not taken.**

Q2 minted 1,500 keys but consumed **13,364** sequence values. Uniqueness is unaffected (1,500 /
1,500 / 0 duplicates), and 13,364 against 10¹⁵ is nothing — but two consequences are worth carrying:

1. **Anyone equating sequence consumption with keys issued will see ~9× inflation under Q2** and
   ~21× under Q1. Reconciliation must not be built on that equivalence.
2. **This is a change introduced by W6 itself.** Today's raw `SEQ.NEXTVAL` in a `CASE` consumes at
   *block* level; replacing it with a UDF call moves consumption to *per row*. Still immaterial, but
   it should be stated rather than discovered later.

## Recommendation to put to Nidwika

Close C4 as **"already satisfied"** unless Q1 was meant specifically. The question is narrow:
*"Did you mean Q1 specifically, and if so, what does it buy that Q2 does not?"*

## Script defect

T11.1's summary query used `rows` as a column alias — a reserved word in Snowflake. Corrected
mid-run; no effect on any result.
