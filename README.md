# Repository index

Working repository for GRS Zone1→Zone2 (Teradata → Iceberg → Snowflake, orchestrated by IDMC) analysis and
design work. It holds **several unrelated workstreams**. This file says which file belongs to which, so that
work on one topic does not get confused with background from another.

**Read this first, then read only the files under the workstream you are working on.**

---

## Workstream index

| ID | Workstream | Status | Files |
|----|-----------|--------|-------|
| **W1** | Dev Aurora DB connection issue | Open — awaiting connection breakdown + Informatica pool review | 3 `.md`, 1 `.msg` |
| **W2** | ABC framework reference | Reference / background | 1 `.md` |
| **W3** | SCD multi-source effective-date split | **Active — current work** | 3 `.md`, 1 `.sql`, 1 `.vtt`, 1 `.png` |

---

## W1 — Dev Aurora DB connection issue

Connection saturation on the Dev Aurora PostgreSQL instance
(`grsdiai-hydration-aurora-postgress-db-development-i2`) blocking TD/MVP unit testing and SIT.

| File | What it is |
|------|-----------|
| `Aurora_DB_Connection_Analysis.md` | Source-by-source record of the email thread and the Informatica↔Aurora discussion |
| `Aurora_RootCause_Actions_LongTerm.md` | Full technical analysis — failure-mode space, remediation ordered by speed, long-term fix |
| `Aurora_Team_Action_Plan.md` | The action plan written for the whole thread (DBA/AWS, Informatica, ingestion teams) |
| `Re URGENT Alignment Required  Dev Aurora DB Connection Issue.msg` | Raw source email thread |

**Not relevant to W3.** Aurora here is the ABC control/metadata database, not a data-pipeline target.

---

## W2 — ABC framework reference

`abc_framework_success_scenario.md` — complete reference for the Audit Balancing Control framework: the
metadata-driven orchestration layer every Zone1→Zone2 job integrates with. Built from the design workbook and
17 KT transcripts.

**Cross-cutting.** It is background for both W1 and W3, but is not itself an issue to be solved.

Relevant to W3 specifically:
- §2 — Aurora vs. Snowflake split, and why the framework depends on **full push-down optimization (PDO)**
- §3 — naming conventions, IDMC connection/folder conventions
- **§5 Phase 3 (Job load)** — the existing 2-step shape: one source-qualifier query (full PDO) → stage,
  then a SQL `MERGE` stage → target. This is the pattern any W3 solution has to fit inside.
- §7 — DQ rule handling

Referenced but **not present in this repo**: `abc_framework_deck.html` (the visual deck), the design workbook
`ABC_load_across_phases_scenrios.xlsx`, and `KT transcripts/` + `claude/transcript_notes/`. Treat citations to
these as external.

---

## W3 — SCD multi-source effective-date split *(active)*

**Problem**: when two or more SCD Type-2 source tables are joined to load a single SCD Type-2 target, neither
source alone can determine the target's `row_eff_dt` / `row_exp_dt`. The target timeline has to be derived
from the union of both sources' version boundaries, and existing target rows have to be reconciled when a
later run splits an interval that was already loaded.

This is distinct from the established pattern (one driving table, LEFT JOINed to others purely for attribute
enrichment), where the driving table alone sets the target dates.

| File | What it is |
|------|-----------|
| `scd_solution_design.md` | **Draft** — how the problem gets solved: the three-step architecture, why a single MERGE fails, the IDMC components, and what the POC proves |
| `scd_poc_snowflake.sql` | Runnable POC for `LM_POC_DB.POC_SCHEMA`. Uses the real `ETL_DATA_INGESTION_SOURCE_WINDOW` and audit-column conventions; business table names are illustrative and flagged in the header. Loads Day 1 and Day 2, runs all three steps, asserts twelve results |
| `scd_scenario_matrix.md` | **Draft** — which join combinations hit the problem and why, explained with worked data. Written to be shown to others, not just read by the team |
| *(deck, not in repo)* | Slide deck covering the same ground plus the IDMC solution design — [claude.ai/artifact/6PJkrypcJ7oZZTgUjV2cYE](https://claude.ai/artifact/6PJkrypcJ7oZZTgUjV2cYE). Private to its owner until shared |
| `scd_glossary.md` | Working definitions of the zone / bucket / source-system vocabulary (SOR, `legacy_TD`, current vs. history bucket) that the ABC doc leaves undefined. Each entry marked Confirmed / Inferred / Unknown |
| `LM - GRS Teradata  MVP - Multiple_SCD_joins_Target_Eff_date_split - USI Morning-20260918_083847-Meeting Recording-en-US.vtt` | Meeting transcript, 2026-09-18. 617 cues, no speaker tags. Where the problem was first walked through |
| `scenario_screenshot.png` | The Excel mock-up shared on that call — day-1 and day-2 worked example for a two-table join on key `k1` |

**Screenshot scope**: only the `Tbl1` / `Tbl2` blocks and the Day1/Day2 target blocks are in scope. The `Tbl3`
block, the top-right `b1`/`t1` rows, and the bottom `Zone1` notes are unrelated scratch — ignore them.

### Current stage

Solution design drafted and a runnable POC written; **awaiting execution evidence** from a real Snowflake
run before any of it is called proven.

**Settled**: periods where one source has no value are kept with the missing side blank; superseded rows are
soft-deleted and reinserted rather than updated in place; the load is three steps (build-and-diff → stage →
soft-delete → insert) rather than a single MERGE.

**Working assumption, not confirmed**: the problem sits on the Zone1 → Zone2 hop. The mechanics are identical
wherever it sits, but the layer decides which engine runs the SQL and who owns the build.

**Open, in order of how much they change the design**: whether a SQL override this large still pushes down
fully in IDMC (see `scd_solution_design.md` §11); whether a current-bucket read gives one row per key or all
versions (`scd_glossary.md`); whether a source can *remove* one of its own versions; and whether load-timed
tables may drive target dates — the team has confirmed such tables exist in Zone1, so that one is now a
decision to take rather than a fact to establish.

The full list of affected assets is owned by Abhi and not yet available.

---

## Conventions for new files

- Prefix new W3 files with `scd_` so they group together — e.g. `scd_scenario_matrix.md`.
- Keep W1 files on the existing `Aurora_` prefix.
- Add any new file to the table under its workstream in this README, in the same commit.
- Raw inputs (transcripts, screenshots, emails) keep their original filename — do not rename them, so they
  stay traceable to the meeting or thread they came from.
- If a file serves more than one workstream, put it under W2 (reference) and note which workstreams use it.
