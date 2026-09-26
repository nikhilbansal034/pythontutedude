# W3 solution design — multi-source SCD2 effective-date split

Status: **rule locked, POC written and passing.** This file covers how the problem gets solved and the POC
that proves it. Vocabulary is in `glossary.md`.

The runnable POC is `poc_v2/` — `00_objects.sql` for the objects and both steps, then `scenarios/S01.sql`
through `S15.sql`. **69 test cases, 69 passing.**

> The first POC (`poc_snowflake.sql`, `POC_Evidence.docx`, `solution_deck.html`) has been **deleted**. It was
> written before the 18-rule table in §6 existed and implemented a plain hash-diff instead, so running it
> would have produced behaviour this design no longer specifies. Its scenario catalogue survives as
> `sources/Final_Scenarios_v2.xlsx`, kept as historical input rather than a live artefact.

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
| **Hard constraint** | The apply must be a single `MERGE`. Separate `UPDATE` and `INSERT` statements are not approved by the client — see §5 |

ABC framework integration is deliberately out of scope here.

---

## 2. The reframe that makes it set-based

The instinct is to walk each changed row, find the target rows it affects, and patch them. That is
inherently row-by-row and led the original discussion toward cursors.

The alternative:

> **For any business_key touched this run, throw its timeline away and rebuild it from scratch from both
> sources, then diff the rebuilt timeline against what the target holds.**

Same output, fully set-based, and idempotent for free — re-running with no new data produces no changes,
which the POC asserts as T12.

---

## 3. Two steps

```
   Zone1 Table 1              Zone1 Table 2
         └────────────┬─────────────┘
                      ▼
        STEP 1 — one mapping, SQL override in the Source transformation
        rebuild the timeline for every changed key, diff against the target
                      ▼
              STAGE table (truncate + reload)
              every row carries action_flag 'U', 'D' or 'I'
              ('U' is rare - only a row that sat at the high end date)
                      ▼
        STEP 2 — ONE MERGE, atomic
        'U' expire in place · 'D' retire · 'I' insert
        a retire+insert emits TWO stage rows:
        one carrying the target SK, one carrying NULL
                      ▼
                 Zone2 target
```

**Step 1 does all the thinking.** When it finishes there are no decisions left — the stage is a complete
instruction list. **Step 1 writes nothing to the target**, so Steps 2 and 3 are needed to apply it. They
contain no logic; they read a flag and act.

**Step 2 is a single atomic statement**, so there is no ordering to get wrong and no window in which the
target holds retired rows with no replacement.

**What happens to a matched row is decided by its CURRENT expiration date, not by its hash.** A row already
closed with a real date was a statement published downstream, so changing it is a correction and the old row
is retired to keep the trail. A row sitting at the high end date never committed to an end date, so closing
it is expired in place. The hash only decides *within* the high-end-date branch. See §6.

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
| 7 | **Read the target** | Current rows for those keys where `is_del = 'N'` **AND `row_eff_dte < row_exp_dte`** — the second condition excludes dead records, which keep `is_del = 'N'`; without it a re-run sees two live rows at the same effective date and cannot match |
| 8 | **Diff** | Match on `(business_key, row_eff_dte)`; the matched row's **current expiry** decides, then its **hash** — see §6 |

### Four things that are easy to get wrong

**Stage 2 is the one people miss.** On Day 2 Table 1 does not change at all, but its full history still has
to be read — otherwise the rebuilt timeline has no Table 1 values and the target is destroyed. From the
2026-09-18 call:

> *"even though there is no change in table one data, still we need to account for all the records related
> to that key where we received a change in Table 2, and vice versa"*

**Stage 4 must include expiry dates, not just effective dates.** If a source covers 10-Sep to 15-Sep and its
next version starts 20-Sep, using only effective dates gives boundaries {10, 20} and the value would be
wrongly carried across the 15–20 gap. Including expiry dates cuts the interval correctly and leaves the gap
blank. The worked example has no mid-timeline gap; **BR005** in the POC does, stopping on 10-Apr and
starting again on 20-Apr.

**Stage 3's collapse has two traps.** Only *consecutive* versions merge, so `p → q → p` must not collapse
into one. And a gap in cover is not a merge: if a source has no value for a period, the periods either side
stay separate even when the value is identical. The POC implements both as an explicit "new run starts
here" flag rather than relying on value comparison alone. **BR004** exercises the repeat, **BR005** the gap.

**Stage 6 cannot fan out, and this is structural.** Because intervals are cut at *every* boundary from both
sources, each interval falls entirely inside at most one version per source. Each join matches 0 or 1 rows.
No aggregation or de-duplication is needed after the join. What keeps that true when the *same* version
arrives twice in one window is stage 3a's per-`(key, eff date)` de-duplication — **BR007** exercises it.

**Stage 8 compares dates *and* values.** A source correcting a value without moving its dates still produces
a `D` + `I` pair. Comparing dates alone would silently keep the stale value. **BR006** exercises it.

---

## 5. MERGE is mandatory — and why the naive form fails

**The client requires a single `MERGE`.** Separate `UPDATE` and `INSERT` statements are not approved. That is
a constraint to design around, not a preference, so this section records what breaks and what it costs.

The natural instinct is one `MERGE` from stage into target. In its naive form it fails at runtime.

On Day 2, the stage holds these rows for BR001:

```
D  (BR001, 10-Sep, 21-Sep)     I  (BR001, 10-Sep, 15-Sep)
D  (BR001, 21-Sep, high end)   I  (BR001, 15-Sep, 21-Sep)
                               I  (BR001, 21-Sep, 22-Sep)
                               I  (BR001, 22-Sep, high end)
```

Three problems:

1. The live target row `(BR001, 10-Sep, 21-Sep)` matches **both** the `D` row and an `I` row on
   `(BROKER_ID, ROW_EFF_DTE)`. Snowflake's `ERROR_ON_NONDETERMINISTIC_MERGE` defaults to `TRUE`, so the
   statement errors. Adding `ROW_EXP_DTE` to the join key fixes that case but not S06, where a source
   corrects a value without moving its dates — there the `D` and `I` rows share key, eff *and* exp.
2. **A single MERGE cannot both update a matched target row and insert a replacement driven by that same
   source row.** Every retire-plus-insert in §6 needs exactly that.
3. Snowflake has no `WHEN NOT MATCHED BY SOURCE`, so a MERGE cannot on its own retire rows that have simply
   disappeared from the new timeline.

