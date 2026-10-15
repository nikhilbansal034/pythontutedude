# Start here — SCD multi-source effective-date split

**What this pack is.** Everything needed to pick up this workstream in a different environment, including
for an AI assistant that has none of the conversation history behind it. It is written to be read cold.

**The problem, in three sentences.** When two or more SCD Type-2 source tables are joined to load a single
SCD Type-2 target, neither source alone can determine the target's effective and expiration dates. The
target's timeline has to be rebuilt from the union of *every* contributing source's version boundaries, and
rows already loaded have to be reconciled when a later run splits an interval that was already written.
Joining on business keys alone produces a cartesian across versions, and the de-duplication that follows
hides it.

---

## Reading order

**If you are an AI assistant generating SQL**, read in this order and stop when you have what you need:

| | File | Why |
|---|---|---|
| 1 | `01_problem_and_design.md` | The mechanism and the 18-rule decision table. Everything else assumes it |
| 2 | `../dataassist/generation_rules.md` | **How to behave.** Eight rules with triggers. Read before generating anything |
| 3 | `../dataassist/historical_load_instructions.md` | What to produce for the Day 1 load |
| 4 | `02_incremental_load_instructions.md` | What to produce for Day 2 onward. **Read its assumptions block first** |
| 5 | `04_worked_examples.md` | Data walkthroughs. Pattern-match against these before inventing an approach |
| 6 | `03_defects_catalogue.md` | Every defect found in four generated assets, with the correct SQL for each |

**If you are a person inheriting this**, read `01` then `03`, then skim `02` and `04`. The full narrative of
how it got here is in `../solution_design.md`, 26 sections — useful background, not needed to act.

---

## Status board

### Proven

- **The design.** 69 test cases across 15 scenarios, 69 passing, executed against Snowflake and evidenced
  by 346 captioned screenshots. Coverage is measured, not claimed: 15 of the 18 rules emit a stage row and
  were observed directly; rules 1, 3 and 18 emit nothing, so they are proved by zero writes.
- **The POC found a real defect in the rule set**, not just in its own code — on a `Z1_RERUN` a genuinely
  new interval was misclassified and its insert silently dropped, losing all target cover from that date
  onward. Fixed, with a regression guard.
- **The historical load generalises.** DataAssist applied the boundary-union mechanism to eight contributing
  sources unaided, from the instruction file alone.

### Open, highest first

| | What | Where |
|---|---|---|
| 1 | **`OFFICE_DEPARTMENT` computes the foreign-key split and then discards it.** History lost, surviving FK arbitrary | `03_defects_catalogue.md` OD10 |
| 2 | **No generated asset asserts anything about the rows it actually writes.** Every defect found so far reached review instead of failing at run time | OD2, and the pattern note below |
| 3 | **The six HR template defects** — one STTM template, three tables, same six defects | `03_defects_catalogue.md` |
| 4 | **Three decisions block the incremental load** | `02_incremental_load_instructions.md` §0 |
| 5 | **The multi-source split has never been generated.** Four assets reviewed; all single-source or FK-driven | below |

### The gap worth naming

**The case this whole design exists for has not been generated once.** Every asset reviewed so far was
either a single source with its own history dates, or a target with foreign keys into SCD-2 parents. The
multi-source boundary union — two co-equal dated sources feeding one target — is proven in the POC and has
never come out of the generator. A table of the `ACCOUNT_PARTY_REFERENCE` shape needs requesting
deliberately; it will not turn up on its own.

---

## Five things that will bite you

**1. A table can govern the output while appearing only in prose.** Twice now a source has been named
nowhere but the free-text Transformation column — once as a join, once as a lookup. A classifier reading
the `Current State Table` column will never see it.

**2. The de-duplication hides the thing the checks are looking for.** A `ROW_NUMBER() … = 1` guarantees
one row per `(key, effective date)`, so a duplicate-key check placed after it can never fail. Put that check
against the **source**.

**3. Checks keyed on the wrong key are blind to the key being wrong.** On one asset every self-check was
keyed on a hardcoded constant; on another the key omitted a scoping column, and a whole business entity was
dropped while all eight checks reported zero.

**4. The generator improvises where the mapping is ambiguous and never says so.** A misspelled function, an
unresolvable identifier in a conditional, a bare `Audit Field` on an indicator column — each produced clean,
runnable, wrong SQL. **Wrong SQL that runs is the worst possible output**, because no one looks at it again.

**5. The hash must exclude the dates.** It decides the action in the incremental rule table, so a hash that
includes the effective or expiration date cannot tell *"same values, different expiry"* from *"different
values"*. Generated code has already got this wrong once.

---

## Vocabulary

| Term | Meaning |
|---|---|
| **Zone1 / Zone2** | Zone1 is the refined landing area (current + history buckets); Zone2 is the curated target |
| **Q1 / Q2** | The two files DataAssist emits per table: Q1 source → staging, Q2 staging → target |
| **STTM** | The data modeller's source-to-target mapping: current state, transformation prose, target column, type, natural-key flags |
| **High end date** | `9999-12-31`. A row carrying it is open-ended |
| **Dead record** | A retired row whose expiry is pulled back to its own effective date, so it spans zero days |
| **Delete indicator** | A retired row flagged `IS_DEL = 'Y'` with both dates left untouched |
| **Rebuild-and-diff** | Rebuild an impacted key's entire timeline from the union of all sources' boundaries, then diff it against the target |
| **Impacted key** | A business key whose sources moved since the last run, found via the process clock |

Full glossary with Confirmed / Inferred / Unknown markers: `../glossary.md`.
