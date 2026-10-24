# Repository index

Working repository for GRS Zone1→Zone2 (Teradata → Iceberg → Snowflake, orchestrated by IDMC) analysis and
design work. It holds **several unrelated workstreams**, one folder each.

**Read this first, then work inside one folder.**

```
├── w1-aurora-db-connection/      Dev Aurora connection saturation      — open
├── w2-abc-framework/             ABC framework reference               — background
├── w3-scd-effective-date-split/  Multi-source SCD2 date split          — ACTIVE
├── history_load_chunking_design/ Iceberg → native history-load chunks  — ACTIVE
├── w4-generic-etl-framework/     Generic config-driven ETL framework   — ACTIVE
├── w5-zone3-consumption-gating/  Zone 3 consumption publication gating — ACTIVE
└── datacamp project/             DataCamp DS practical exam            — ACTIVE
```

Each workstream folder keeps its raw inputs — transcripts, screenshots, email exports — in its own
`sources/` subfolder, separate from the analysis derived from them.

---

## W1 — Dev Aurora DB connection issue

Connection saturation on the Dev Aurora PostgreSQL instance
(`grsdiai-hydration-aurora-postgress-db-development-i2`) blocking TD/MVP unit testing and SIT.

**Status**: open — awaiting the connection breakdown and the Informatica pool settings review.

| File | What it is |
|------|-----------|
| `connection_analysis.md` | Source-by-source record of the email thread and the Informatica↔Aurora discussion |
| `rootcause_and_longterm_fix.md` | Full technical analysis — failure-mode space, remediation ordered by speed, long-term fix |
| `team_action_plan.md` | The action plan written for the whole thread (DBA/AWS, Informatica, ingestion teams) |
| `sources/Re URGENT Alignment Required  Dev Aurora DB Connection Issue.msg` | Raw email thread |

**Not relevant to W3.** Aurora here is the ABC control/metadata database, not a data-pipeline target.

---

## W2 — ABC framework reference

`reference.md` — complete reference for the Audit Balancing Control framework: the metadata-driven
orchestration layer every Zone1→Zone2 job integrates with. Organised as a **sequential chain** —
it follows one batch run from the scheduler trigger through to batch post load, with a setup
prologue covering everything that must exist before a run can start.

`KT_transcript/` — the 16 source `.vtt` recordings the reference is built from (Jun 2026 architecture
session, May 2026 metadata sessions, the Zone2 design session, ABC KT 1–7, the Balance Reconciliation
KT, the runtime-mock-entries session, the Sept 2026 "new changes" session, and the two Sept 2026
framework walkthroughs). All read in full.

**Cross-cutting.** Background for both W1 and W3; not itself an issue to be solved.

Sections W3 leans on:
- §2–3 — Aurora vs. Snowflake split, and why the framework depends on **full push-down optimization (PDO)**
- §4–6 — naming conventions, metadata tables, IDMC connection and folder conventions, parameter file
- **§9 Phase 4 (Job load)** — the existing two-step shape: one source-qualifier query (full PDO) → stage,
  then a SQL `MERGE` stage → target. The shape any W3 solution has to fit inside
- **§9 Phase 3, step 3.2** — `etl_data_ingestion_source_window`, the per-source-table sourcing window
  the W3 POC uses
- §4 (S1.4–S1.5) and §9 Phase 4.2 — DQ rule handling
- §15 — the September 2026 changes (`batch_sourcing_stats` split, reversed RA behaviour)

Referenced but **not in this repo**: the LLD, the Lucid flow, the ABC data model, `abc_framework_deck.html`,
the design workbook `ABC_load_across_phases_scenrios.xlsx`, and the metadata/runtime-entry Excel
workbooks. Treat citations to these as external.

---

## W3 — SCD multi-source effective-date split *(active)*

**Problem**: when two or more SCD Type-2 source tables are joined to load a single SCD Type-2 target,
neither source alone can determine the target's `row_eff_dte` / `row_exp_dte`. The target timeline has to be
derived from the union of both sources' version boundaries, and rows already loaded have to be reconciled
when a later run splits an interval that was already written.

Distinct from the established pattern — one driving table, LEFT JOINed to others purely for attribute
enrichment — where the driving table alone sets the target dates.