### Two routes that satisfy the constraint

| | Approach | Cost |
|---|---|---|
| **A** | **Double-row stage.** Step 1 emits *two* stage rows for a retire-plus-insert: one that matches the target (drives the retire) and one carrying a deliberately non-matching join key (drives the insert). One MERGE with several `WHEN MATCHED ... AND action_flag = ...` clauses plus `WHEN NOT MATCHED` then performs `'U'`, `'D'` and `'I'` in one statement | Changes Step 1's output shape; the stage roughly doubles for changed keys |
| **B** | **IDMC's own SCD2 merge pattern** — two target transformations writing to the same table, one Update and one Insert, combined by *context-based optimization for multiple targets* | None, if it pushes down as one MERGE. This is the vendor's documented pattern |

**Decision: route A, the double-row stage.** Determinism holds by construction — the diff emits at most one
instruction per target row, so no target row is matched twice.

### No column is added to the stage

The stage structure is shared across pipelines, so adding a column to it means an `ALTER` everywhere. The
apply therefore adds **nothing**:

| Column | Status | Why it is not new |
|---|---|---|
| `BROKER_PARTY_DIM_SK` | already there | Carries the target SK on `'U'`/`'D'` and a newly allocated SK on `'I'`. It **is** the merge key |
| `ACTION_FLAG` | the one added column | Cannot be derived — see below. Rename it to the stage's existing operation/CDC indicator if there is one, and the apply adds nothing |
| `DEL_IND` | already there | Populated for lineage, but the MERGE no longer reads it |
| `RULE_NO` | POC only | Debug — records which of the 18 rules produced the row. Dropped when this folds into the real pipeline |

An earlier draft carried two more, and both were avoidable:

- **`MERGE_KEY`** was byte-for-byte identical to `BROKER_PARTY_DIM_SK` on every branch of the diff. Pure
  duplication. The MERGE joins on the surrogate key directly, and `'I'` rows are excluded from matching by
  `AND S.ACTION_FLAG <> 'I'` in the `ON` clause — which is a stronger guarantee than the original
  NULL-never-matches trick, because it does not depend on a freshly allocated key being absent from the
  target. A reset or externally-seeded sequence cannot break it.
- **`RETIRE_MODE`** told the MERGE which retirement mechanism to apply. It never needed telling: the
  mechanism is decided by the **target row's current expiry**, which the MERGE already reads as
  `T.ROW_EXP_DTE`:

```sql
WHEN MATCHED AND S.ACTION_FLAG = 'D' THEN UPDATE SET
     T.IS_DEL      = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.IS_DEL ELSE 'Y' END,
     T.ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = DATE '9999-12-31'
                          THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END
```

Both right-hand sides test the value the row held **before** the statement — every right-hand side in an
`UPDATE` is evaluated against the pre-update row, so the second assignment does not see what the first would
write. Reading the mechanism from the target at apply time is also strictly more robust than carrying it on
the stage, because a stage column is a snapshot taken in Step 1 while `T.ROW_EXP_DTE` is the value actually
being overwritten.

Verified in DuckDB against `scenarios/S01.sql`: both branches fire (a dead record at `SK 103`, a delete
indicator at `SK 102`), and swapping the two mechanisms changes the target — so the evidence is not vacuous.

**`ACTION_FLAG` stays, and is the only column the apply adds.** It cannot be derived:

- `'U'` and `'D'` both match an existing target row, so the MERGE has to tell them apart.
- It cannot do so by comparing hashes — a `'D'` stage row deliberately carries the **old** target values for
  debugging, so a hash comparison reports *unchanged* on precisely the rows that changed.
- Nor by expiry — rules 5 and 9 both sit at the high end date and differ only by hash, which Step 1 has
  already evaluated.

The distinction is a **conclusion Step 1 reaches** from both sources and the target together. The MERGE sees
one stage row and one target row, so it cannot re-derive it. One column, carrying one decision. If the real
stage already has an operation or CDC indicator (I/U/D), rename `ACTION_FLAG` to that and the apply adds
nothing at all.

**One file, not two.** An earlier draft split the objects across `00_objects.sql` and `01_ddl_and_merge.sql`,
and the second re-declared the target, the live view, the stage and the sequence. Two copies of the same DDL
is how they came to disagree about `MERGE_KEY` — one said NULL on `'I'` rows, the other wrote the new
surrogate key — without anything failing, because only one was ever executed. `00_objects.sql` now carries
every object plus the Step 2 MERGE, and `tools/check_merge_drift.py` fails the build if any scenario's copy
of the MERGE diverges from it.

**IDMC is deferred.** The POC is proved at Snowflake level first, with no stored procedures, and the objects
are shaped so they can be folded into the existing ETL pipeline afterwards. Whether IDMC renders this as one
pushed-down MERGE — via a Data Driven target operation, or via its own two-target SCD2 pattern — is a
separate spike, not a blocker.

> **Sourcing caveat**: `docs.snowflake.com` and `docs.informatica.com` are both blocked by this environment's
> network egress proxy. The statements above about MERGE clause semantics and IDMC's SCD2 pattern come from
> search summaries and general knowledge, **not from primary documentation read directly**. Verify before
> committing to a design.


---

## 6. Steps 2 and 3

### The locked decision table

Every rebuilt interval is matched to the existing target row on `(business_key, row_eff_dte)`. The matched
row's **current expiry** decides first; the **hash** — taken over the columns that actually reach the target —
only decides inside the high-end-date branch.

**Source of truth: `sources/Requirement.xlsx`**, confirmed with leadership. Where its wording was struck
through in the spreadsheet, the surviving bracketed text is authoritative — `upd` was a shorthand that was
struck precisely because it read as "update in place" when it means retire-and-replace.

Each row below describes what happens at **one** effective date. A run processes every effective date in the
rebuilt timeline, so one key normally triggers several of these in the same run.

