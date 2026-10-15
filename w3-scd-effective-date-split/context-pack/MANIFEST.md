# Transfer manifest

What to copy into the client environment, what deliberately **not** to, and how to confirm the transfer
landed intact.

---

## Copy these — about 500 KB

### 1. The pack itself

```
context-pack/00_START_HERE.md
context-pack/01_problem_and_design.md
context-pack/02_incremental_load_instructions.md
context-pack/03_defects_catalogue.md
context-pack/04_worked_examples.md
context-pack/MANIFEST.md
```

### 2. The two instruction files the pack points at

```
dataassist/historical_load_instructions.md      what to produce for Day 1
dataassist/generation_rules.md                  how to behave while generating
```

**Keep them under a `dataassist/` folder one level up from `context-pack/`**, or fix the relative links in
`00_START_HERE.md`. The pack references them as `../dataassist/…`.

### 3. The reference implementation — the highest-value thing here

```
poc_v2/00_objects.sql            every object, the Step 1 diff view, the Step 2 MERGE
poc_v2/scenarios/S01.sql … S15.sql    69 worked cases with expected results inline
poc_v2/TEST_PLAN.md              the grid: which rules each scenario reaches, and its result
poc_v2/README.md                 what each scenario proves
```

**This is executable truth, and it is the part most likely to be left behind** because it is not markdown.
A copilot that can read `00_objects.sql` has the 18 rules as working SQL rather than as prose, and the 15
scenario files give it 69 input/expected pairs to pattern-match against.

### 4. The verifiers — so the copilot can check itself

```
tools/verify/verify_historical_examples.py       the split, collapse, gaps, the containment check
tools/verify/verify_historical_check7.py         why containment catches a misclassification
tools/verify/verify_tpa_assertions.py            constant-keyed checks failing on correct data
tools/verify/verify_tpa_agreement_fk.py          stale FK, and the duplicate insert
tools/verify/verify_department_findings.py       tautological checks, hidden duplicates, lost job
tools/verify/verify_office_department_fix_review.py   the split computed and discarded
```

They need **`duckdb` only** — no Snowflake connection, no credentials, no network. Each prints its own
pass/fail. If `duckdb` is not installable in the client environment, copy them anyway: they read as precise
specifications of each defect.

### 5. Optional background for a human, not for a copilot

```
solution_design.md       26 sections. The full narrative of how this was reached
glossary.md              Zone / bucket / source-system vocabulary, each entry marked
                         Confirmed / Inferred / Unknown
review/                  the independent test lead review and our response
```

> **Do not feed `solution_design.md` to a copilot wholesale.** It is 1,600 lines, and sections 1–19 are
> *how we got here* — essential for a person inheriting this, mostly noise for something generating SQL.
> `01_problem_and_design.md` is the distillation that replaces it for that purpose. Sections 20–26 are the
> DataAssist integration and are genuinely useful if you want more than the catalogue gives.

---

## Do not copy — about 18 MB, and none of it helps

| | Size | Why not |
|---|---|---|
| `poc_v2/evidence/POC_Evidence.xlsx` | **11 MB** | 346 captioned screenshots. Evidence for a human auditor that the POC really ran; unreadable to a copilot and it would dominate any context window |
| `sources/*.docx` (4 files) | **5.9 MB** | Screenshots of generated SQL you already have in the client environment as actual files |
| `sources/*.vtt` | 72 KB | Meeting recordings with participant names. Nothing in them is not already captured in the design |
| `sources/*.xlsx`, `*.png` | 370 KB | Superseded scenario catalogues and a whiteboard photo |
| `poc_v2/evidence/archive/` | 437 KB | A superseded evidence workbook |
| `tools/mk_*.py`, `refresh_docs.py`, `annotate_evidence.py` | — | Generators for *this* repo's artefacts. They have no job in the client environment |

**That is 18 MB of the 19 MB total.** Leaving it behind is not a compromise — the copilot is better without it.

---

## Confirm the transfer landed

```bash
# 1. the verifiers run and pass
for f in tools/verify/*.py; do python3 "$f" > /dev/null && echo "OK $f" || echo "FAIL $f"; done

# 2. the pack's internal links resolve
grep -oE '\.\./[A-Za-z0-9_./-]+\.(md|sql|py)' context-pack/*.md | cut -d: -f2 | sort -u | \
  while read p; do [ -f "context-pack/$p" ] && echo "OK   $p" || echo "MISS $p"; done
```

If step 2 reports misses, the folder shape differs from the one above — either restore it or fix the
relative links in `00_START_HERE.md`.

---

## Prime a copilot with this

A first message that gets a cold assistant to the right place:

> This repository holds the design for a Snowflake SCD Type-2 load where the target's effective and
> expiration dates must be derived from several source tables rather than taken from any one of them.
>
> Read `context-pack/00_START_HERE.md` first — it gives the reading order and a status board of what is
> proven versus open. Then read `context-pack/01_problem_and_design.md` for the mechanism and the 18-rule
> decision table, and `dataassist/generation_rules.md` before generating any SQL.
>
> Three things to know before you start. The incremental instructions
> (`context-pack/02_incremental_load_instructions.md`) rest on three assumptions stated in their §0 that
> are **not yet confirmed** — check them before generating production SQL. The defect catalogue
> (`context-pack/03_defects_catalogue.md`) lists every mistake already made generating this, with the
> correct SQL for each; read it before repeating one. And the worked examples
> (`context-pack/04_worked_examples.md`) were all executed — the scripts in `tools/verify/` reproduce them,
> and you can run them yourself with `duckdb`.

---

## What is still missing, and should travel as a known gap

| | |
|---|---|
| **The multi-source split has never been generated** | Four assets reviewed; all single-source or foreign-key driven. The case this design exists for needs a table of the `ACCOUNT_PARTY_REFERENCE` shape requested **deliberately** |
| **Three decisions block the incremental load** | `02_incremental_load_instructions.md` §0. A3 — whether Q2 may emit two rows per key — is the one most likely to force a redesign |
| **No generated asset asserts what it writes** | Every defect found so far reached human review rather than failing at run time, for this reason alone |
| **`SEQ.NEXTVAL` inside `MERGE … WHEN NOT MATCHED THEN INSERT … VALUES`** | Expected to work, never confirmed from documentation. A 30-second test in the account settles it, and it is a hard failure if unsupported |
