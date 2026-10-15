# W3 — SCD multi-source effective-date split

**The problem.** When two or more SCD Type-2 source tables are joined to load a single SCD Type-2 target,
neither source alone can determine the target's `row_eff_dte` / `row_exp_dte`. The target timeline has to be
derived from the union of both sources' version boundaries, and rows already loaded have to be reconciled
when a later run splits an interval that was already written.

Distinct from the established pattern — one driving table, LEFT JOINed to others purely for attribute
enrichment — where the driving table alone sets the target dates.

---

## Where things are

```
.
├── context-pack/            Self-contained pack for moving this to another environment
├── solution_design.md       The design of record
├── glossary.md              Zone / bucket / source-system vocabulary
├── scd_date_split_design_deck.html   7-slide walkthrough, open in a browser
│
├── poc_v2/                  The POC — proven, 69/69 against Snowflake
├── dataassist/              Integration with the client's code generator
├── review/                  The independent test lead review, and our response
├── sources/                 Raw inputs, original filenames
└── tools/                   Generators, checks, and verifiers
```

### `context-pack/` — for moving this elsewhere

A self-contained pack written to be read cold, including by an AI assistant with none of the history
behind it. `00_START_HERE.md` gives the reading order and a status board;
`02_incremental_load_instructions.md` is the Day 2+ specification and is **the only document here that
rests on unconfirmed assumptions** — they are listed in its §0. `MANIFEST.md` says exactly what to copy
(about 500 KB), what to leave behind (about 18 MB, none of it useful to a copilot) and how to confirm the
transfer landed.

### `solution_design.md` — the design of record

One file, numbered sections. The locked **18-rule table** is §6. §16 holds the test strategy and result,
§17 the defect the POC found. §20 onward cover the DataAssist integration, §24–§26 the reviews of generated
output.

### `poc_v2/` — the POC

**69 test cases across 15 scenarios, 69 passing**, executed against Snowflake and evidenced.
`00_objects.sql` holds every object, the Step 1 diff view and the Step 2 MERGE; `scenarios/S01.sql …
S15.sql` are one file per scenario; `TEST_PLAN.md` is the grid with the rules each reaches and its result;
`poc_v2/evidence/POC_Evidence.xlsx` carries 346 captioned screenshots. See `poc_v2/README.md`.

### `dataassist/` — integration with the client's generator

DataAssist reads the data modeller's STTM and emits two files per table: **Q1** source → staging, **Q2**
staging → target. These four documents are what we feed it, and what came back.

| File | What it is |
|------|-----------|
| `historical_load_instructions.md` | **The input.** How the Day 1 load works: a per-table classifier, one SQL template per classification, worked data examples, and the self-check assertions the generator must emit |
| `generation_rules.md` | **How to behave while generating.** Eight rules with triggers, learned from reviewing the first output. Its spine: produce plausible SQL where you should have stopped, and wrong SQL that runs is the worst outcome |
| `review_hr_tables.md` | Review of three ADW HR assets — `DEPARTMENT` (D1–D7), `JOB` (J1–J7), `OFFICE_DEPARTMENT` (OD1–OD9). All three reproduce the same six defects from one STTM template |
| `review_office_department_fix.md` | Round 2 on `OFFICE_DEPARTMENT` after the generator was corrected. Six findings fixed; one critical defect introduced |

### `review/` — the independent test lead review

`TEST_LEAD_REVIEW.md` is the review itself: conditional sign-off with four blocking exit criteria.
`TEST_LEAD_REVIEW_RESPONSE.md` is our response, with every finding independently re-executed before being
accepted.

### `sources/` — raw inputs

Original filenames, so each stays traceable to the meeting, thread or upload it came from. Meeting
transcripts, the client's `Requirement.xlsx`, the scenario workbooks, and the `.docx` files carrying
screenshots of generated SQL.

### `tools/` — generators, checks and verifiers

| | |
|---|---|
| `mk_scenarios.py` | Generates the 15 scenario files from one spec |
| `refresh_docs.py` | Rebuilds the test-plan grid from a real run |
| `check_sql_lint.py` | Catches the two Snowflake-only errors DuckDB accepts |
| `check_merge_drift.py` | Proves all 70 copies of the apply MERGE are byte-identical |
| `run_scenario_duckdb.py` | The offline harness |
| `annotate_evidence.py`, `mk_evidence_workbook.py` | Build and caption the evidence workbook |
| **`tools/verify/`** | One script per review, reproducing every executed claim in it. They need `duckdb` only |

Everything in `tools/` runs from this folder:

```
python3 tools/check_sql_lint.py
python3 tools/run_scenario_duckdb.py S01.sql
python3 tools/verify/verify_historical_examples.py
```

---

## Current stage

**The POC is proven.** 69/69 against Snowflake, with coverage measured rather than claimed: 15 of the 18
rules emit a stage row and were observed directly; rules 1, 3 and 18 emit nothing and are proved by zero
writes. It also found a real defect in the rule set — see `solution_design.md` §17.

**Integration is under way, historical load first.** Four generated assets have been reviewed. The split
mechanism itself is sound where it has been exercised, but **the multi-source case the POC was built for has
not been generated once** — every asset so far has been single-source or foreign-key driven.

**Open, highest first.** `OFFICE_DEPARTMENT` round 2 computes the split and then discards it
(`dataassist/review_office_department_fix.md`, OD10/OD11 — one change, not two). The HR template defects
need fixing once at the mapping template rather than per table. And no generated asset yet asserts anything
about the rows it actually writes, which is how every defect above reached review rather than being caught
at run time.