| # | EFF_DATE | HASH | EXP_DATE | EXECUTION_TYPE | ACTION | Stage flag |
|---|---|---|---|---|---|---|
| 1 | matches a target row | same | same · target at 9999 | regular | do nothing | *none* |
| 2 | matches a target row | same | same · target at 9999 | rerun | update UUID | `'U'` |
| 3 | matches a target row | same | same · target at real date | regular | do nothing | *none* |
| 4 | matches a target row | same | same · target at real date | rerun | update UUID | `'U'` |
| 5 | matches a target row | same | **diff** · target at 9999 | regular | **expire in place** — update `row_exp_dte`; no retire, no `is_del`, surrogate key survives — **and insert** the new version at the new effective date **if the source supplies one** | `'U'` (+ `'I'`) |
| 6 | matches a target row | same | **diff** · target at 9999 | rerun | as 5, + update UUID | `'U'` (+ `'I'`) |
| 7 | matches a target row | same | **diff** · target at **real date** | regular | **retire** — `is_del='Y'`, both dates untouched — **+ insert** a new entry at the **same** effective date | `'D'` + `'I'` |
| 8 | matches a target row | same | **diff** · target at **real date** | rerun | as 7, + update UUID | `'D'` + `'I'` |
| 9 | matches a target row | **diff** | same · target at 9999 | regular | **dead record** — `row_exp_dte` pulled back to the row's own `row_eff_dte` — **+ insert** at the same effective date | `'D'` + `'I'` |
| 10 | matches a target row | **diff** | same · target at 9999 | rerun | as 9, + update UUID | `'D'` + `'I'` |
| 11 | matches a target row | **diff** | same · target at **real date** | regular | **retire** (`is_del='Y'`) **+ insert** at the same effective date | `'D'` + `'I'` |
| 12 | matches a target row | **diff** | same · target at **real date** | rerun | as 11, + update UUID | `'D'` + `'I'` |
| 13 | matches a target row | **diff** | **diff** · target at 9999 | regular | **dead record + insert** at the same effective date | `'D'` + `'I'` |
| 14 | matches a target row | **diff** | **diff** · target at 9999 | rerun | as 13, + update UUID | `'D'` + `'I'` |
| 15 | matches a target row | **diff** | **diff** · target at **real date** | regular | **retire** (`is_del='Y'`) **+ insert** at the same effective date | `'D'` + `'I'` |
| 16 | matches a target row | **diff** | **diff** · target at **real date** | rerun | as 15, + update UUID | `'D'` + `'I'` |
| 17 | **no target row at that effective date** | — | — | either | **insert** | `'I'` |
| 18 | **target row's effective date is gone from the rebuilt timeline** | — | — | either | **no action — the row is left live, deliberately.** See §14 | *none* |

`execution_type` changes nothing but the UUID stamp: rows 1–16 pair up identically apart from it. Two kinds
of insert are distinguished deliberately — rows 5–6 insert at a **new** effective date (which is rule 17
firing at the next boundary), rows 7–16 insert at the **same** effective date as the row being retired, which
is why a dead record and its replacement share an effective date.

**The expiry decides first; the hash only decides inside the high-end-date branch.** A row already closed with
a real date was a statement published downstream — "valid 10-Sep to 21-Sep" went out as a report. Changing it
is a **correction**, so the old row is retired and stays visible for traceability. A row sitting at the high
end date never committed to an end date; it meant "current, end unknown". Closing it is not a correction, it
is the natural progression, so it is **expired in place**.

This is why S01 and S02 handle a hash-unchanged row differently: S01's row sat at a real expiry and is
retired, S02's sat at 9999 and is expired in place. The hash is the same in both.

**Why the hash is needed at all**: two rows can be identical on both dates and still differ in value — a
source restating a row in place. Dates alone cannot tell them apart, and a date-only comparison would write
nothing, leave the stale value in the target, and report success. See scenario S06.

**Why the hash is taken only over target-bound columns**: a source column the target never carries can change
without meaning anything to a consumer. Hashing it would split the target into two identical rows. See S03.

### Two ways a retired row is retired

Once the hash says a row must go, *how* it goes depends on its expiry. The rule, confirmed by the team:

| The row being retired | How it is retired | Result |
|---|---|---|
| Its `ROW_EXP_DTE` is the **high end date** (9999-12-31) | **Dead record** — set `ROW_EXP_DTE` equal to that row's own `ROW_EFF_DTE` | The row spans zero days, so no as-of query can return it |
| Its `ROW_EXP_DTE` is a **real date** | **Delete indicator** — set `IS_DEL = 'Y'`, leave both dates alone | The row is excluded by a consumer filtering on `IS_DEL` |

A dead record is the stronger of the two, because it is invisible to an as-of query **whether or not the
consumer knows to filter on a flag**. A delete indicator only works if every consumer remembers. Whether
that argues for using dead records everywhere is open — see §13.

`IS_DEL = 'Y'` therefore fires on **any** change to a row whose expiry was already a real date, whether or not
its values moved — S01's `A1|B1` row is retired even though its hash is unchanged. The `'U'` branch is the
narrow one: it needs a row at the high end date whose values did not change.

```sql
-- STEP 2a — the row sat at the high end date and its values did not change: expire in place
UPDATE Z2_BROKER_PARTY_DIM T
SET ROW_EXP_DTE           = S.ROW_EXP_DTE,
    AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
FROM STG_Z2_BROKER_PARTY_DIM S
WHERE S.ACTION_FLAG = 'U'
  AND T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK;

-- STEP 2b — retire. A real expiry means a correction (delete indicator); the high end date means a dead record
UPDATE Z2_BROKER_PARTY_DIM T
SET IS_DEL      = CASE WHEN T.ROW_EXP_DTE = '9999-12-31'::DATE THEN T.IS_DEL ELSE 'Y' END,
    ROW_EXP_DTE = CASE WHEN T.ROW_EXP_DTE = '9999-12-31'::DATE THEN T.ROW_EFF_DTE ELSE T.ROW_EXP_DTE END,
    AUDIT_UPDATE_DATETIME = CURRENT_TIMESTAMP()
FROM STG_Z2_BROKER_PARTY_DIM S
WHERE S.ACTION_FLAG = 'D'
  AND T.BROKER_PARTY_DIM_SK = S.BROKER_PARTY_DIM_SK;

-- STEP 3 — insert
INSERT INTO Z2_BROKER_PARTY_DIM (...)
SELECT SEQ_BROKER_PARTY_DIM_SK.NEXTVAL, ...
FROM STG_Z2_BROKER_PARTY_DIM WHERE ACTION_FLAG = 'I';
```

**Both the `U` and `D` rows carry the target row's own surrogate key**, so each update matches on one column.
Matching on `(BROKER_ID, ROW_EFF_DTE, ROW_EXP_DTE)` instead would also hit a row retired in an *earlier* run
that happened to cover the same interval.

**Every action here is idempotent**, which is what makes restart safe without depending on ABC's cleanup:
re-applying a `'U'` writes the value already there, re-retiring a dead record leaves it dead, and an interval
already inserted matches on the next run with the same hash and expiry, so it falls to "nothing is written".

