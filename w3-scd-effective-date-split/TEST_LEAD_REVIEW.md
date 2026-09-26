# W3 POC v2 — independent test lead review

**Reviewed**: 2026-09-26 · **Scope**: `Requirement.xlsx`, `solution_design.md`, `glossary.md`, `poc_v2/`
(all 15 scenarios, 69 test cases), `poc_v2/evidence/`, `tools/`
**Method**: independent re-execution, evidence audit, requirement trace, and mutation testing.

> ## Verdict — CONDITIONAL SIGN-OFF
>
> **Approved to proceed, subject to four blocking exit criteria (§6) closing before the IDMC build starts.**
>
> The POC's stated objective — prove the 18-rule logic is correct and implementable in Snowflake, one
> `MERGE`, no stored procedures — **is met and genuinely evidenced**. The reservation is not that the logic
> is wrong. It is that one *unstated precondition* is load-bearing, and the suite cannot currently detect
> its violation.

---

## 1. What was independently verified

Nothing in this section is taken from the package's own claims. Each row was re-derived.

| Check | Method | Result |
|---|---|---|
| 69 test cases pass | Re-ran all 15 scenarios through `tools/run_scenario_duckdb.py` | **69/69 PASS — reproduced** |
| No Snowflake-only SQL errors | `tools/check_sql_lint.py` | clean |
| Apply MERGE has not drifted | `tools/check_merge_drift.py` | 70 copies byte-identical |
| Evidence volume | Unzipped the OOXML, counted `xl/media/*` | **346 PNGs**, 17 sheets, 15 drawings |
| Captions reconcile | Parsed `caption_ledger.json` | **346 captions**, one per image |
| Verdicts reconcile | Parsed `verdicts.json` | 69 entries, all PASS, matches `TEST_PLAN.md` |
| Evidence is really Snowflake | Rendered `image1.png`, `image257.png` | **Genuine Snowsight** — result-grid chrome, row counts, query timings, column type badges. Data matches the seeds exactly |
| S12 TC03 regression guard is real | Rendered `image257.png` | Confirmed: on `Z1_RERUN`, rules **4, 6, 17** appear and **18 does not**; the rule-17 insert reaches `9999-12-31` |
| Rule table is faithful to the requirement | Parsed `xl/sharedStrings.xml` of `Requirement.xlsx` for `<strike>` runs | **Corroborated** — see §2 |

### The strikethrough claim checks out

`solution_design.md` §6 rests on reading struck-through spreadsheet text as non-authoritative. That is an
unusual thing to take on trust, so it was verified at file-format level. The raw OOXML confirms it:

| Shared string | Struck text | Surviving text |
|---|---|---|
| 8 | `upd exp date` | `(update with is_deleted = 'Y' & create new entry with same row eff date)` |
| 8 | `upd exp date with new uuid if needed` | `(update with is_deleted = 'Y' & create new entry with same row eff date)` |
| 11, 12 | `upd` (×2 each) | `(update with is_deleted = 'Y' & create new entry)` |

The design's reading is correct. **Requirement fidelity is the strongest part of this package**, and it
also resolves a question the design raises about itself — see D6.

---

## 2. What the team did well

Recorded because it is load-bearing for the verdict, not as courtesy.

- **Chained runs, not reset-per-test-case.** TC01 loads an empty target through the real pipeline and every
  later case is the next run against its predecessor's output. This is the correct structure for testing an
  *incremental* load, and it is what made the rule-17/18 defect findable at all — the bug is unreachable by
  any single-run or reseeded test.
- **A real defect found, fixed, and guarded**, with the guard verified in the evidence rather than asserted.
- **Honest negative reporting.** Rules 1, 3 and 18 are explicitly *not* claimed as covered the same way as
  the other fifteen — they emit nothing, so they are proved by zero writes. Both evidence gaps (the Copilot
  button occluding `AUDIT_BATCH_ID`, the cropped empty-stage shots) are disclosed rather than buried.
- **Generated SQL with drift checking**, so 70 copies of the apply cannot silently diverge.
- **`expected_results.txt` is a genuine predicted-state document**, row by row. This is what makes the
  manual screenshot verification credible rather than a rubber stamp.
