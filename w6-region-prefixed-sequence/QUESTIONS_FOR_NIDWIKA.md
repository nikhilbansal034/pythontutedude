# W6 — what we need from Nidwika to close the POC

Nine Snowflake runs are complete. **Twelve of thirteen requirements are proven**, and the two
scheme-level questions (C3, C6) are settled by measurement. What remains is almost entirely
decisions that are hers or the team's, not tests.

Ordered by how much they block. **Q1–Q3 are the ones that actually gate the build.**

---

## Q1 — Was Q1 meant specifically, or was "Zone 1 → Zone 2" a paraphrase? *(C4)*

**Why we are asking.** §3 says the key should be region-qualified "while data moves from Zone 1 into
Zone 2". Both Q1 (Zone 1 → staging) and Q2 (staging → Zone 2) sit inside that journey, and **Q2 line
50 already mints the key** before anything reaches Zone 3. Measured: **both placements satisfy §3.**

**What it costs if Q1 was meant specifically**, from the run:

| | Q2 (today) | Q1 |
|---|---|---|
| Keys minted for 1,500 insertions | 1,500 | **10,000** |
| Rows carrying a key they must discard | 0 | **8,500** |
| Flag-4 retirement rows given a key they must not use | 0 | **500** |

The waste is immaterial against 10¹⁵ keys. **The real issue is the flag-4 path**: moving the mint to
Q1 means moving the SCD-2 change-flag decision out of the `MERGE` and into the staging transform.
That changes who owns the logic and where it is tested — a redesign, not a relocation.

**What we need**: *"Did you mean Q1 specifically, and if so, what does it buy that Q2 does not?"*
If it was a paraphrase, **C4 closes as already satisfied and nothing changes.**

---

## Q2 — Are R12 and R13 actually requirements? *(they are inferences, not transcript)*

**Why we are asking.** Neither appears in the transcript. We derived them from §3's traceability
argument, wrote them down so the prefix scheme could be judged, and have now **proven both**:

- **R12** — every key unique across all regions, for all time
- **R13** — the region recoverable from the key **without a join**

**Why it still matters even though they passed.** R13 is what eliminated digit concatenation as a
candidate: concatenation misdecodes 1,200 of 4,800 keys once region codes reach two digits. **If R13
is not actually required**, that argument falls away and C3 would need re-opening on R12 grounds
alone — where concatenation also fails, but less dramatically.

**What we need**: confirmation that "trace a record back by its key, without consulting another
table" is genuinely required, or a statement that a lookup is acceptable.

---

## Q3 — Which downstream systems hold `EMPLOYEE_ID`, and in what datatype?

**Why we are asking.** This sets the field width, and the width can **never be changed** once keys
are issued — changing it renumbers every key ever created.

Measured: `NUMBER(38,0)` is **never** the binding constraint. The two that bite are the 64-bit
sequence ceiling and **any downstream 64-bit consumer**:

| Width | Keys per region | A Java `long` / BIGINT consumer |
|---|---|---|
| **15 (recommended)** | 10¹⁵ | **safe** — a region-12 key is 1.3% of the ceiling |
| 18 | 10¹⁸ | **overflows** at a two-digit region code |

**What we need**: the list of systems that read `EMPLOYEE_ID` — BI tools, extracts, any Java/Python
consumer, the global consolidation layer — and the column type each uses. **If anything downstream
is 64-bit, width 15 is the answer and we pin it now.**

---

## Q4 — Where does the ETL get the region name? *(C5)*

**Why we are asking.** R8 says the region name is an input, never hard-coded. Nothing says where it
comes from, and this is an IDMC/orchestrator decision rather than a Snowflake one. All three
candidates work; the choice is about **where a mistake can be made**.

| Candidate | Keeps R2's agreed signature? | Caller can get it wrong? |
|---|---|---|
| **A.** Literal argument | **yes** | yes |
| **B.** Derived from the deployment | no | no |
| **C.** One config row per deployment | no | no |

**The part that needs her attention is not the mechanism — it is this failure mode:**

> A **valid region name for the wrong region** produces `2000000000000007` — a structurally perfect
> key that passes every uniqueness and decode test in the entire pack, and is wrong. Nothing detects
> it. The traceability goal that motivated this whole change is defeated precisely where it would
> matter.

A typo is benign by comparison: it returns `NULL`, which a `NOT NULL` column turns into a failed
load.

**What we need**: (a) which mechanism, and (b) agreement to adopt two controls regardless —
**`NOT NULL` on the key column**, and a **per-deployment guard** rejecting a region this deployment
may not issue. Both are free and they compose. B and C change R2's agreed signature from
`f(region_name, sequence_name)` to `f(sequence_name)`, which is why they need her agreement rather
than ours.

---

## Q5 — Confirm the three scheme decisions we are treating as settled

These were decided by measurement, not preference. Flagging them for ratification rather than debate.

| Decision | Basis |
|---|---|
| **Fixed-width offset, width 15** *(C3)* | Concatenation produced **198 duplicate primary keys** at twelve regions and **999 collisions** with legacy keys. Offset: zero in both |
| **Leave legacy keys alone — do not backfill** *(C6)* | Coexistence clean (11,000/11,000/0). Backfill produced **3,000 duplicates**, colliding with keys *already issued* |
| **Region code 0 must never be allocated** | Legacy keys decode to region 0. That is what makes them self-identifying rather than silently misattributed |

---

## Q6 — Who owns onboarding a new table? *(a consequence of R2)*

Adding a **region** is a data change — proven, zero lines of code. Adding a **table** is not: the
function names every sequence literally, so a new table edits the `CASE`.

That is still one place rather than per-ETL, which is what §1 asked for. But someone owns it.

**What we need**: agreement on whether the function's `CASE` arms are **generated from the registry**
at deploy time (our recommendation — these queries are already generated) or hand-maintained.

---

## Q7 — Should the release check become a standing gate?

One query catches the two silent-corruption modes we found:

```sql
SELECT FUNCTION_NAME, VOLATILITY, IS_MEMOIZABLE
FROM INFORMATION_SCHEMA.FUNCTIONS
WHERE FUNCTION_NAME = '<the key function>';
-- must be VOLATILE and IS_MEMOIZABLE = NO
```

**Both columns matter**: a memoizable function reports `VOLATILITY = 'VOLATILE'`, so checking
volatility alone passes it. Pairs with the R11 check (`CREATED = LAST_ALTERED` proves the function
was not quietly edited).

**What we need**: a yes/no on adding these to the deployment pipeline.

---

## One thing to raise with Snowflake, not with Nidwika

Snowflake's *Name resolution* page states: "All unqualified objects in a view or UDF definition will
be resolved in the view's or UDF's schema only." **Sequences do not comply** — proven by calling a
function from a schema with no same-named sequence and getting `invalid identifier`, while the
function's own schema had one.

Either the documentation or the behaviour is wrong. We have designed around it (fully qualify), so
nothing is blocked — but knowing which it is tells us whether to keep defending against it.