**The POC predates this rule** — it retired every row with `IS_DEL = 'Y'` and had no `'U'` branch at all.
BR001 and BR006 need re-running; see §9.

---

## 7. IDMC components — deferred

| Step | Component | Notes |
|---|---|---|
| 1 | Mapping: Source transformation with **custom query / SQL override** → stage table, operation **Insert** | Needs the **Create Temporary View** session property for pushdown to work with a SQL override |
| 2a | Mapping: Source = stage filtered `action_flag='U'` → Zone2 target, operation **Update** | Writes `row_exp_dte` only; only fires for a row that sat at the high end date. Informatica's docs state Create Temporary View is mandatory before configuring update, upsert or delete |
| 2b | Mapping: Source = stage filtered `action_flag='D'` → Zone2 target, operation **Update** | Writes `is_del` and/or `row_exp_dte`, per the retirement rule |
| 3 | Mapping: Source = stage filtered `action_flag='I'` → Zone2 target, operation **Insert** | Plain insert |

**This section is deferred.** The POC is being proved at Snowflake level first. It is kept because the
mapping shapes below are still the likely landing point once the SQL is settled.

Steps 2a and 2b are both updates against the same target and could be one mapping driven by a `CASE`, but
they write different columns for different reasons and keeping them apart makes a run's counts readable:
"12 expiry moves, 3 retirements, 5 inserts" says more than "20 updates".

**Possible consolidation**: Snowflake targets in IDMC support a **Data Driven** operation, where a flag
column decides insert vs. update per row, which would collapse Steps 2a, 2b and 3 into one mapping. Keep
them separate for v1 — unambiguous and easier to debug — and test Data Driven afterwards.

---

## 8. Restart behaviour

**A single MERGE is atomic**, so the half-applied target the old design worried about cannot occur: the
statement either commits in full or rolls back in full. A failure while building the stage leaves the target
untouched, and the stage is truncate-and-reload anyway.

The restart case that *does* survive is different: **the MERGE commits, then the run fails before ABC records
success.** ABC restarts the job, and the same MERGE is re-applied against an already-correct target. That is
safe only if the apply is idempotent — and it is, *provided the target read excludes dead records*.

After a complete apply, effective date 21-Sep holds two rows that both carry `is_del = 'N'`:

| NK1 | NK2 | eff | exp | is_del | |
|---|---|---|---|---|---|
| A2 | B1 | 21-Sep | 21-Sep | N | the dead record — zero length, but the flag stays `'N'` |
| A2 | B2 | 21-Sep | 22-Sep | N | its replacement |

Reading the target on `is_del = 'N'` alone returns both, so the match on `(business_key, row_eff_dte)` is
ambiguous and the diff cannot run. Adding `row_eff_dte < row_exp_dte` to the read (§4 stage 7) excludes the
dead record, every interval then matches one row, and the restart writes **zero rows**.

**This makes the target-read filter a correctness requirement rather than a refinement.** It is the one thing
restart safety now rests on.


---

## 9. The POC

`poc_v2/` runs against `LM_POC_DB.POC_SCHEMA`. Run `00_objects.sql` **once**, then each scenario file top
to bottom. Every `EVIDENCE` block returns a result set to capture; every test case ends in a single
`PASS`/`FAIL` row.

| | |
|---|---|
| `00_objects.sql` | every object, the Step 1 diff view, and the Step 2 MERGE. The MERGE at its foot is a no-op there — `CREATE OR REPLACE` leaves the stage empty — so running the file also syntax-checks the statement without touching data |
| `scenarios/S01.sql` … `S15.sql` | one file per scenario, test cases chained as successive ETL runs |
| `evidence/` | the workbook: tab 1 the rules, tab 2 the test-case grid, tab 3 on for screenshots |

**The target is never hand-seeded.** TC01 of each scenario loads an empty target through the real pipeline
and every later test case is the next run against whatever the previous one left. There is one reset, at the
top of each file. That is the only way to test the property that matters most here — that rows an incremental
run should not touch stay untouched — and every test case from TC02 on asserts it explicitly, keyed on
`AUDIT_BATCH_ID`.

**Status: 69 test cases, 69 passing** in the DuckDB harness (`tools/run_scenario_duckdb.py`), which executes
the `.sql` files statement by statement so what runs is what is on disk. Snowflake has confirmed the parts
DuckDB cannot: the multi-clause MERGE is valid, `ERROR_ON_NONDETERMINISTIC_MERGE` stays quiet,
`SEQ_BROKER_PARTY_DIM_SK.NEXTVAL` works inside the view alongside `QUALIFY`, and `SHA2`, `UUID_STRING()` and
`count_if` all behave.

### A defect the rerun scenario exposed

Writing S12 found a real bug in Step 1. The classifier added 1 to **every** rule on a `Z1_RERUN`, including
rule 17. A brand-new interval arriving during a rerun therefore classified as **18** — which means something
else entirely, *"this target row is gone from the timeline, do nothing"* — and the `'I'` branch does not
select it:

```
before:  stage = [rule 6 'U']                 ->  cover ends at the split date
after:   stage = [rule 6 'U', rule 17 'I']    ->  cover reaches the high end date
```

**The insert was silently dropped and the target lost all cover from that date onward.** The `+1` now applies
only to the matched rules, 1–16. `S12 TC03` is the regression guard and asserts `RULE_NO = 18` never appears
in a stage.

### Objects — what is real and what is illustrative

Taken from `../w2-abc-framework/reference.md`, names and columns as documented:

| Object | Note |
|---|---|
| `ETL_DATA_INGESTION_SOURCE_WINDOW` | The real per-source-table sourcing window, with its documented column list. **Per source table**, not one global watermark — each source carries its own start and end time and its own `JOB_STATUS` |
| `GRS_UNIQUE_ID` | Zone1 record-identifier audit column |
| `AUDIT_BATCH_ID` / `AUDIT_JOB_ID` | Snowflake stage and target audit columns. The documented quirk is honoured: they hold `EXECUTION_RUN_ID` and `JOB_RUN_ID`, **not** the metadata batch/job ids |
| `AUDIT_CREATE_DATETIME` / `AUDIT_UPDATE_DATETIME` | Standard audit column names |
| Stage behaviour | Truncate-and-reload every run, never upsert |