- **`check_sql_lint.py` encodes two real defects** the harness structurally cannot catch. Writing a checker
  for your own tooling's blind spot is good practice.

---

## 3. Mutation testing

Passing tests prove nothing unless they can fail. **26 faults** were injected into the Step 1 view and the
apply logic; the full suite was re-run against each.

**17 caught · 9 survived.** Mutation score **65%** (71% excluding two equivalent mutants, §5).

### Caught — the suite is strong here

| Injected fault | Detected by |
|---|---|
| `ROW_HASH` omitted from the diff (dates only) | S01, S06, S10, S12, S15 — 19 cases |
| Boundaries drop expiry dates (eff only) | S05, S10, S12, S15 — 11 cases |
| Live view drops the dead-record filter | S01, S06, S12, S14, S15 — 20 cases |
| Stage 2 reads only delta rows, not full history | 12 scenarios — 32 cases |
| Rule 5 retires instead of expiring in place | 10 scenarios — 20 cases |
| Rule 18 emitted as a retire instead of ignored | all 15 scenarios — 37 cases |
| Collapse groups by value, not consecutive run | S04 |
| **Rule-17 rerun defect reintroduced** | S12 — 6 cases |
| Impacted-key detection stops seeing SRC_2 | 10 scenarios |
| `ROW_HASH` widened to a non-target column | all 15 scenarios |
| Retirement mechanisms swapped | S01, S06, S10, S12 |
| `'U'` branch deleted | 9 scenarios |
| `IS_DEL='Y'` on insert | all 15 scenarios |
| `ROW_HASH` not persisted | all 15 scenarios |
| `AUDIT_BATCH_ID` constant | 10 scenarios |
| `JOB_STATUS='Completed'` filter removed | S13 |
| De-dup picks earliest — *in SRC_2 only* | — see F3 |

### Survived — the coverage holes

Every survivor below is a fault that **breaks the logic while all 69 test cases still report PASS**.

| # | Injected fault | Severity |
|---|---|---|
| F1 | Stage-6 containment loosened to overlap | 🔴 high |
| F2 | Per-`(key, eff)` de-duplication deleted from `s1_dedup` | 🟠 medium |
| F2 | Per-`(key, eff)` de-duplication deleted from `s2_dedup` | 🟠 medium |
| F3 | De-dup tie-break flipped `DESC` → `ASC` ("latest wins" reversed) | 🟠 medium |
| F4 | Gap-guard `LAG(ROW_EXP_DTE) = ROW_EFF_DTE` removed from the island flag | 🟠 medium |
| F5 | UUID restamp removed from the `'U'` branch | 🟠 medium |
| F5 | UUID never written by any MERGE branch | 🟠 medium |
| — | Impacted keys widened to every key | ⚪ equivalent, §5 |
| — | Window made inclusive at the start (`>` → `>=`) | ⚪ equivalent, §5 |

---

## 4. Findings

### 🔴 F1 — Overlapping source intervals cause silent corruption, then hard failure

`solution_design.md` §4 states:

> *"Stage 6 cannot fan out, and this is structural. Because intervals are cut at every boundary from both
> sources, each interval falls entirely inside at most one version per source."*

That guarantee holds **only if no source contains overlapping intervals for one business key**. That
precondition is stated nowhere and tested nowhere. Per-`(key, eff)` de-duplication does not cover it —
overlapping versions have *different* effective dates, so de-dup never sees them.

**Reproduced.** Two overlapping SRC_1 versions for one key:

```
SRC_1:  K9  A1  2026-08-01 → 2026-08-20
        K9  A2  2026-08-10 → 2026-08-31     ← overlaps A1 on 08-10..08-20
SRC_2:  K9  B1  2026-08-01 → 9999-12-31
```