| Path | What it is |
|------|-----------|
| `README.md` | **Start here** — index for this workstream, what lives where, and how to run the tools |
| `context-pack/` | **Self-contained pack for moving this workstream elsewhere**, including for an AI assistant with none of the history. Orientation and status board, the distilled design and 18-rule table, the Day 2+ incremental specification (the only document resting on unconfirmed assumptions — listed in its §0), the consolidated defect catalogue across four generated assets, executed worked examples, and a transfer manifest saying what to copy and what to leave behind |
| `solution_design.md` | The design of record: architecture, the locked 18-rule table (§6), the two retirement mechanisms, the test strategy and result (§16), the defect the POC found (§17), and the DataAssist integration and its reviews (§20–§26) |
| `poc_v2/` | **The POC.** `00_objects.sql` holds every object, the Step 1 diff view and the Step 2 MERGE; `scenarios/S01.sql … S15.sql` are one file per scenario; `TEST_PLAN.md` is the 15-scenario × 69-test-case grid; `evidence/POC_Evidence.xlsx` carries 346 captioned screenshots |
| `dataassist/` | **Integration with the client's code generator.** `historical_load_instructions.md` is the input we feed it; `generation_rules.md` is the generation discipline learned from its first output; `review_hr_tables.md` and `review_office_department_fix.md` are the reviews of what came back |
| `review/` | The independent test lead review and our response — every finding re-executed before being accepted |
| `sources/` | Raw inputs under their original filenames: meeting transcripts, `Requirement.xlsx`, the scenario workbooks, and the `.docx` files of generated SQL |
| `tools/` | Generators and checks, all runnable from the workstream folder. `tools/verify/` holds one script per review, reproducing every executed claim in it |
| `glossary.md` | Zone / bucket / source-system vocabulary the ABC reference leaves undefined. Every entry marked Confirmed / Inferred / Unknown |
| `scd_date_split_design_deck.html` | **The design walkthrough deck** — 7 slides, self-contained, no build step. Open in a browser; `Ctrl`/`Cmd`+`P` prints one slide per page |

**Screenshot scope**: only the `Tbl1` / `Tbl2` blocks and the Day1/Day2 target blocks are in scope. The
`Tbl3` block, the top-right `b1`/`t1` rows, and the bottom `Zone1` notes are unrelated scratch.

### Current stage

**The POC is proven: 69 test cases across 15 scenarios, 69 passing**, executed against Snowflake and
evidenced by 346 captioned screenshots in `poc_v2/evidence/POC_Evidence.xlsx`. Every screenshot was checked
against the expected result field by field, with per-test-case verdicts in `poc_v2/evidence/verdicts.json`
and in the Result column of `poc_v2/TEST_PLAN.md`.

Coverage is **measured, not claimed**: 15 of the 18 rules emit a stage row and were observed directly in the
evidence; rules 1, 3 and 18 emit nothing at all, so they are proved by zero writes rather than by a visible
row. The cases most likely to fail silently are all covered and confirmed — a value returning after a
different one in between, a gap in cover with the same value either side, a value corrected without its
dates moving, the same version arriving twice in one window, a back-dated correction, an orphaned row, and a
hash-definition change mid-pipeline.

The POC also **found a real defect** in the rule set: on a Zone1 rerun a genuinely new interval was
misclassified and its insert silently dropped, losing all target cover from that date onward. Fixed, with
S12 TC03 as the regression guard (`solution_design.md` §17).

A **leadership-verified worked example** arrived on 2026-10-13, adding two target columns. Days 1 to 3 of it
were replayed through the POC and reproduce **row for row** — insert, expire-in-place and soft delete all
match. Day 4 is unreconciled and being re-checked, and the target needs a new `current_record_ind` column.
Detail in `solution_design.md` §19.

**Integration has started, historical load first.** `dataassist/historical_load_instructions.md` is the input to the client's
DataAssist generator for the Day 1 load. `ACCOUNT_PARTY_REFERENCE` is the first target confirmed to need the split — two SCD-2
sources, and only **one of its 23 mapped columns** reveals it (`solution_design.md` §22). Writing the instruction file's runtime
assertions turned up the sharpest reason the classifier matters: a split table generated with the non-split template **passes
every obvious check**, because the staging de-duplication hides the join fanout before staging is written. One containment check
catches it, and nothing else does (§23).