Illustrative — shaped to the documented naming conventions, but the real object names are not in anything we
hold, so **substitute before real use**: `Z1_BROKER_PARTY_HIST`, `Z1_BROKER_COMMISSION_HIST`,
`Z2_BROKER_PARTY_DIM`, `STG_Z2_BROKER_PARTY_DIM`, and `GRS_REFINED_TIMESTAMP` (the ABC doc describes "an
audit column present on every Zone1 target table marking when that row was last refined" but never spells
the column name).

### Test data

Two Zone1 history-bucket tables, both SCD2, both contributing attributes to one Zone2 SCD2 dimension,
joined on `BROKER_ID`.

| Broker | Purpose | Runs |
|---|---|---|
| **BR001** | The main scenario. The party table never changes on Day 2, yet three of its target rows get rewritten | 101, 102 |
| **BR002** | Day 2 changes a column that never reaches the target. Must produce **no** target change at all | 101, 102 |
| **BR003** | Never touched after Day 1. Must not be re-read or re-written | 101 |
| **BR004** | The same value returns later with a different one in between (`ACTIVE → SUSPEND → ACTIVE`). The two `ACTIVE` runs must stay separate | 104 |
| **BR005** | A gap in cover with the same value either side. The gap must survive the collapse | 104 |
| **BR006** | A value corrected without either of its dates moving. The target row must still be replaced | 104, 105 |
| **BR007** | The same version arrives twice inside one window. Only the later copy may be used | 104 |

BR004–BR007 were added after the first run, one per trap in §4. Each is built so that a *plausible but
wrong* implementation fails on it **silently** — producing a wrong target and reporting success — rather
than raising an error.

### Verified results — Day 1 and Day 2

Each table below was written down as a prediction before the run, and is what the run produced.

**After Day 1** — 5 target rows, all `IS_DEL = 'N'`:

| BROKER_ID | ROW_EFF_DTE | ROW_EXP_DTE | BROKER_STATUS_CDE | COMMISSION_TIER_CDE |
|---|---|---|---|---|
| BR001 | 2026-09-09 | 2026-09-10 | *(null)* | TIER1 |
| BR001 | 2026-09-10 | 2026-09-21 | ACTIVE | TIER1 |
| BR001 | 2026-09-21 | 9999-12-31 | SUSPEND | TIER1 |
| BR002 | 2026-09-05 | 9999-12-31 | ACTIVE | TIER1 |
| BR003 | 2026-09-01 | 9999-12-31 | ACTIVE | TIER1 |

**Day 2 stage** — exactly 4 `I` and 2 `D`, all BR001, the `D` rows carrying surrogate keys 3 and 4. Nothing
for BR002 or BR003. Step 2 also reported `0 multi-joined rows updated`, independently confirming the
surrogate-key match is unambiguous.

**After Day 2** — BR001 has 5 live rows and 2 superseded:

| BROKER_ID | ROW_EFF_DTE | ROW_EXP_DTE | BROKER_STATUS_CDE | COMMISSION_TIER_CDE | IS_DEL |
|---|---|---|---|---|---|
| BR001 | 2026-09-09 | 2026-09-10 | *(null)* | TIER1 | N |
| BR001 | 2026-09-10 | 2026-09-15 | ACTIVE | TIER1 | N |
| BR001 | 2026-09-10 | 2026-09-21 | ACTIVE | TIER1 | **Y** |
| BR001 | 2026-09-15 | 2026-09-21 | ACTIVE | TIER2 | N |
| BR001 | 2026-09-21 | 2026-09-22 | SUSPEND | TIER2 | N |
| BR001 | 2026-09-21 | 9999-12-31 | SUSPEND | TIER1 | **Y** |
| BR001 | 2026-09-22 | 9999-12-31 | SUSPEND | TIER3 | N |

### Verified results — the four harder cases

**Run 104 stage** — 8 rows, all `I`, in the shape that separates a correct collapse from a fan-out:

| Broker | Rows | What a different count would have meant |
|---|---|---|
| BR004 | 3 | 4 → the two `ACTIVE` runs merged into one overlapping version, fanning the middle interval out |
| BR005 | 3 | 1 → the gap was collapsed away and both its boundary dates lost |
| BR006 | 1 | — |
| BR007 | 1 | 2 → the duplicate survived de-duplication and fanned out |

BR005's middle row came through carrying **no** `BROKER_STATUS_CDE`, spanning 2026-04-10 to 2026-04-20 —
the period neither source covers. That is the intended behaviour, not a defect.

**Run 105 stage** — exactly one `D` and one `I`, both BR006, both on the *same* `ROW_EFF_DTE` and
`ROW_EXP_DTE` (2026-05-01 → 9999-12-31), differing only in value. This is the case `ROW_HASH` exists for: a
diff joining on dates alone returns an **empty stage** here, leaves the stale `ACTIVE` value in the target
permanently, and reports success.

**After run 105** — BR006 holds both rows on identical dates: the live `SUSPEND` one under
`AUDIT_BATCH_ID` 105, and the retired `ACTIVE` one under 104. The correction is recorded, not overwritten.

### The twenty-six assertions

**T01–T12 — Day 1 and Day 2**

| | Checks |
|---|---|
| T01 / T02 | BR001 has 5 live and 2 superseded rows |
| T03 / T04 | BR002 unchanged and never soft-deleted — **the collapse worked** |
| T05 | BR003 untouched — it never entered the run's sourcing window |
| T06 | BR001's live timeline has no gaps or overlaps |
| T07 | `BROKER_ID` + `ROW_EFF_DTE` is unique **among live rows** |
| T08 | …and deliberately **not** unique across all rows — 2 duplicate pairs |
| T09 / T10 | The 09-Sep row exists and carries no `BROKER_STATUS_CDE` |
| T11 | The Day 2 rows carry `AUDIT_BATCH_ID = 102`, so a run is traceable in the target |
| T12 | A third run with no newly refined rows produces an **empty stage** — idempotence |

T07 and T08 together are the important pair: they pin down the consequence that every consumer query and
every future merge has to filter on `is_del`.

**T13–T26 — the four harder cases**