| Depth | Observed behaviour |
|---|---|
| **2-way, run 1** | The `08-10 → 08-20` interval matches **both** versions. Stage emits 5 rows where 4 are correct. Target ends with **two live rows at the same `(K9, 2026-08-10)`** — violating S15's own stated invariant *"one live row per (key, eff date)"* |
| **2-way, run 2** *(sources unchanged — must be a no-op)* | Stage is **not empty**: 2×`D` + 2×`I`. **Idempotence is permanently broken.** Every subsequent run retires both rows and inserts two fresh ones — the table grows and surrogate keys churn indefinitely, with no convergence |
| **3-way overlap** | Run 2 emits **two `D` instructions against the same target surrogate key** (SKs 7, 8 and 9 each receive 2). In Snowflake with `ERROR_ON_NONDETERMINISTIC_MERGE = TRUE` — the default the design explicitly relies on — **the MERGE aborts and the job fails** |

So the failure mode degrades from *silent data corruption* to *hard runtime failure* purely as a function of
overlap depth. The 2-way case is the dangerous one: it reports success.

This also falsifies, for this input class, the determinism argument in §5: *"the diff emits at most one
instruction per target row, so no target row is matched twice."*

**Why this is not hypothetical.** §11 confirms Zone1 holds SCD2 tables built from sources that overwrite in
place, whose `row_eff_dte` records *when Zone1 loaded the row* — exactly the population where a re-load,
replay or late-arriving correction produces overlapping intervals. Zone1 has no enforced constraints, and
the `C` (corrupt) test type already exists for malformed input, covering NULL key, duplicate `(key, eff)`
and out-of-window timestamps. Overlapping intervals is the obvious fourth member of that family, and it is
the only one missing.

<details>
<summary>Reproduction SQL (run after <code>00_objects.sql</code>)</summary>

```sql
TRUNCATE TABLE ETL_DATA_INGESTION_SOURCE_WINDOW;
TRUNCATE TABLE Z1_BROKER_PARTY_HIST;
TRUNCATE TABLE Z1_BROKER_COMMISSION_HIST;
TRUNCATE TABLE Z2_BROKER_PARTY_DIM;
TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;

INSERT INTO ETL_DATA_INGESTION_SOURCE_WINDOW
 (EXECUTION_RUN_ID, JOB_RUN_ID, TARGET_TABLE_NAME, SOURCE_TABLE_NAME,
  WINDOW_START, WINDOW_END, EXECUTION_TYPE, JOB_STATUS)
VALUES
 (901,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_PARTY_HIST',
  TIMESTAMP '2026-09-01 00:00', TIMESTAMP '2026-09-21 08:00','NEW','Completed'),
 (901,1,'Z2_BROKER_PARTY_DIM','Z1_BROKER_COMMISSION_HIST',
  TIMESTAMP '2026-09-01 00:00', TIMESTAMP '2026-09-21 08:00','NEW','Completed');

INSERT INTO Z1_BROKER_PARTY_HIST
SELECT    'K9','A1',NULL,DATE '2026-08-01',DATE '2026-08-20','U-1',TIMESTAMP '2026-09-21 08:00'
UNION ALL SELECT 'K9','A2',NULL,DATE '2026-08-10',DATE '2026-08-31','U-2',TIMESTAMP '2026-09-21 08:00';
INSERT INTO Z1_BROKER_COMMISSION_HIST
SELECT    'K9','B1',NULL,DATE '2026-08-01',DATE '9999-12-31','U-9',TIMESTAMP '2026-09-21 08:00';

TRUNCATE TABLE STG_Z2_BROKER_PARTY_DIM;
INSERT INTO STG_Z2_BROKER_PARTY_DIM SELECT * FROM V_STEP1_BROKER_PARTY_DIM_DIFF;

-- two stage rows for the SAME interval -- the fan-out the design says cannot happen
SELECT RULE_NO, ACTION_FLAG, BROKER_STATUS_CDE, ROW_EFF_DTE, ROW_EXP_DTE
FROM   STG_Z2_BROKER_PARTY_DIM ORDER BY ROW_EFF_DTE, ACTION_FLAG;
```

Apply the MERGE, then register run 902 over the same window with no source change. The stage should be
empty. It is not. For the 3-way case, add a third version `A3 2026-08-05 → 2026-08-25` and check:

```sql
SELECT BROKER_PARTY_DIM_SK, count(*) FROM STG_Z2_BROKER_PARTY_DIM
WHERE ACTION_FLAG <> 'I' GROUP BY 1 HAVING count(*) > 1;   -- non-empty = MERGE will abort
```
</details>

---

### 🟠 F2 — De-duplication is untested in both sources

The `QUALIFY ROW_NUMBER() OVER (PARTITION BY BROKER_ID, ROW_EFF_DTE ORDER BY GRS_REFINED_TIMESTAMP DESC)`
de-dup can be **deleted outright from `s1_dedup` and from `s2_dedup`** with **69/69 still passing**.

The reason is specific and worth stating, because the test looks like it covers this. S07 TC05 — the only
duplicate `(key, eff)` case in the suite — is constructed so that:

1. both copies carry **identical** `GRS_REFINED_TIMESTAMP` (deliberate: no tie-break), **and**
2. one copy's value (`B5`) **equals what the target already holds**.

With de-dup removed, the fan-out does occur — two rows reach `new_rows` for one interval — but one
classifies as rule 1 (*do nothing*) and the other as rule 9, so the net target state is accidentally
correct and the assertion passes. **The fan-out is real; the assertion is blind to it.** Had neither copy
matched the incumbent, the run would have produced two `D` rows on one surrogate key.

`solution_design.md` §4 states *"**BR007** exercises it."* BR007 belongs to POC v1, which was deleted. v2
did not replace that coverage.

---

### 🟠 F3 — "Latest copy wins" is untested

Flipping the tie-break `ORDER BY GRS_REFINED_TIMESTAMP DESC` → `ASC` passes **69/69**. Because S07 TC05
uses identical timestamps by design, no test can distinguish the two orderings.

This compounds with `solution_design.md` §13 open question 1 — *"are they restatements where the latest
wins, or distinct versions that must all land?"* The rule is therefore **simultaneously unsettled with the
business and unverified in test**. §13 correctly identifies it as *"the only one that changes the design
rather than the documentation."*

---

### 🟠 F4 — S05 does not test its own premise

S05 is titled, in both `TEST_PLAN.md` and `poc_v2/README.md`:

> *"A gap in cover, **with the same value either side**"*

`solution_design.md` §4 names it one of the four things that are easy to get wrong:

> *"a gap in cover is not a merge: if a source has no value for a period, the periods either side stay
> separate **even when the value is identical**."*

The seed data is:

```
K1  A1  2026-08-01 → 2026-08-10
K1  A2  2026-08-20 → 9999-12-31      ← gap 08-10..08-20, but A1 ≠ A2
```

The values differ, so `LAG(VAL) IS NOT DISTINCT FROM VAL` already keeps the two versions in separate
islands. The gap-guard `AND LAG(ROW_EXP_DTE) = ROW_EFF_DTE` never does any work. Removing that guard
entirely passes **69/69**.

The guard is correct and load-bearing for real data. It is simply not the thing S05 is exercising.

---

### 🟠 F5 — UUID is never asserted

Removing the UUID write from **every** MERGE branch passes **69/69**. So does removing it from the `'U'`
branch alone.

This matters more than it first appears. **Rules 2 and 4 exist solely to restamp the UUID** — it is their
only behavioural difference from rules 1 and 3, which emit nothing. Mutation F5 shows the suite verifies
that a `'U'` stage row *is emitted* (a row-count assertion) but never that the UUID *actually changes on
the target row*.

`poc_v2/README.md` states the manual screenshot verification checked `RULE_NO`, `ACTION_FLAG`, `DEL_IND`,
business key, status and tier codes, both dates, `IS_DEL`, `AUDIT_BATCH_ID`, row counts and MERGE counts.
**UUID is absent from that list too.** The column is unverified in both the automated and the manual pass.

Note this cannot be properly closed before `solution_design.md` §13 open question 9 is answered — you
cannot assert a value whose definition is undecided.

---

### 🟡 F6 — The harness runs a fourth, unguarded copy of the apply logic

`tools/run_scenario_duckdb.py` intercepts every `MERGE` and substitutes its own hand-written
`MERGE_AS_THREE` emulation. `check_merge_drift.py` proves the 70 SQL copies agree **with each other** —
but nothing ties any of them to what the tests actually execute.

