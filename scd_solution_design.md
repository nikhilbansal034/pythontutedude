# W3 solution design — multi-source SCD2 effective-date split

Status: **draft.** The problem catalogue is in `scd_scenario_matrix.md`; this file covers how it gets solved
and the POC that proves it. Vocabulary is in `scd_glossary.md`.

The runnable POC is `scd_poc_snowflake.sql`.

---

## 1. Scope and constraints

| | |
|---|---|
| **Hop** | Zone1 → Zone2 — **working assumption, not confirmed** |
| **Source** | Zone1 tables, both SCD2, read from the history bucket |
| **Target** | Zone2 Snowflake table, SCD2, soft-delete via `is_del` |
| **Orchestration** | IDMC (Informatica Intelligent Data Management Cloud) |
| **Execution** | Full push-down / SQL ELT optimization — the work runs inside Snowflake |
| **Hard constraint** | No stored procedures. SQL is embedded in the IDMC pipeline |

ABC framework integration is deliberately out of scope here.

---

## 2. The reframe that makes it set-based

The instinct is to walk each changed row, find the target rows it affects, and patch them. That is
inherently row-by-row and led the original discussion toward cursors.

The alternative:

> **For any business_key touched this run, throw its timeline away and rebuild it from scratch from both
> sources, then diff the rebuilt timeline against what the target holds.**

Same output, fully set-based, and idempotent for free — re-running with no new data produces no changes,
which the POC asserts as T11.

---

## 3. Three steps

```
   Zone1 Table 1              Zone1 Table 2
         └────────────┬─────────────┘
                      ▼
        STEP 1 — one mapping, SQL override in the Source transformation
        rebuild the timeline for every changed key, diff against the target
                      ▼
              STAGE table (truncate + reload)
              every row carries action_flag 'I' or 'D'
              ┌───────┴────────┐
              ▼                ▼
        STEP 2 — 'D'      STEP 3 — 'I'
        Update            Insert
        is_del = 'Y'      new versions
              └────────┬───────┘
                       ▼
                 Zone2 target
```

**Step 1 does all the thinking.** When it finishes there are no decisions left — the stage is a complete
instruction list. **Step 1 writes nothing to the target**, so Steps 2 and 3 are needed to apply it. They
contain no logic; they read a flag and act.

**Step 2 must run before Step 3.**

---

## 4. Step 1 — the eight stages

| | Stage | What it does |
|---|---|---|
| 1 | **Impacted keys** | `business_key` values whose audit timestamp moved in *either* source since the last run |
| 2 | **Full history** | *All* versions of those keys from *both* sources — not just the delta rows |
| 3 | **Clean each source** | Latest row per (key, eff date); project to target-relevant columns; collapse consecutive identical versions |
| 4 | **Collect boundaries** | Every `row_eff_dte` **and** `row_exp_dte` from both cleaned sources |
| 5 | **Build intervals** | `row_exp_dte = LEAD(boundary)`; the final boundary closes the last interval |
| 6 | **Fill intervals** | LEFT JOIN each source on containment |
| 7 | **Read the target** | Current rows for those keys where `is_del = 'N'` |
| 8 | **Diff** | New not in current → `'I'`. Current not in new → `'D'`. Identical → left alone |

### Four things that are easy to get wrong

**Stage 2 is the one people miss.** On Day 2 Table 1 does not change at all, but its full history still has
to be read — otherwise the rebuilt timeline has no Table 1 values and the target is destroyed. From the
2026-09-18 call:

> *"even though there is no change in table one data, still we need to account for all the records related
> to that key where we received a change in Table 2, and vice versa"*

**Stage 4 must include expiry dates, not just effective dates.** If a source covers 10-Sep to 15-Sep and its
next version starts 20-Sep, using only effective dates gives boundaries {10, 20} and the value would be
wrongly carried across the 15–20 gap. Including expiry dates cuts the interval correctly and leaves the gap
blank. The worked example has no mid-timeline gap, so it does not exercise this — the POC's collapse logic
guards it explicitly.

**Stage 3's collapse has two traps.** Only *consecutive* versions merge, so `p → q → p` must not collapse
into one. And a gap in cover is not a merge: if a source has no value for a period, the periods either side
stay separate even when the value is identical. The POC implements both as an explicit "new run starts
here" flag rather than relying on value comparison alone.

