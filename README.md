# Repository index

Working repository for GRS Zone1→Zone2 (Teradata → Iceberg → Snowflake, orchestrated by IDMC) analysis and
design work. It holds **several unrelated workstreams**, one folder each.

**Read this first, then work inside one folder.**

```
├── w1-aurora-db-connection/      Dev Aurora connection saturation      — open
├── w2-abc-framework/             ABC framework reference               — background
├── w3-scd-effective-date-split/  Multi-source SCD2 date split          — ACTIVE
└── (repo root)                   DataCamp DS practical exam            — ACTIVE
```

The DataCamp exam files sit at the repo root rather than in a `w<n>-` folder,
because `code.py` reads the CSV by a bare relative path and moving either would
break the DataLab paste. See the note at the end of this file.

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
orchestration layer every Zone1→Zone2 job integrates with. Built from the design workbook and 17 KT
transcripts.

**Cross-cutting.** Background for both W1 and W3; not itself an issue to be solved.

Sections W3 leans on:
- §2 — Aurora vs. Snowflake split, and why the framework depends on **full push-down optimization (PDO)**
- §3 — naming conventions, IDMC connection and folder conventions
- **§5 Phase 3 (Job load)** — the existing two-step shape: one source-qualifier query (full PDO) → stage,
  then a SQL `MERGE` stage → target. The shape any W3 solution has to fit inside
- §4.2 `etl_data_ingestion_source_window` — the per-source-table sourcing window the W3 POC uses
- §7 — DQ rule handling

Referenced but **not in this repo**: `abc_framework_deck.html`, the design workbook
`ABC_load_across_phases_scenrios.xlsx`, and `KT transcripts/` + `claude/transcript_notes/`. Treat citations
to these as external.

---

## W3 — SCD multi-source effective-date split *(active)*

**Problem**: when two or more SCD Type-2 source tables are joined to load a single SCD Type-2 target,
neither source alone can determine the target's `row_eff_dte` / `row_exp_dte`. The target timeline has to be
derived from the union of both sources' version boundaries, and rows already loaded have to be reconciled
when a later run splits an interval that was already written.

Distinct from the established pattern — one driving table, LEFT JOINed to others purely for attribute
enrichment — where the driving table alone sets the target dates.

| File | What it is |
|------|-----------|
| `scenario_matrix.md` | Which join combinations hit the problem and why, explained with worked data. Written to be read cold by people outside the discussion |
| `solution_design.md` | How it gets solved: the three-step architecture, why a single MERGE fails, the IDMC components, and what the POC proves |
| `poc_snowflake.sql` | Runnable POC for `LM_POC_DB.POC_SCHEMA`. Loads Day 1 and Day 2, runs all three steps, asserts twelve results. Uses the real `ETL_DATA_INGESTION_SOURCE_WINDOW` and audit-column conventions; business table names are illustrative and flagged in the header |
| `solution_deck.html` | The slide deck — 9 slides covering the problem, the worked Day 1 / Day 2 example, which join combinations break, and the solution architecture. Standalone single file: open it in a browser, no server and no build step. Speaker notes behind the toggle in the header; `Ctrl`/`Cmd`+`P` prints one slide per page |
| `glossary.md` | Zone / bucket / source-system vocabulary (SOR, `legacy_TD`, current vs. history bucket) that the ABC reference leaves undefined. Every entry marked Confirmed / Inferred / Unknown |
| `sources/…vtt` | Meeting transcript, 2026-09-18. 617 cues, no speaker tags. Where the problem was first walked through |
| `sources/scenario_screenshot.png` | The Excel mock-up shared on that call — Day 1 and Day 2 worked example |

**Screenshot scope**: only the `Tbl1` / `Tbl2` blocks and the Day1/Day2 target blocks are in scope. The
`Tbl3` block, the top-right `b1`/`t1` rows, and the bottom `Zone1` notes are unrelated scratch.

### Current stage

Solution design drafted and a runnable POC written; **awaiting execution evidence** from a real Snowflake run
before any of it is called proven.

**Settled**: periods where one source has no value are kept with the missing side blank; superseded rows are
soft-deleted and reinserted rather than updated in place; the load is three steps (build-and-diff → stage →
soft-delete → insert) rather than a single MERGE.

**Working assumption, not confirmed**: the problem sits on the Zone1 → Zone2 hop. The mechanics are identical
wherever it sits, but the layer decides which engine runs the SQL and who owns the build.

**Open, in order of how much they change the design**: whether a SQL override this large still pushes down
fully in IDMC (`solution_design.md` §11); whether a current-bucket read gives one row per key or all versions
(`glossary.md`); whether a source can *remove* one of its own versions; and whether load-timed tables may
drive target dates — the team has confirmed such tables exist in Zone1, so that one is a decision to take
rather than a fact to establish.

The full list of affected assets is owned by Abhi and not yet available.

---

## DataCamp DS Professional practical exam *(active, repo root)*

Unrelated to W1-W3. The certification practical exam for QuorWatt Urban
Mobility: predict whether a shared e-scooter goes out of service in the next 24
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

### Current stage

Code and written report are complete, mutually consistent, and every number in
the report comes from a verified run of `code.py`. **The presentation (6-10
slides, ≤10 minutes, recorded) has not been started** — it is a separately
graded, mandatory deliverable.

**Headline result**: the requested ≥90% accuracy target is not achievable and
should not be chased — a model predicting "in service" for every row already
scores 87.8% while catching nothing. The usable finding is that
`battery_health_score` dominates every driver ranking, and that at a 10%-of-fleet
daily inspection budget the model catches ~23% of next-day failures at a 29% hit
rate, against 0% under today's reactive maintenance.

**Known gap**: these files break this repo's own one-folder-per-workstream
convention. Moving them into `w4-datacamp-practical/` would be tidier but breaks
`code.py`'s relative read of the CSV and the direct paste into DataLab. Left at
the root deliberately; revisit once the exam is submitted.

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