**The first generated output is in and reviewed (§24).** The split itself came out right and generalised unaided from the
two-source proof to **eight contributing sources**. Of nine findings raised, eight hold and one was withdrawn once the DDL
proved DataAssist right. Six of the eight are one behaviour — **plausible SQL emitted where generation should have stopped**:
a misspelled `coalasce` silently dropped on 12 columns, a condition dropped on 3, and a join on a column that does not exist
silently rerouted. Two more were confirmed by execution: four of seven self-checks keyed on a hardcoded constant, and a `MERGE`
keyed on another SCD-2 table's per-version surrogate, which duplicates rows when that table is renumbered.

**This settles the design question, not delivery.** IDMC is deferred, the objects still have to fold into the
existing pipeline, and the open items in `poc_v2/README.md` remain open.

**Settled**: periods where one source has no value are kept with the missing side blank. The target timeline
is rebuilt from the union of both sources' boundaries and diffed against what is already loaded. The action
is decided by the **18-rule table** — the existing target row's current expiry decides first, and the hash
only decides inside the high-end-date branch. Retirement has **two** mechanisms, not one: a **dead record**
(expiry was `9999-12-31`, so it is pulled back to the row's own effective date and `IS_DEL` stays `'N'`) and
a **delete indicator** (expiry was a real date, so `IS_DEL` becomes `'Y'` and both dates are left alone).
The apply is **one `MERGE`** — separate `UPDATE` and `INSERT` statements are not approved by the client.

**Working assumption, not confirmed**: the problem sits on the Zone1 → Zone2 hop. The mechanics are identical
wherever it sits, but the layer decides which engine runs the SQL and who owns the build.

**Open, in order of how much they change the design**: whether a SQL override this large still pushes down
fully in IDMC (`solution_design.md` §12); whether a current-bucket read gives one row per key or all versions
(`glossary.md`); whether a source can *remove* one of its own versions; and whether load-timed tables may
drive target dates — the team has confirmed such tables exist in Zone1, so that one is a decision to take
rather than a fact to establish.

The full list of affected assets is owned by Abhi and not yet available.

---

## History load chunking — Iceberg → native *(script written, awaiting test run)*

Planner for the one-time historical load from Zone1 Iceberg tables to native tables: an anonymous Snowflake
Scripting block, run from a Snowflake Workspace, that reads each Iceberg table's structure and writes a chunk
plan (how many chunks, the dividing column, each chunk's range and size) to two metadata tables. Loading data
and building load SQL are out of scope.

| File | What it is |
|------|-----------|
| `solution_design.md` | **Design of record (v2)**: problem, scope, decisions D1–D15, architecture, how the chunking technique is chosen, metadata tables, behaviour |
| `chunk_planner_design_deck.html` | Design deck, 9 slides, self-contained (built with the `lm-html-deck` skill, deck-2 shell). Problem statement, architecture diagram, solution steps |
| `design_review.md` | The review trail, revisions 1–9: how the design got to v2 and why each change was made |
| `reference_ddl.sql` | CURRENT and HISTORY reference DDL for one table, transcribed, with each column's role annotated |
| `sql/01_metadata_ddl.sql` | `HIST_PLAN_TABLE` and `HIST_PLAN_CHUNK` |
| `sql/02_test_setup.sql` | 11 synthetic test objects, one per decision branch |
| `sql/03_smoke_test.sql` | Proves the scripting constructs the planner relies on work in the account |
| `sql/04_chunk_planner.sql` | **The planner** |
| `sql/05_validate.sql` | Expected-vs-actual checks and an exactly-once coverage proof against the source data |
| `sql/06_reset_test_metadata.sql` | Clears the test schema's plan rows |
| `sql/TEST_PLAN.md` | Run sequence R0–R9, expected results, evidence checklist E01–E17 |
| `sources/ddl_current_raw.png`, `sources/ddl_history_raw.png` | The DDL screenshots as shared (2026-10-05). Renamed from the chat upload names `1.png` / `2.png`, which carried no meaning |

**Current stage**: the design is closed and the script is written but **not yet run on Snowflake**. Next is to
run `sql/TEST_PLAN.md` and share the evidence screenshots, then do a reconnaissance run on 3–5 real table pairs.

**Folder name**: does not follow the `w<n>-` convention; named as requested.

---

## W4 — Generic ETL framework *(active)*

Architecture design for **one configuration-driven ETL framework in IDMC** serving every load type — full,
incremental, catchup, history, static, truncate-and-load, SCD1, SCD2 — and every team, built on the existing
ABC metadata tables. Includes DQ, reconciliation, dependency checks, parent-child relationships and parallel
grouping.

**Status**: high-level architecture in progress. **No build, no POC.** Requirements settled, the flow drawn,
and the feature register scored: the gap list stands at **26 features**, clustering in keys and table structure, where ABC records nothing at all.
The batch spine is ten blocks, the table spine eleven, and **seven checks** are the only things that stop a run.

| File | What it is |
|------|-----------|
| `high_level_design.md` | **ACTIVE.** The high-level architecture: the requirements settled with the design lead, the two-level flow from Stonebranch trigger to batch close, where every block exits, and what is deliberately left to low-level design |
| `high_level_design.xlsx` | **ACTIVE.** The same content structured — the flow drawn as blocks, every block as a row, the load-type / table-type / write-strategy vocabulary, and the **feature register**: 54 capabilities the framework needs, scored against what ABC already provides |
| `Zone2_OneTime_Loads.pptx` | **Background.** ABC's September 2026 design for Historical, Catchup and First-Time Incremental loads — the three rerun flags the W2 reference records as never built. Analysed in §10 of the design: nothing structural changes, and it validates the orthogonal-axes decision from outside this conversation |
| `framework_flow.drawio` | **ACTIVE.** The flow as an editable diagram — three columns: the configuration each step reads, the flow and its seven checks, and the state written or the failure exit |
| `requirement_and_design.md` | **PARKED.** The earlier design log. Its load-type model and target table types are requirement-level and still stand; its write-strategy mechanics and window-derivation work are low-level design and wait for sign-off on the architecture |
| `design_tracker.xlsx` | **PARKED** alongside it, for the same reason |

**One acceptance test governs the architecture:** one taskflow serves every load type, and **no block on the
flow diagram branches on load type**. A load type changes parameter values, never the path through the flow.

Settled with the design lead: Stonebranch triggers a **batch**, not a table · **one** taskflow · source and
target both in **Snowflake**, so full push-down applies and there is no staging block · control tables in
Aurora with working copies in Snowflake, pushed back at post load · Stonebranch owns the batch while the
**framework owns sequencing and parallelism of tables within it** · DQ and continue-on-failure exactly as ABC
does them today.

The earlier iteration drifted from architecture into detailed design — watermark arithmetic and column lists
before a flow existed. It is parked rather than deleted, with an honest classification of what carries
forward at the top of each file.

**This is a fresh design**, not a continuation of any earlier proof of concept in this repository. It does
not inherit decisions from one. The single background reference is
`../w2-abc-framework/reference.md`, used for the existing **Aurora metadata table structure** and ABC's
structural limits, so this design can decide what to reuse, what to extend and what to create.

**Design discussion for W4 stays in this folder.** It is deliberately not appended to the W2 ABC files, which
remain a reference for the framework as it exists today.

---

## DataCamp DS Professional practical exam *(active)*

Unrelated to W1-W3, and the one folder here not named `w<n>-`. The
certification practical exam for QuorWatt Urban Mobility: predict whether a shared e-scooter goes out of service in the next 24
hours, identify the strongest drivers, and recommend what the Fleet Reliability
Team should do next.

| File | What it is |
|------|-----------|
| `code.py` | **Source of truth.** Exact copy of the single DataLab code cell — validation, cleaning, EDA, both models, evaluation, business metric, driver ranking. CRLF line endings; preserve them |
| `report.txt` | **Source of truth** for the narrative. Exact copy of the DataLab text area, including the task-list preamble. CRLF |
| `written_report_draft.md` | The same narrative rendered as markdown, for reading and review |
| `FULL_SUBMISSION_REFERENCE.md` | Report + code in one file. **Generated** from `report.txt` and `code.py` — do not hand-edit |
| `PROJECT_NOTES.md` | Working notes: every decision taken, why, and what was verified against real output |
| `DS_capstone_scooter_snapshots.csv` | The dataset — 1800 scooter snapshots, 7 columns |
| `Deloitte+Practical+-+DS+-+Automotive.pdf` | The brief and the grading task list |
| `workbook_screenshot.png` | The DataLab workbook template task list |
| `scooter_reliability_presentation.pptx` | The deliverable deck — 8 slides, full word-for-word speaker notes in the notes pane |
| `presentation/make_charts.py` | Regenerates the deck's five charts from the CSV, same matplotlib style as `code.py`. Runnable from any directory |
| `presentation/build_deck.js` | Regenerates the .pptx (needs `npm install pptxgenjs`). Runnable from any directory |
| `presentation/charts/` | The rendered chart PNGs the deck embeds |

### Current stage

Code, written report and presentation are all complete and mutually consistent.
Every number in the report and the deck comes from a verified run of `code.py`.
**Still to do: record the presentation** (≤10 minutes) and submit both through
the certification portal. The deck's speaker notes are a full script; at a
normal 150 words per minute it runs about 8.9 minutes.

**Headline result**: the requested ≥90% accuracy target is not achievable and
should not be chased — a model predicting "in service" for every row already
scores 87.8% while catching nothing. The usable finding is that
`battery_health_score` dominates every driver ranking, and that at a 10%-of-fleet
daily inspection budget the model catches ~23% of next-day failures at a 29% hit
rate, against 0% under today's reactive maintenance.

**Paths**: `code.py` reads the CSV by a bare relative name, deliberately — that
is what the DataLab paste needs, and it resolves because the CSV sits beside it.
Run it from inside this folder:

```
cd "datacamp project" && python3 code.py
```

The two `presentation/` scripts resolve their own paths, so they run from
anywhere.

**Folder name**: `datacamp project` contains a space and does not follow the
`w<n>-<topic>` convention used by the other workstreams. Quote it in shell
commands.

---

## W5 — Zone 3 consumption publication gating *(active)*

Stopping business/reporting users from seeing a partially refreshed, internally inconsistent
consumption dataset while the upstream batch is still running. The visible state of a consumption
object changes today as a side effect of upstream loading; it must instead change only as an
explicit, controlled publication event.

**Status**: requirements phase closed, solution phase not started.

| File | What it is |
|------|-----------|
| `problem_statement.md` | **The agreed, frozen baseline.** Problem statement, scope, model and vocabulary, settled decisions D1 and D3, requirements R1-R24, parked dependencies, open operational policy. Section 6 carries working positions (D2, D4, A1-A4) that are **outside** the freeze |
| `requirement_deck.html` | Leadership deck, 7 slides, built on the `lm-html-deck` deck-1 identity. The baseline consolidated to four parts, with a stacked before/after timeline as the central diagram. By direction it carries **no requirement IDs and no source references**, unlike the skill's default. Derived from `problem_statement.md` — update it there first, then reflect it here |
| `sources/RE Discuss code freeze activities.msg` | The requirement source — a Copilot synthesis of the 24-Oct-2026 design discussion |
| `sources/POC02_Recommendation_and_Design 1.html` | **Background only.** Earlier clone-and-swap recommendation. Addresses a neighbouring problem and predates this requirement |
| `sources/POC05 - Same-Name Clone Refresh for Consumption - Deck.html` | **Background only.** Earlier same-name reclone analysis. A component, not a solution |

**Deliberately excluded as inputs**: the prior consumption-layer option analysis, and the two decks
above as a basis for analysis. This problem is approached fresh — see the provenance section of
`problem_statement.md`.

**The four discriminating requirements**, each capable of eliminating an otherwise attractive
option on its own: **R4** (publishing one consistency group must not make another inconsistent),
**R15** (publication must not persist masked values as real data), **R20** (no per-object
redevelopment of existing view logic), **R22** (consistency-group membership known and kept
current).

**Vocabulary that matters.** The *unit of governance* is the object — tags, masking and grants
bind there. The *unit of visibility* is the consistency group — the closure of ground objects a
report depends on. Collapsing those two produces a broken design. That views inherit consistency
rather than being published is a working position (D4), not part of the freeze.

**Not W4.** W4 is the generic ETL framework that loads objects. W5 is about when a loaded object
becomes *visible*. They meet only at the publication step (R8).

---

## Conventions

- **One folder per workstream**, named `w<n>-<short-topic>`. Add it to the tree at the top of this file and
  give it a section here, in the same commit that creates it.
- **Raw inputs go in that workstream's `sources/`** and keep their original filenames — do not rename them,
  so they stay traceable to the meeting or thread they came from. Everything else is derived analysis and
  gets a short descriptive name.
- **No prefixes on filenames.** The folder already says which workstream a file belongs to.
- **Cross-workstream references use a relative path** (`../w2-abc-framework/reference.md`), so it is obvious
  when a document is reaching outside its own workstream.
- A file serving more than one workstream lives in W2 (reference) and says which workstreams use it.