**Stage 6 cannot fan out, and this is structural.** Because intervals are cut at *every* boundary from both
sources, each interval falls entirely inside at most one version per source. Each join matches 0 or 1 rows.
No aggregation or de-duplication is needed after the join.

**Stage 8 compares dates *and* values.** A source correcting a value without moving its dates still produces
a `D` + `I` pair. Comparing dates alone would silently keep the stale value.

---

## 5. Why not a single MERGE

The natural instinct is one `MERGE` from stage into target. **It fails at runtime.**

On Day 2, the stage holds these rows for K1:

```
D  (K1, 10-Sep, 21-Sep)        I  (K1, 10-Sep, 15-Sep)
D  (K1, 21-Sep, high end)      I  (K1, 15-Sep, 21-Sep)
                               I  (K1, 21-Sep, 22-Sep)
                               I  (K1, 22-Sep, high end)
```

The live target row `(K1, 10-Sep, 21-Sep)` matches **both** the `D` row and an `I` row on
`(business_key, row_eff_dte)`. Snowflake's `ERROR_ON_NONDETERMINISTIC_MERGE` is `TRUE` by default, so the
statement errors.

Adding `row_exp_dte` to the join key fixes that case but not the one where a source corrects a value without
moving its dates — there the `D` and `I` rows share key, eff *and* exp.

Snowflake also has no `WHEN NOT MATCHED BY SOURCE` clause, so a MERGE cannot soft-delete rows that have
simply disappeared from the new timeline.

**Splitting into an UPDATE and an INSERT removes the entire class of problem.** It is also semantically
honest: this is not an upsert. It is closing one set of rows and appending a different set.

---

## 6. Steps 2 and 3

```sql
-- STEP 2 — soft-delete
UPDATE TGT_TABLE
SET IS_DEL = 'Y', AUDIT_UPD_TS = CURRENT_TIMESTAMP()
FROM STG_TABLE S
WHERE S.ACTION_FLAG = 'D' AND TGT_TABLE.TGT_SK = S.TGT_SK;

-- STEP 3 — insert
INSERT INTO TGT_TABLE (...)
SELECT SEQ_TGT_SK.NEXTVAL, ... FROM STG_TABLE WHERE ACTION_FLAG = 'I';
```

**The `D` rows carry the target row's own surrogate key**, so the update matches on one column. Matching on
`(business_key, row_eff_dte, row_exp_dte)` instead would also hit a row soft-deleted in an *earlier* run
that happened to cover the same interval.

---

## 7. IDMC components

| Step | Component | Notes |
|---|---|---|
| 1 | Mapping: Source transformation with **custom query / SQL override** → stage table, operation **Insert** | Needs the **Create Temporary View** session property for pushdown to work with a SQL override |
| 2 | Mapping: Source = stage filtered `action_flag='D'` → Zone2 target, operation **Update** | Informatica's docs state Create Temporary View is mandatory before configuring update, upsert or delete |
| 3 | Mapping: Source = stage filtered `action_flag='I'` → Zone2 target, operation **Insert** | Plain insert |

All three push down: source and target are both in Snowflake.

**Possible consolidation**: Snowflake targets in IDMC support a **Data Driven** operation, where a flag
column decides insert vs. update per row, which would collapse Steps 2 and 3 into one mapping. Keep them
separate for v1 — unambiguous and easier to debug — and test Data Driven afterwards.

---

## 8. Restart behaviour

The diff is recomputed from scratch each run against whatever the target holds *at that moment*, so the
whole thing is idempotent per key. If Step 2 succeeds and Step 3 fails, the next run recomputes, sees those
rows are no longer live, and re-emits the inserts. Nothing to unwind, no special restart logic beyond the
stage's truncate-and-reload.

**One gap**: between Step 2 and Step 3 the target holds soft-deleted rows with no replacement. Whether IDMC
can wrap both mappings in one Snowflake transaction under pushdown is **unverified** — see §11.

---

## 9. The POC

`scd_poc_snowflake.sql` runs the whole thing against `LM_POC_DB.POC_SCHEMA`. Copy, paste, execute top to
bottom. Every `EVIDENCE` block returns a result set to capture.

### Test data

| Key | Purpose |
|---|---|
| **K1** | The main scenario. Table 1 never changes on Day 2, yet three of its target rows get rewritten |
| **K2** | Day 2 changes a column that never reaches the target. Must produce **no** target change at all |
| **K3** | Never touched after Day 1. Must not be re-read or re-written |

### Expected results