| | Checks |
|---|---|
| T13 / T14 | BR004 has 3 live rows, 2 of them separate live `ACTIVE` rows — **the repeat was not merged** |
| T15 | BR004's live timeline has no gaps or overlaps |
| T16 | BR005 has 3 live rows — **the gap survived the collapse** |
| T17 | BR005's 10-Apr to 20-Apr row carries no `BROKER_STATUS_CDE` |
| T18 | BR005 has 2 separate live `ACTIVE` rows — not merged across the gap |
| T19 / T20 / T21 | BR006's correction retired exactly 1 row, left exactly 1 live, and that row carries `SUSPEND` |
| T22 | BR006's retired and live rows share the same dates — **the in-place correction was caught** |
| T23 / T24 | BR007 has 1 live row carrying `SUSPEND` — **the duplicate did not fan out, and the later copy won** |
| T25 | No duplicate `BROKER_ID` + `ROW_EFF_DTE` among live rows, with all seven brokers loaded |
| T26 | Idempotence again at the larger scale — empty stage with 7 brokers and 15 live rows in the target |

### Why these assertions are not vacuous

Before the Snowflake run, the whole script was executed in DuckDB — which supports the same `QUALIFY`,
`IS DISTINCT FROM` and windowing this logic relies on — and three wrong implementations were injected in
turn, to check the assertions actually fail when the logic is wrong rather than passing by coincidence:

| Injected fault | Caught by |
|---|---|
| Collapse groups by value rather than by consecutive run | T13–T18, T25 |
| Diff joins on dates only, `ROW_HASH` omitted | T19, T21, T22 |
| Per-`(key, eff date)` de-duplication removed | T23, T25 |

**None of T01–T12 caught any of them** — the original suite passed cleanly on all three broken versions.
That is precisely why BR004–BR007 exist.

DuckDB checks the *logic*, not Snowflake syntax or pushdown behaviour — hence §12, which is unchanged by
any of this.

---

## 10. From POC to the real system

The POC creates seven objects. They are not all the same kind of thing, and the difference matters when
this is built for real: one already exists, three are placeholders, two are genuinely new, and one is the
logic itself.

| POC object | What it actually is | What happens to it |
|---|---|---|
| `ETL_DATA_INGESTION_SOURCE_WINDOW` | The **real** ABC control table. The POC recreates it only because `POC_SCHEMA` holds no copy | **Already exists** — drop the `CREATE` from the script. Read-only input, written by the framework at job preload |
| `Z1_BROKER_PARTY_HIST` | Placeholder source 1 | **Replace** with the real Zone1 table |
| `Z1_BROKER_COMMISSION_HIST` | Placeholder source 2 | **Replace** with the real Zone1 table |
| `Z2_BROKER_PARTY_DIM` | Placeholder target | **Replace** with the real Zone2 dimension, which already exists |
| `STG_Z2_BROKER_PARTY_DIM` | The stage | **New** — one per target |
| `SEQ_BROKER_PARTY_DIM_SK` | Surrogate-key source | **New, or not needed** — see below |
| `V_STEP1_..._DIFF` | Step 1's logic | **New** — one per target |

Steps 2 and 3 are DML, not objects. They become IDMC mappings (§7).

### The view is the brain, but not the whole design

Step 1 **writes nothing**. It reads four inputs and returns a list of instructions. Two further operations
apply them. A common misreading is that the view is the whole solution and everything else is a parameter;
it is neither the whole solution nor is the rest parameterised.

Two details are easy to miss:

- **Step 1 reads the Zone2 target.** Stage 7 pulls the rows already there for the impacted keys. So this is
  not a one-way Zone1 → Zone2 flow: one query touches both zones plus the control table. If the zones sit in
  different databases, that has consequences for qualification and for connection privileges.
- **The view is hand-written per target, not parameter-driven.** It hardcodes the two source table names,
  the join key, the two carried columns, and the *number* of sources. Swapping a table name is a rewrite of
  the CTEs, not a parameter substitution. Making it genuinely generic is the metadata-template question in
  §12, and is a much larger build.

### The stage table — the one piece with no equivalent today

The stage is the handoff between deciding and doing. Every row carries `ACTION_FLAG`:

| Flag | Meaning | `BROKER_PARTY_DIM_SK` |
|---|---|---|
| `I` | A version that should exist in the target but does not | Null — Step 3 assigns one |
| `D` | A version in the target that is no longer valid | **The existing key**, which is how Step 2 finds the row to retire |

It is truncated and reloaded every run, never appended — which is what makes the load restartable. There is
no accumulated state to unwind, and a re-run recomputes against whatever the target holds at that moment
(§8). Its columns mirror the target's carried columns plus `ACTION_FLAG`, the surrogate key, `ROW_HASH`
and the audit columns.

### Changes required before this runs for real

In priority order. **The first two fail silently** — the job reports success having done nothing, or the
wrong thing.

**A. The control-table read is POC-grade and will break.** `cur_run` takes `MAX(EXECUTION_RUN_ID)` across
the whole table, and neither it nor `win` filters on `TARGET_TABLE_NAME`. With one target that is harmless.
In the real system that table holds rows for **every** target, so `MAX()` picks up whichever job ran most
recently anywhere — possibly another team's — and `win` then returns source windows belonging to a
different target. Both CTEs need a `TARGET_TABLE_NAME` filter, and the run id should come from the
framework's run context rather than `MAX()`.

**B. The `SOURCE_TABLE_NAME` literals must match what the framework actually writes.** The `win` CTE joins
on string literals. If the framework writes fully-qualified names, or a different case, the join returns
nothing → `impacted_keys` is empty → the stage is empty → the job succeeds having done nothing. Read one
real row of that table before trusting it.

**C. `GRS_REFINED_TIMESTAMP` is confirmed.** Previously flagged as a name this design invented because the ABC reference describes the column without naming it. The team confirms this is the column they already use to fetch the latest SCD2 records from source, so the POC and the real pipeline agree.

**D. Cross-database qualification.** If Zone1 and Zone2 are in different databases or schemas, every
reference needs full `DB.SCHEMA.TABLE` qualification and the connection needs read on both. This also
interacts with pushdown: a documented Informatica failure puts the temporary view in the wrong schema when
a mapping reads across schemas (§12).

**E. The surrogate key.** If the real Zone2 dimension already generates keys — an identity column, its own
sequence, a hash key — delete `SEQ_BROKER_PARTY_DIM_SK` and the `NEXTVAL` from Step 3 and use whatever
exists. Only create a sequence if the target has no generator.

**F. Stage location and naming** should follow the ABC convention rather than the POC's, and the stage needs
whatever audit columns the framework expects.

### One decision to take before building

The Step 1 SQL can live two ways:

| | How | Trade-off |
|---|---|---|
| **A permanent Snowflake view** | Deploy the view; IDMC selects from it | `CREATE VIEW` needed once at deploy time, under change control. Version-controlled in Snowflake |
| **A SQL override in the Source transformation** | Paste the query into IDMC | Informatica implements this by creating a *temporary view at runtime* anyway, so the same privilege is needed — but granted permanently to the runtime role |

Since both need `CREATE VIEW`, the permanent view is the better default: the same privilege, exercised at
deploy time under change control rather than on every run. This is drawn from vendor documentation read
second-hand and is one of the things the §12 spike should settle.

---

## 11. Confirmed limitation — mixed clocks

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

## 12. To verify before build

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

## 13. Still open on the problem side

### From the scenario walkthrough

The live scenario catalogue is `poc_v2/TEST_PLAN.md` and tab 2 of the evidence workbook, both generated
from `tools/scenario_specs.py` **plus a real run** by `tools/refresh_docs.py`, so neither can drift from the
SQL. `sources/Final_Scenarios_v2.xlsx` is the earlier hand-built catalogue, kept for provenance only.

These questions came out of the review and are the ones that would change what gets built:

| | Question | Why it matters |
|---|---|---|
| 1 | When several source rows share a key **and** effective date in one window, are they restatements where the latest wins, or distinct versions that must all land? | The only one that changes the design rather than the documentation. If all must land, two live rows would share a key and effective date and the timeline becomes ambiguous |
| 2 | Is `ROW_EFF_DTE` a **date** or a **timestamp**? | If intraday runs carry different times, question 1 resolves itself — the rows never collide |
| ~~3~~ | **CLOSED** — `execution_type` does not override the rule. `Requirement.xlsx` gives the same action for regular and rerun in every cell, differing only by the UUID stamp. ~~On a Zone 1 rerun, does `execution_type` override the retirement rule?~~ The colleague's sheet says *"if execution type = Z1 rerun then update all, else mark the existing record as Dead Record"*. Neither transcript mentions rerun at all. | **REOPENED.** Option 1 (ignore `execution_type`, §6 applies unchanged) keeps the audit trail; Option 2 ("update all") suppresses it on the grounds that a rerun's previous output was a processing artefact, not a published statement. Settled as option 1: `execution_type` only restamps the UUID, and S12 tests all eight rerun rules |
| 4 | Is `IS_DEL` also set on a dead record, or left at `'N'`? | Decides how consumers and the framework's restart cleanup identify live rows |
| 5 | Should Step 1 read a zero-length row as live at all? | Filtering `ROW_EFF_DTE < ROW_EXP_DTE` in the target read would exclude dead records however `IS_DEL` is set, and would settle question 4 |
| 6 | Are both sources always keyed the same way? | If one is a parent that several keys point at, a parent-only change must fan out to every child before the rebuild — and the current Step 1 would find nothing, producing an empty stage and a job that reports success |
| 7 | Can more than two SCD2 sources feed one target? | Same arithmetic, but the SQL is written for exactly two |
| 8 | Does the target read filter `row_eff_dte < row_exp_dte`? §4 and §8 require it | Without it a re-run sees two live rows at one effective date and cannot match. Stated as a requirement; still to be confirmed with the team |
| ~~9~~ | ~~Can a source remove one of its own versions, leaving a stale Zone2 row?~~ **CLOSED** — yes, and the row is left live deliberately. See §14 | |
| ~~10~~ | ~~What happens when the hash definition changes?~~ **CLOSED** — gradual re-derivation, no truncate. See §15 | |
| ~~11~~ | ~~Can an SCD1 source feed this?~~ **CLOSED** — the Zone1 history bucket is never SCD1, so the combination cannot arise | |
| 9 | What is `UUID` on the target row — an id we generate per target row and restamp each run, or a source `UNIQUE_ID` carried through? | If it is carried through, which source supplies it? A target row is built from both, and an interval covered by only one source has no value from the other |

**Restart is settled, on one condition.** See §8: a single MERGE is atomic, so the half-applied target cannot
occur, and the surviving case (MERGE committed, run marked failed) is a clean no-op **provided the target read
excludes dead records**. Tracing it row by row shows the
design recovers on its own, and shows why: the restart keeps the same sourcing window, so Step 1 rebuilds
the same timeline, and the diff runs against whatever the target holds at that moment. Every action in §6 is idempotent, so re-applying writes nothing. The framework's own cleanup cannot find our retired rows — they carry
the id of the run that *inserted* them — but that turns out not to matter, because we never depend on it.
Worth stating explicitly, because the moment Step 1 is "optimised" to trust the target instead of
rebuilding, this stops being true.

### Carried over from the earlier scenario catalogue

These do not block the POC but do affect scope:

- Does a current-bucket read give one row per key, or all versions?
- Can a source *remove* one of its own versions? If so, nothing in the delta will ever flag it.
- Is "current value only + current value only → SCD2 target" already a solved pattern?
- Are SCD1 and SCD2 the only target types?
- Does a join returning many rows per key per date need handling here, or is it a separate track?

---

## 14. Stale Zone2 rows, and how to read the target

**Decision: a Zone2 row whose effective date no longer appears in the rebuilt timeline is left live and
untouched.** It is not retired, not flagged, not removed. Rule 18.

This happens when Zone1 does a full rerun or loses its checkpoint and re-sources only the latest version, so
history Zone2 already holds disappears from the source. The architects want that row retained: it was
published and reporting has used it.

It costs nothing in Step 1. Our diff matches on `(business_key, row_eff_dte)`, and the orphan sits at an
effective date the rebuilt timeline no longer contains — so no rule matches it and no instruction is emitted.
One row per match, no ambiguity.

**It is also self-healing.** When Zone1 recovers and re-supplies the missing version, the rebuilt timeline
regains that boundary, the orphan matches again, its hash and expiry compare equal, and it falls to rule 1 —
untouched. The row that was orphaned turns out to be the row that makes recovery free. Retiring it would have
forced a re-insert with a new surrogate key.

### The one cost, and the trap in it

While Zone1 is degraded the target can hold **two live rows covering the same date** — the orphan and the
rebuilt row. Consumers must therefore be told how to choose.

**Read by effective date: take the row with the greatest `row_eff_dte` that is on or before the as-of date.**
That is the ordinary way to read an SCD2 dimension and it returns the orphan, which is the historically
correct value — the one Zone1 lost.

**Do not read by load order.** Picking the most recently written row — by `audit_create_datetime`,
`audit_batch_id` or the highest surrogate key — selects the row derived from Zone1 *after* it lost history and
discards exactly the row this decision exists to preserve. This must be stated to whoever builds reports; it
is the obvious choice and it is the wrong one.

