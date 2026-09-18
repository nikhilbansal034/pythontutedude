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
| **W3** | SCD multi-source effective-date split | **Active — current work** | 2 `.md`, 1 `.vtt`, 1 `.png` |

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
| `scd_scenario_matrix.md` | **Draft** scenario catalogue — which source/target combinations hit the problem, built under both readings of Q1, plus the eleven failure mechanisms and why each one breaks |
| `scd_glossary.md` | Working definitions of the zone / bucket / source-system vocabulary (SOR, `legacy_TD`, current vs. history bucket) that the ABC doc leaves undefined. Each entry marked Confirmed / Inferred / Unknown |
| `LM - GRS Teradata  MVP - Multiple_SCD_joins_Target_Eff_date_split - USI Morning-20260918_083847-Meeting Recording-en-US.vtt` | Meeting transcript, 2026-09-18. 617 cues, no speaker tags. Where the problem was first walked through |
| `scenario_screenshot.png` | The Excel mock-up shared on that call — day-1 and day-2 worked example for a two-table join on key `k1` |

**Screenshot scope**: only the `Tbl1` / `Tbl2` blocks and the Day1/Day2 target blocks are in scope. The `Tbl3`
block, the top-right `b1`/`t1` rows, and the bottom `Zone1` notes are unrelated scratch — ignore them.

### Current stage

Scoping. Enumerating the full permutation space of source/target SCD-type combinations to establish **which
combinations actually hit this problem and which are already handled** by the existing pattern — before any
solution design.

Not yet decided: inner vs. outer join semantics for the contributing tables, `is_del` semantics, the full
list of affected assets (owned by Abhi).

**Blocking question (Q1)**: whether a Zone1 *current bucket* read of a source table that is SCD2 in the SOR
returns one row per business key, or all of the source's effective-dated versions. The answer changes which
combinations hit the problem. See `scd_glossary.md`.

---

## Conventions for new files

- Prefix new W3 files with `scd_` so they group together — e.g. `scd_scenario_matrix.md`.
- Keep W1 files on the existing `Aurora_` prefix.
- Add any new file to the table under its workstream in this README, in the same commit.
- Raw inputs (transcripts, screenshots, emails) keep their original filename — do not rename them, so they
  stay traceable to the meeting or thread they came from.
- If a file serves more than one workstream, put it under W2 (reference) and note which workstreams use it.