**After Day 1** — 5 target rows, all `is_del = 'N'`:

| business_key | row_eff_dte | row_exp_dte | tbl1 | tbl2 |
|---|---|---|---|---|
| K1 | 2026-09-09 | 2026-09-10 | *(null)* | p |
| K1 | 2026-09-10 | 2026-09-21 | a | p |
| K1 | 2026-09-21 | 9999-12-31 | b | p |
| K2 | 2026-09-05 | 9999-12-31 | m | n |
| K3 | 2026-09-01 | 9999-12-31 | g | h |

**Day 2 stage** — exactly 4 `I` and 2 `D`, all K1. Nothing for K2 or K3.

**After Day 2** — K1 has 5 live rows and 2 superseded:

| business_key | row_eff_dte | row_exp_dte | tbl1 | tbl2 | is_del |
|---|---|---|---|---|---|
| K1 | 2026-09-09 | 2026-09-10 | *(null)* | p | N |
| K1 | 2026-09-10 | 2026-09-15 | a | p | N |
| K1 | 2026-09-10 | 2026-09-21 | a | p | **Y** |
| K1 | 2026-09-15 | 2026-09-21 | a | q | N |
| K1 | 2026-09-21 | 2026-09-22 | b | q | N |
| K1 | 2026-09-21 | 9999-12-31 | b | p | **Y** |
| K1 | 2026-09-22 | 9999-12-31 | b | r | N |

### The eleven assertions

| | Checks |
|---|---|
| T1 / T2 | K1 has 5 live and 2 superseded rows |
| T3 / T4 | K2 unchanged and never soft-deleted — **the collapse worked** |
| T5 | K3 untouched |
| T6 | K1's live timeline has no gaps or overlaps |
| T7 | `business_key` + `row_eff_dte` is unique **among live rows** |
| T8 | …and deliberately **not** unique across all rows — 2 duplicate pairs |
| T9 / T10 | The 9-Sep row exists and carries no Table 1 value |
| T11 | Re-running with no new data produces an **empty stage** — idempotence |

T7 and T8 together are the important pair: they pin down the consequence that every consumer query and
every future merge has to filter on `is_del`.

---

## 10. Confirmed limitation — mixed clocks

The team has confirmed Zone1 holds **SCD2 tables built from sources that overwrite in place**. Those tables
have no business effective date; their `row_eff_dte` records *when Zone1 loaded the row*.

Join one to a genuinely business-dated table and the target timeline mixes two clocks. If a change really
happened on 11-Sep but was loaded on 18-Sep, the target says 18-Sep, and an as-of-12-Sep query returns the
stale value. **No query fixes this later — the information is not there.**

Two options, and it is a business decision rather than a technical one:

1. **Accept it.** The target's dates mean "business date where we have one, load date where we don't".
   Cheapest, but it must be written down for consumers.
2. **Bar those tables from setting dates.** Use them for values only, snapped to boundaries from
   business-dated tables. The timeline then means one thing throughout, at some loss of fidelity.

---

## 11. To verify before build

| | Question | Why it could change the design |
|---|---|---|
| 1 | Does a SQL override this large still generate a **single pushed-down statement**, or does IDMC give up and pull data to the agent? | If pushdown breaks past some complexity, Step 1 must be split into several mappings with work tables between them |
| 2 | Can Steps 2 and 3 share one Snowflake **transaction**? | If not, we accept a brief window where soft-deleted rows have no replacement |
| 3 | Does **Data Driven** target operation work under SQL ELT optimization? | Would collapse Steps 2 and 3 into one mapping |
| 4 | Does the real Zone2 target have a **surrogate key** usable as the update match column? | The POC assumes one; without it Step 2 needs a different predicate |
| 5 | How many assets are affected? | 2–3 means hand-written SQL per asset. 15+ means this should be a metadata-driven template, which is a much larger build and hard to reverse |

Question 1 is worth an early spike: build the query, run the mapping, and read the session log for whether
it reports full pushdown.

---

## 12. Still open on the problem side

Carried from `scd_scenario_matrix.md` §11 — these do not block the POC but do affect scope:

- Does a current-bucket read give one row per key, or all versions?
- Can a source *remove* one of its own versions? If so, nothing in the delta will ever flag it.
- Is "current value only + current value only → SCD2 target" already a solved pattern?
- Are SCD1 and SCD2 the only target types?
- Does a join returning many rows per key per date need handling here, or is it a separate track?