---

## 15. Changing the hash definition

When a column is added to the Zone2 target the hash is computed over a different column set, so every
existing row's stored hash was built on the old definition.

**Decision: no truncate and reload.** Zone1 may itself have lost history, so reloading from it can lose
versions Zone2 has been reporting on. Truncating destroys everything published to date.

**Decision: let it happen gradually.** No special migration job. Keys are re-derived whenever they next
become impacted, and each daily run stays small.

**Decision: when a key is re-derived, the ordinary rules apply** — rules 9–16. A row at the high end date
becomes a dead record; a back-dated row gets `is_del = 'Y'`. Both keep their original surrogate keys and
remain in the table. The new versions are inserted alongside. Nothing is lost.

### What this costs, stated plainly

- The target carries a **mix of old-definition and new-definition hashes indefinitely**.
- A key that never changes again **keeps the new column empty forever**. A report on that column will show
  blanks for quiet keys, and the reason will not be obvious from the data.
- Every key that is re-derived has its whole history soft-deleted and re-inserted, so **surrogate keys churn**
  for that key. Anything downstream joining on the surrogate key sees new values.

This was chosen over a single deliberate pass across all keys, which would have made the table uniform at the
cost of one large run. If the empty-column effect later becomes a problem, a backfill can be run at that
point — the decision is reversible.

---

---

## 16. Test strategy for POC v2

**Everything proved in POC v1 is treated as unproven.** The rule changed after v1 ran, so its evidence
describes behaviour the design no longer specifies. POC v2 re-establishes coverage from nothing.

### Rule coverage is counted, not assumed

The earlier catalogue exercised **11 of 18** rules. POC v2 reaches **all 18**, and the coverage is
**measured from a real run** by `tools/refresh_docs.py` rather than asserted by hand.

Fifteen rules emit a stage row and are directly observable. **Rules 1, 3 and 18 emit nothing at all** — they
are the do-nothing rules — so they are proved by **zero writes** in the idempotent cases, not by a visible
row. Saying they are "covered" the same way as the others would be false.

| Rule | Where | |
|---|---|---|
| 1, 3 | every idempotent case | 0 stage rows, 0 written |
| 2, 4, 6, 8, 10, 12, 14, 16 | S12, one per test case | all eight rerun variants |
| 5 | S01, S02, S03, S04, S05, S07, S08, S13, S15 | expire in place — the only rule where the surrogate key survives |
| 7, 13 | S01 | |
| 9 | S01, S06, S14, S15 | |
| 11 | S01, S10, S14 | back-dated correction, previously untested |
| 15 | S10 | hash **and** expiry move on a closed row |
| 17 | all fifteen scenarios | |
| 18 | S11 | the orphan stays live and untouched, 0 stage rows |

### Fifteen scenarios, chosen to close every gap

| | Scenario | Rules it must exercise |
|---|---|---|
| S01 | One source changes, the other does not | 1, 3, 7, 13, 17 |
| S02 | Both sources change in the same run | 5, 17 |
| S03 | Change in a column the target never carries | 1 |
| S04 | A value comes back after a different one | 17 |
| S05 | A gap in cover, same value either side | 17 |
| S06 | A value corrected with no change to its dates | 9, 17 |
| S07 | Several runs in one day, same key and eff date | 5, 17 |
| S08 | A key no source touched this run | 1, 3, 7, 13, 17 |
| S09 | A key appearing for the first time | 17 |
| **S10** | **Back-dated correction** | **11, 15** |
| **S11** | **Stale / orphan row** | **18** |
| **S12** | **execution_type = Z1 RERUN** | **2, 4, 6, 8, 10, 12, 14, 16** |
| **S13** | **execution_type = RESTART** | MERGE atomicity, idempotence |
| **S14** | **Hash-definition change** | §15, gradual re-derivation |
| **S15** | **Volume and differential** | all rules, on random data |

All 18 rules are covered. S12 carries every rerun variant, so it needs one test case per rule.

### Test case types

| Code | Proves |
|---|---|
| **P** positive | the canonical case produces the expected target |
| **I** idempotent | re-running the same input writes **zero** rows |
| **N** negative | input that must produce no change at all |
| **E** edge | zero-length rows, same eff and exp, high-end-date boundaries |
| **C** corrupt | NULL key, duplicate (key, eff date), timestamp outside the window |
| **V** volume | many keys of different shapes at once, checked against structural invariants |

**S15 is the one that finds what hand-written cases miss**, but not the way it was first planned. Comparing
against a second Python implementation was dropped — a second implementation is a second thing to get wrong,
and it cannot run in Snowflake where the evidence is captured. S15 asserts **invariants** instead, which hold
whatever the rules did:

- no two **live** rows for one key may overlap
- a corrupt source row must never reach the target
- a duplicate `(key, effective date)` must never produce two live rows

A hand-written case proves the rule you were thinking about. An invariant proves the rules you were not.

### Structure

One SQL script per scenario. **One reset, at the top of the file** — test cases do not reset, because each
is the next run against what the previous one left. They must therefore run in order, top to bottom; each is
still a section you can execute and screenshot on its own, and scenarios stay independent of each other.

Test cases are labelled with the run they represent: `TC02 (D1R2)` is test case 2, day 1 run 2. Three runs a
day, 08:00 / 12:00 / 16:00.

Source changes are written the way Zone1 writes them — `UPDATE` the previous version's `ROW_EXP_DTE` and
`INSERT` the new one, both carrying a fresh `GRS_REFINED_TIMESTAMP` — not as a reseed.

The surrogate-key sequence is **never restarted**: production does not reuse a key, so neither does the POC.
That holds only because no assertion references a generated key, which is verified rather than assumed.
Snowflake's sequence is not gapless — it allocated 301–304 and then 401 — so this is a demonstrated
requirement, not a precaution.

```
poc_v2/
  00_objects.sql      tables, sequence, the Step 1 diff view, the live view. Run once
  S01.sql ... S15.sql one per scenario; TC sections within
  TEST_PLAN.md        the full scenario x test case grid
  evidence/           POC_v2_Evidence.xlsx, one tab per scenario
```

Step 1 lives in the objects script as a **view**, since stored procedures are not allowed. Each test case
then reads: `TRUNCATE` stage → `INSERT INTO stage SELECT FROM view` → `MERGE` → verify.