**Confirmed**: mutating the MERGE inside `00_objects.sql` — including swapping the two retirement
mechanisms — changes **no test result at all**, because that statement is never run by the harness. The
same mutation applied to `MERGE_AS_THREE` is caught immediately by S01, S06, S10 and S12.

This is precisely the failure mode `check_merge_drift.py` was written to prevent, reintroduced one level
up. Its own docstring describes it:

> *"...which is exactly how `00_objects.sql` and `01_ddl_and_merge.sql` came to disagree about `MERGE_KEY`
> without anything failing."*

Two secondary notes on the emulation, neither currently a defect but both worth recording:

- It applies the branches **sequentially** (`U`, then `D`, then `I`), whereas a real multi-clause `MERGE`
  evaluates every clause against one pre-statement snapshot. Safe today only because the diff emits at most
  one instruction per target row — which is exactly the property F1 breaks.
- Statement-level Snowflake behaviour (`ERROR_ON_NONDETERMINISTIC_MERGE`, clause-match semantics) is by
  construction untestable here. The design acknowledges this; F1 is the case where it bites.

---

## 5. Not defects — recorded so they are not re-investigated

Two mutations survived for a legitimate reason and should **not** be treated as gaps:

| Mutation | Why it survives |
|---|---|
| Impacted-key detection widened to **every** key | The rebuild is idempotent, so unimpacted keys classify as rules 1/3 and write nothing. The target is identical; only the cost changes |
| Sourcing window made inclusive at the start (`>` → `>=`) | A row re-entering the window rebuilds to the same timeline and writes nothing |

Both are genuinely harmless to the target. The observation worth carrying forward is narrower: the
documented **half-open window boundary** and the claim that *"impacted-key detection does not reach too
far"* (S08) are correct **by construction**, not **by test**. Idempotence is doing the work. That is a
legitimate design property — but if Step 1 is ever "optimised" to trust the target instead of rebuilding,
both of these silently become real defects. §13 already flags this exact risk.

---

## 6. Documentation defects

These matter because a sign-off package is read by people who will not re-derive it.

| # | Where | Defect |
|---|---|---|
| **D1** | `solution_design.md` §10.A | States *"neither it nor `win` filters on `TARGET_TABLE_NAME`"*. **Both do** — `00_objects.sql:169` and `:176`. A build team reading this would "fix" something already fixed, and may miss the genuine residual risk buried in the same paragraph (`MAX()` should come from the framework run context) |
| **D2** | `solution_design.md` §9 | Wholesale **POC v1 content** — BR001–BR007, the T01–T26 assertions, "Verified results — Day 1 and Day 2" — inside a document whose §16 states *"Everything proved in POC v1 is treated as unproven."* Lines 341–342 still read *"The POC predates this rule… BR001 and BR006 need re-running"*, directly contradicting the headline |
| **D3** | `solution_design.md` §4 | The four trap-coverage claims (*"BR004 exercises the repeat, BR005 the gap"*, *"BR007 exercises it"*, *"BR006 exercises it"*) are inherited from deleted v1 assets. **Two of the four are not exercised in v2** — see F2 and F4 |
| **D4** | `poc_v2/TEST_PLAN.md` §"Why S15 matters most" | Describes a test that **does not exist**: *"TC02 in particular — ten consecutive runs, random mutations, compared after every one."* §16 records that this approach was dropped; the grid shows S15 TC02 as a single run. §16's own table still labels S15 *"Volume and differential"* |
| **D5** | `poc_v2/TEST_PLAN.md`, `README.md` | **"Volume" is a misnomer.** S15 is 6 keys and 15 seeded rows — the largest key count in any scenario; the largest target row count asserted anywhere in the suite is 17, and the largest live-view count 15. This is a multi-key invariant test, which is valuable — but no scale or performance evidence exists anywhere in the package |
| **D6** | `solution_design.md` §6 | The rule table marks rules 8/10/12/14/16 as *"as N, + update UUID"*. Rule 8's UUID phrase is **struck through** in `Requirement.xlsx` (§1), and the code correctly does not restamp. **The code is right; the table over-specifies.** As implemented, rules 10/12/14/16 are behaviourally identical to 9/11/13/15 and are distinguished only by the debug `RULE_NO` label |
| **D7** | root `README.md` §"Current stage" | Repeats two claims F2 and F4 contradict — listing *"a gap in cover with the same value either side"* and *"the same version arriving twice in one window"* among cases *"all covered and confirmed"* |

---

## 7. Exit criteria

### Blocking — before the IDMC build starts

| # | Criterion | Closes |
|---|---|---|
| **B1** | **Resolve the overlap assumption.** Either (a) state *"non-overlapping intervals per key per source"* as a documented precondition backed by an upstream DQ contract, or (b) add a guard in Step 1 that rejects or collapses overlaps. Then add a `C`-type test case that fails without it | F1 |
| **B2** | **Add real de-dup coverage** — a `(key, eff_date)` duplicate with **distinct** timestamps where **neither** value matches the incumbent. Must fail if the `QUALIFY` is removed **or** if the tie-break is reversed | F2, F3 |
| **B3** | **Fix S05 to test its stated premise** — same value either side of the gap. Must fail if the gap-guard is removed | F4 |
| **B4** | **Bring the harness under drift control** — generate `MERGE_AS_THREE` from `00_objects.sql`, or extend `check_merge_drift.py` to cover it | F6 |

B1 is the one that must not slip. It is a **design decision**, not a test fix, and it becomes an order of
magnitude more expensive once IDMC mappings exist.

### Non-blocking — before the design is circulated further

1. Add a UUID assertion (F5) — but settle §13 Q9 first.
2. Correct D1; delete or clearly quarantine §9's v1 content (D2); fix §4's trap claims (D3); reconcile the
   S15 "differential" text (D4); correct the §6 UUID column (D6); update the root README (D7).
3. Rename S15 from "volume" to "multi-key invariants" and log scale/performance as an explicit open item
   feeding §12 Q1 (D5).

### Recommended method change

**Replace "18/18 rules reached" as the coverage gate with a mutation score.** Rule coverage measures
*reachability*; it says nothing about *sensitivity*, and this review demonstrated five separate faults that
leave all 69 cases green. The team already has the instinct — §9 documents exactly this technique with
three injected faults — but it was applied to v1 and not carried into v2. **Re-adopting the project's own
v1 method is the single highest-value change available.**

A second, structural observation: the v1 → v2 transition **lost coverage silently**. v1's BR004–BR007 each
targeted one named trap; v2's S04–S07 are broader and better structured, but two of those traps quietly
stopped being tested while the design doc continued to claim they were. When retiring a test asset, port
its *assertions* first and its *narrative* second — here the narrative survived and the assertions did not.

---

## 8. Questions needed to convert this to full sign-off

| # | Question | Why it blocks |
|---|---|---|
| 1 | **Can a Zone1 history-bucket table contain overlapping intervals for one business key?** | Decides whether B1 is a documentation line or a code guard. Highest-value question in the pack |
| 2 | **What is `UUID` on a target row** — generated per row and restamped, or carried from a source? (§13 Q9) | F5 cannot be closed before this. If carried, which source supplies it for an interval only one source covers? |
| 3 | **How many assets will use this pattern?** (§12 Q5) | At 2–3, hand-written SQL per asset is fine. At 15+, the per-target hand-written view is the wrong shape — and that is hard to reverse after the IDMC build |

---

## 9. Summary

| | |
|---|---|
| **Logic** | Sound. Verified against the requirement down to spreadsheet formatting |
| **Evidence** | Real. 346 genuine Snowflake screenshots, reconciled against a proper predicted-state document |
| **Test structure** | Correct. Chained incremental runs, which is what found the one real defect |
| **Test sensitivity** | **Strong in the middle, thin at the edges.** 17 of 26 injected faults caught |
| **The thin edges** | All sit on **unconfirmed assumptions about source data quality** |
| **Documentation** | Materially out of step with the code in seven places, mostly v1 residue |

**Close B1–B4 and this gets unconditional sign-off.**
