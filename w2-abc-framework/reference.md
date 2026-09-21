# ABC Framework — The Sequential Chain

**Audit Balancing Control**: the metadata-driven execution-control framework every Zone1→Zone2 (and
Zone3) ETL job integrates with.

This document follows **one batch run from the moment it is triggered until it closes**. Everything is
in the order it actually happens. Where a phase behaves differently for a restart, a rerun or a
historical load, that difference is described at the point in the chain where it occurs, and §11
collects the seven execution types side by side.

**Built from**: the 16 KT transcripts in [`KT_transcript/`](KT_transcript/), read end to end —
the June architecture session, the May metadata sessions, the Zone2 design session, ABC KT 1–7
(Jul–Aug 2026), the Balance Reconciliation KT, the runtime-mock-entries session, the September
"new changes" session, and the two September framework walkthroughs.

**Nothing here is invented.** Where the transcripts disagree, where a speaker was unsure, or where
audio was ambiguous, that is said explicitly rather than resolved silently. Facts that are true only
of a particular asset (broker, CCO) are labelled as such.

---

## Table of contents

**Orientation**
1. [What ABC is, and the vocabulary](#1-what-abc-is-and-the-vocabulary)
2. [The physical landscape — Aurora, Snowflake, IDMC, Stonebranch](#2-the-physical-landscape)
3. [Why full push-down optimization dictates the design](#3-why-full-push-down-optimization-dictates-the-design)

**Before the chain can run — the setup**
4. [Step S1 — Populate the metadata tables, in dependency order](#4-step-s1--populate-the-metadata-tables-in-dependency-order)
5. [Step S2 — Stand up the IDMC components for a domain](#5-step-s2--stand-up-the-idmc-components-for-a-domain)
6. [Step S3 — Write the parameter file](#6-step-s3--write-the-parameter-file)
7. [Step S4 — Hand-build the per-table ABC logic inside the mappings](#7-step-s4--hand-build-the-per-table-abc-logic-inside-the-mappings)

**The chain**
8. [The chain at a glance](#8-the-chain-at-a-glance)
9. [Phase by phase — the full sequence](#9-phase-by-phase--the-full-sequence)
   - [Phase 0 — Scheduler trigger and the Zone1 dependency](#phase-0--scheduler-trigger-and-the-zone1-dependency)
   - [Phase 1 — Batch preload prerequisite](#phase-1--batch-preload-prerequisite)
   - [Phase 2 — Batch preload](#phase-2--batch-preload)
   - [Phase 3 — Job preload](#phase-3--job-preload)
   - [Phase 4 — Job load](#phase-4--job-load)
   - [Phase 5 — Job post load](#phase-5--job-post-load)
   - [Phase 6 — Batch post load](#phase-6--batch-post-load)
10. [The failure chain](#10-the-failure-chain)

**Variants and reference**
11. [The seven execution types](#11-the-seven-execution-types)
12. [Flag legend — every flag, every value](#12-flag-legend--every-flag-every-value)
13. [Table catalogue, keyed to the chain](#13-table-catalogue-keyed-to-the-chain)
14. [Notifications](#14-notifications)
15. [The September 2026 changes](#15-the-september-2026-changes)
16. [Open items, risks and known gaps](#16-open-items-risks-and-known-gaps)
17. [People, external documents, and where things live](#17-people-external-documents-and-where-things-live)

---

# Orientation

## 1. What ABC is, and the vocabulary

ABC is an **execution control framework** that ensures data loads are accurate and consistent. The
name decomposes exactly:

- **Audit** — verify that every record arriving from the source is properly accounted for in the
  target, and record all the counts and errors in `job_run_stats`.
- **Balance** — after the load, compare an aggregated **amount** sum between source and target
  (count checks also live here).
- **Control** — manage restartability, rerun, skip-on-restart, and all such operations.

The stated design goal: individual jobs should not separately implement row-count tracking, restart
handling, DQ enforcement or balance reconciliation. *"The framework is capable enough to take the
counts, to fail the job, to restart the job, whatever the scenarios. The effort we have to put here
is integrating the framework with our job execution."*

### Batch, job, and the three identifiers

**A batch is the combination of SOURCE + DOMAIN + APPLICATION LAYER (+ target zone).**

> CMPM (source) → Broker (domain) → Data Domain (layer) in Zone 2 = one batch.
> A domain's tables may be fed by several sources; each source gives that domain its own batch.
> CCO feeds **two** domains — Account and Contract — and therefore has two Zone2 batches.
> A batch is looked up at runtime by exactly these four columns plus `is_active = 'Y'`.

Zone 2 has **two application layers**: **Data Domain** and a second layer usually called
**Functional / Functional Area**. Every asset built so far sits in Data Domain only; nobody in the
KTs was certain of the second layer's exact name, and no work had been done on it.

**A batch is an umbrella of jobs. One job = one target table load.** A batch with 20 tables has 20
rows in `job_metadata`.

Three identifiers are easy to confuse, and the distinction matters everywhere:

| Identifier | What it is | When it changes |
|---|---|---|
| **`batch_run_id`** | Primary key of `batch_run_stats`, a UUID | **New on every insert**, including every restart insert |
| **`execution_run_id`** | The thread that ties an entire run together | **New for a new run or a rerun; REUSED across a restart** |
| **`job_run_id`** | Primary key of `job_run_stats`, a UUID | New per job run; **reused on restart** when the execution_run_id matches |

> *"This execution_run_id is the only parameter you should always hold on to when you have to relate
> throughout the process. Every single table in your entire runtime tables is stacked with this
> execution_run_id."*

Worked example: a run fails carrying execution_run_id 123 → its restart is also 123. The next day
succeeds as 456. Later 678 fails → its restart is also 678. Each of those inserts gets its own new
`batch_run_id`.

### The two families of tables

- **Metadata tables** (static, shown in **red** in the data model) — hand-populated before anything
  runs: `batch_metadata`, `job_metadata`, `etl_data_ingestion_metadata`, `job_rule_master`,
  `job_rule_assignment`, `balance_reconciliation_metadata`, plus the batch-prerequisite config table.
- **Runtime tables** (shown in **green**) — written automatically by the framework:
  `batch_run_stats`, `batch_sourcing_stats` (new, Sept 2026), `job_run_stats`,
  `etl_data_ingestion_source_window`, `job_error_stats`, `job_rule_execution_log`,
  `job_rule_error_detail`, `balance_reconciliation_stats`, and the Snowflake-only RA tables.

All PK/FK relationships are wired in the data model; FKs are enforced (which is why the unit-test
mock data must be inserted parent-first — see §9, Phase 3).

File-related ABC tables exist in the shared model but **Zone2/Zone3 do not use them**.

### Zone 1 versus Zone 2 — same tables, different frameworks

Zone 1 and Zone 2 **share the same physical ABC tables in Aurora**, but run **different frameworks**.
Zone 1 uses only about five of them — `batch_metadata`, `job_metadata`, `batch_run_stats`,
`job_run_stats`, `job_error_stats`. Zone 2 uses almost all of them except the file-related ones.

Two consequences that bite repeatedly:

1. **Zone 1 writes two rows per run** (one at preload, one at post load) sharing the same
   `execution_run_id` and `instance_id`, whereas Zone 2 inserts once and updates. Zone 2 therefore
   reads Zone 1's runtime data through **consolidating views**, not the base tables:
   `batch_run_stats_raw`, `job_run_stats_raw`, `job_error_stats_raw`.
2. **Zone 1 creates FOUR job_ids per table.** Only one of them matters to ABC — see Phase 3.

### Status vocabulary

| Table | Permitted statuses |
|---|---|
| Zone 2 `batch_run_stats` | Started · Completed · Failed |
| Zone 2 `job_run_stats` | Started · Completed · Failed |
| **Zone 1 batch** | Started · Completed · Failed · **Partial** |
| **Zone 1 job** | Completed · Failed — **never Partial** |

**Partial** means some jobs in the Zone 1 batch completed and some failed. Zone 2 is allowed to start
when the Zone 1 batch is **Completed *or* Partial** — and then checks each individual source job
itself. This single fact is the reason `etl_data_ingestion_source_window` exists at all.

### Time zones

Everything ABC touches is **UTC**.

- At project start the estate was fragmented: business data in EST, Snowflake in PST, Zone1 ABC in
  UTC. UTC was chosen **because Zone1's existing ABC and Aurora were already UTC**, and the Snowflake
  account in use was switched to UTC.
- **Rule**: every audit and extraction column — in the ABC tables *and* in the Zone2 target tables —
  is UTC. Aurora's `CURRENT_TIMESTAMP AT TIME ZONE UTC` is used throughout.
- **Business data date fields keep their native source time zone. No conversion.** Business signed
  off: source systems (HR, producer, DLCC, …) send what they send and are not normalised.
- **Extraction logic is therefore always built on the AUDIT fields of the Iceberg/Snowflake tables,
  never on business data fields.** Because extraction is driven by the ABC tables and those are UTC,
  the mismatch never surfaces.
- **AWS / S3 / Glue-managed Iceberg = UTC. IDMC and Teradata run in EST.**
- For the history load the **DMigrator** process adds an extra column carrying the **UTC timestamp of
  when the Teradata data landed**, so Zone2 extraction has a UTC column to key off.
- USRM data's time zone was still unknown and needed a conformance check; data-share handling was
  tracked as a separate open discussion.

---

## 2. The physical landscape

| Thing | Where | Role |
|---|---|---|
| **Aurora** (AWS-managed, Postgres-compatible) | AWS | **System of record for every ABC control/metadata/runtime table** |
| **Snowflake** | — | Holds the actual Zone2 business/target tables, plus a handful of **temporary** ABC tables and the **RA** tables |
| **S3 + Snowflake-managed Iceberg** | AWS | Zone1's landing zone; Zone1 drops files into S3, Iceberg tables point at them |
| **IDMC / Informatica (IICS)** | — | Where all ABC mappings and task flows are built |
| **Stonebranch** | — | The scheduler. Holds the Zone1→Zone2 dependency and the prerequisite→batch dependency |
| **Teradata** | — | Current-state target; **becomes the SOURCE for the historical load** |
| **DMigrator** | — | Moves Teradata → Zone1 for historical/catchup. **Outside ABC's scope** |

**Why ABC lives in Aurora at all**, given Zone2's targets are in Snowflake: Zone 1's pipeline is
AWS-native (Lambda, Glue), so Zone 1's ABC tables were already in Aurora. **Zone 2 was directed to
reuse the very same ABC tables.** Everything downstream — the Snowflake temp tables, the dual writes —
follows from that decision.

Today all ABC tables sit in one shared **`default` database** with an `ABC` schema. A dedicated
Aurora ABC database, created via **Liquibase**, was planned but never delivered (see §16).

---

## 3. Why full push-down optimization dictates the design

> *"If we have source and target tables from different databases, full PDO doesn't work. In order to
> enable full PDO we're trying to make that database same. That is the reason why we have created
> some temporary ABC tables in Snowflake."*

Full PDO pushes the entire load into the database engine. It requires source and target to be in the
**same** engine. Zone2's targets are Snowflake; the ABC tables are Aurora. So during **job load**, ABC
writes to **Snowflake temp copies**, and **job post load** explicitly reads those temps and writes the
real rows back into Aurora. This is a deliberate, coded write-back step — not an automatic mirror.

Two further consequences of PDO that appear later in the chain:

- **PDO is all-or-nothing.** Either every record loads or none does — there is no partial stage load.
  This is precisely why a **stage table row count > 0 is trusted as proof** that the previous run's
  stage load completed (Phase 3, step 5).
- **Full PDO does NOT work for the stage→target hop**, because that statement is a `MERGE` rather than
  a plain `SELECT`. Full PDO is enabled in the setting, but the **"create temporary view" option had
  to be unticked** — it errored.

### Which ABC table is written where

| Table | Aurora | Snowflake | Nature of the Snowflake copy |
|---|---|---|---|
| `job_run_stats` | ✅ system of record | ✅ temp | Cleared per job_id each run; holds only `source_record_count` + `target_unchanged_record_count` |
| `job_rule_error_detail` | ✅ **permanent** | ✅ temp **and ✅ permanent** | The only table permanent in **both** databases; **no pre-delete** — rows accumulate |
| `balance_reconciliation_stats` | ✅ | ✅ temp | Holds only `source_aggregate_text`; cleared per job_id |
| `etl_data_ingestion_source_window` | ✅ | ✅ | **Dual-written** — the job-load source-qualifier query joins it in Snowflake to get the window |
| `job_rule_execution_log` | ✅ | ❌ **none** | No Snowflake counterpart at all |
| **RA temp** and **main RA** | ❌ **none** | ✅ ✅ | **Snowflake only — no Aurora equivalent** |
| `batch_run_stats`, `batch_sourcing_stats`, `job_error_stats`, all metadata tables | ✅ | ❌ | Aurora only |

**Target state (not built)**: each Snowflake business domain gets its own dedicated `ABC` schema
holding the temp and RA tables. Today everything points at one shared testing schema.

---

# Before the chain can run — the setup

Nothing in §9 happens until these four setup steps are done. They are themselves sequential: the
metadata rows come first because the IDMC components read them, and the parameter file comes last
because it names objects created in the earlier steps.

## 4. Step S1 — Populate the metadata tables, in dependency order

All metadata rows are inserted **manually by DML today**. The long-term plan is **Liquibase**-managed
DML once the dedicated Aurora ABC database exists — *"once we are pointing to the new database built
through Liquibase, all the DML process should happen through Liquibase only."*

**The DML generation convention**: an Excel workbook holds the insert templates with **CONCAT
formulas** that build the `INSERT` statements. It was first built for CCO and is reusable by everyone.
Its central rule:

> **No primary key is ever hard-coded.** Every foreign key is resolved by a sub-query against its
> parent metadata table — `batch_id` from `batch_metadata` by source/domain/layer/zone, `job_id` from
> `job_metadata` by job_name + batch_id, `rule_id` from `job_rule_master` by rule_name + rule_scope.
> This makes the same DML valid in **every environment**, since the auto-increment values differ.
> The database name is not even referenced — only the schema name.

Insert in this order:

### S1.1 — `batch_metadata` (one row per batch)

| Column | Notes |
|---|---|
| `batch_id` | **Auto-increment — do not supply it** |
| `batch_name` | Convention `Z2_BATCH_<SOURCE>_<DOMAIN>`, e.g. `Z2_BATCH_CMPM_BROKER`. ⚠️ Flagged as not final — pending agreement with Nithika |
| `batch_description` | "Batch to load data from `<source>` to `<domain>` Data Domain layer" |
| `is_active` | **Drives the runtime lookup.** `'N'` → the batch_id lookup returns nothing → no `batch_run_stats` row → no job runs at all. It does not error; it silently does nothing |
| `email_id` | Populated but **not actually wired into notifications** — "we are not using it directly anywhere, just providing it as of now" |
| `source_name` | The Zone1 source, e.g. CMPM, CCO |
| `domain_name` | e.g. Broker, Account, Contract |
| `application_name` | **NULL for Zone2/Zone3** — a Zone1 field |
| `application_layer_name` | `Data Domain` or `Functional` |
| `application_dependency_name` | The batch this one depends on. Today == `source_name`, because only one source and one dependency are supported. It *could* name another Zone2 batch, but **"the logic is not supporting currently"** |
| `application_source_batch_id` | **The Zone1 batch_id.** How to find it: §9 Phase 3 sidebar |
| `target_zone` | `Zone2` or `Zone3` |
| `load_frequency` | daily / weekly / monthly, per the source system |
| scheduling mechanism, `load_schedule_time`, `load_expected_completion_time` | **Dummy values today**; to be replaced once Stonebranch jobs are created |
| 4 audit columns | `CURRENT_TIMESTAMP AT TIME ZONE UTC`; user id = mail ID or `CURRENT_USER` (which returns a token number — accepted for now) |
| `KRS` / "key args" | Zone1-only; NULL for Zone2/Zone3 |

### S1.2 — `job_metadata` (one row per target table)

| Column | Notes |
|---|---|
| `job_id` | Auto-increment |
| `job_name` | `Z2_JOB_<SOURCE>_<DOMAIN>_<TABLE>_LOAD`. ⚠️ **Be very careful here** — the framework looks up job_id by this string |
| `job_description` | "Job to load `<table>` from `<source>` in `<domain>` Data Domain" |
| `is_active` | **Operationally meaningful**: set `'N'` to exclude a table from a batch run, or permanently when a table is de-scoped |
| `batch_id` | FK |
| `table_name`, `schema_name`, `database_name` | The **target**. ⚠️ Duplicated here even though the mappings are parameterised, because **job post load reads them to compute the target counts**. If you change the parameter file's database/schema, you must change these too |
| `target_load_type` | type 0 / type 1 / **type 2** / append only. Everything built so far is **SCD Type 2**, plus ~3 static tables |
| `workflow_name` | The **job-level** task flow: `TSKFL_LOAD_<TARGET_DOMAIN>_<TABLE>` |
| `wrapper_workflow_name` | The **batch-level** task flow: `TSKFL_LOAD_<TARGET_DOMAIN>_<SOURCE_DOMAIN>_TO_<TARGET_ZONE>_<APPLICATION_LAYER>_BATCH` |
| `count_threshold_indicator` | `'Y'` if any **count** balance metric exists |
| `amount_balance_check_indicator` | `'Y'` if any **amount** balance metric exists |
| `source_to_target_layer` | `Refined to Zone2 Data Domain`. "Refined" was chosen because another Zone1 team calls Zone1 *Refined* (per Swayam). ⚠️ **Known inconsistency**: some CCO rows say `Zone1 to Zone2 Data Domain`; Aishwarya spotted this in KT 1 and said she would correct them |
| audit columns, `KRS` | as above |

⚠️ The two indicators are at **JOB level, not per column.** They are purely the framework's switch:
if both are `'N'`, the entire balance-reconciliation component is skipped in job post load.

### S1.3 — `etl_data_ingestion_metadata` (one row per SOURCE TABLE per job)

Columns: `target_batch_id`, `target_job_id`, `target_table_name`, `source_name`,
`source_table_name`, `is_active`, audit fields — **plus, added September 2026:** `database_name`,
`schema_name`, `source_object_name`, which exist to **uniquely identify a source table in
`job_metadata`**, because the same source table name can appear in multiple schemas or databases.

- A target with several source tables gets **several rows**. Real example: CCO's `agreement` target
  has **six** source tables → six rows.
- ⚠️ **The critical gotcha**: `source_table_name` must match **exactly how Zone 1 spelled it in THEIR
  `job_metadata`**, because that string is the join key. Observed in CCO: the real object is
  `CCO_DB_SCOOP1_SALES_REP_CODE`, but Zone1's job_metadata says `SALES_REP_CODE_T`. ABC must record
  `SALES_REP_CODE_T`. (`CCO_DB_SCOOP1` is an Iceberg prefix and is not part of the Zone1 entry.)
- ⚠️ Aishwarya's POC used one source table, and developers copied that pattern — **multi-source
  tables are being under-populated across the team** (see §16).

### S1.4 — `job_rule_master` (the global DQ catalogue)

A **distinct list of every DQ check across every batch and every job** — not per batch, not per job.

Columns: `rule_id` (auto-increment), `rule_name` (e.g. "null check"), `rule_scope` (e.g. `column`),
audit columns.

- A rule must exist here **before** it can be assigned anywhere. A null check is defined **once** and
  reused by every job in every asset.
- Nothing prevents duplicate rows — *"I don't think it will give you an error, but it is not good
  practice"*. Always check first. The FK from `job_rule_assignment.rule_id` **will** reject a rule_id
  that does not exist here.
- ⚠️ **Only the null check has ever been inserted.** Across ADW, Producer and CCO, no other check type
  has been needed. Other examples discussed: date format check, length check.

### S1.5 — `job_rule_assignment` (assign a master rule to a job's column)

| Column | Notes |
|---|---|
| `job_rule_assignment_id` | Auto-increment |
| `job_id`, `rule_id` | FKs |
| `validation_type` | `'PRE'` (DQ runs before the target load). **Informational only — the code does not read it** |
| `target_column_name` | The column the check applies to |
| `pattern_available`, `pattern` | **Not used.** Kept `'N'`. Aishwarya speculated an expression could be stored here and reused in the ETL, or used for date patterns — explicitly unresolved |
| `error_severity_code` | **`CRITICAL` / `C`** or **`INFORMATIONAL` / `I`** — the single most consequential value in the table |
| `error_message_text` | Free text, e.g. "Null values found". ⚠️ No template exists for other check types; the convention would have to be decided |
| `is_active` | ⚠️ **See the warning below** |
| audit columns | |

- One row **per column**. Five columns needing a null check on one table = five rows. Real example:
  CCO `agreement_rating_plan` has checks on 2 columns → 2 rows; CCO `account_party_address` has 3.

> ### ⚠️ The `is_active` asymmetry — the single most dangerous trap in the framework
>
> **`is_active` on `job_rule_assignment` is NOT honoured automatically.** DQ checks are **hand-coded
> inside the stage-load mapping**, so deactivating a rule here does nothing on its own.
>
> Worked example from KT 4: three critical null checks exist. You set `broker_party_id`'s rule to
> inactive but don't touch the mapping. A null still sets `critical_error_check = 'Y'`, the record is
> still routed to error and **still withheld from the target** — exactly the behaviour you were
> trying to stop.
>
> **You must edit the ETL logic as well.** This is written into the LLD as a note: *"If any critical
> validation rules are later deactivated in job_rule_assignment, the validation logic should be
> reviewed and updated to make sure the processing behaviour still matches the active rules."*
>
> By contrast, **`is_active` on `balance_reconciliation_metadata` IS honoured automatically** —
> deactivate there and nothing else changes, because that component is genuinely reusable.
>
> DQ rule discovery is **entirely manual, by deliberate decision**, per Nithika and Swayam's guidance.
> Automating DQ checks in the main mapping was raised by Aishwarya **multiple times** and **parked
> every time**.

### S1.6 — `balance_reconciliation_metadata` (one row per metric)

| Column | Notes |
|---|---|
| `balance_reconciliation_metric_id` | Auto-increment |
| `balance_reconciliation_metric`, `metric_description` | e.g. "reconcile distinct count of broker_party_identifier from Zone1 source to Zone2 target" |
| `balancing_type` | `AMOUNT` / `COUNT` / distinct count |
| `source_to_target_layer` | `Refined to Zone2 Data Domain` |
| `target_database_name`, `target_schema_name`, `target_table_name`, `target_column_name` | The column being reconciled |
| `region`, `source_path` | Zone1-related; unused |
| `source_query`, `target_query` | **Not used** — "we have already implemented the logic dynamically within the ETL itself" |
| `threshold_type_name` | `PERCENTAGE` or `VALUE` (the maths differs) |
| `threshold_value` | |
| `is_active` | **Honoured automatically by the code** |
| `job_id` | FK |

- Five metrics on five columns of one table = five rows. CCO `policy` has **seven**, all amount
  columns, threshold type `PERCENTAGE`, threshold value **5**.
- **Balance reconciliation is fundamentally about AMOUNT fields.** *"If $100 enters your system, your
  $100 should pass through your system — whether you filter, pass through, or aggregate. Count is not
  the balance. Balance is your amount. Just remember that as a thumb rule."* An exercise was running
  to enumerate every amount column across every job, table and wave, because the intent is that **all
  amount columns get reconciled**.
- **Rule of thumb**: if the future-state target table has an amount column, reconcile it — **even if
  the current-state code never did**. Anything already reconciled in current state must be
  reconciled in the new code.
- **The threshold is a business decision, not a technical one.** It depends on the business
  criticality of the column — for premium/loss/claim fields even a single unit matters. *"At least in
  this project we don't go with percentage"* (though CCO in practice uses 5%). The metadata supplies
  the threshold; the framework does the maths and the comparison.

### S1.7 — The batch-prerequisite config table

A separate config table gating the Zone1 readiness check. Columns: `target_batch_id` (the Zone2
batch), `source_batch_id` (the Zone1 batch), `source_name`, `domain_name`, `mandatory_time_check`
(an active flag), and **`dependency_batch_timestamp`** — a **cut-off time of day**.

At runtime the current date is concatenated with that time and the Zone1 source batch is checked for
Completed-or-Partial at or by that moment.

> Worked example: CMPM's Zone1 pipeline runs **four batches a day**. The Zone2 broker batch loads once,
> after the final Zone1 batch. If that finishes at 12:00 AM, `dependency_batch_timestamp` = 12:00, and
> the Zone2 batch is scheduled after it.

A POC was running to confirm **Stonebranch can read IICS/IDMC status**.

### S1.8 — `batch_sourcing_stats` (September 2026, one-time per source batch)

Introduced when the split described in §15 landed. **One row per (target batch, source batch) pair —
a one-time entry, not one per run.** See §15 for the columns and the worked CRC example.

---

## 5. Step S2 — Stand up the IDMC components for a domain

IDMC folder layout:

```
DAA_COMMON/
└── ABC/                    ← the master copies of every ABC component
    ├── ABC job preload (sub-task flow)
    ├── ABC job preload failure (sub-task flow)
    ├── ABC job post load success (sub-task flow)
    ├── ABC job post load failure (sub-task flow)
    ├── batch prerequisite (task flow)
    └── all the ABC mappings
<DOMAIN>/                   ← e.g. BROKER, ACCOUNT, CONTRACT, CLAIMS
├── ABC/                    ← the domain's own COPY of everything above
├── STAGE/
├── MAIN/
└── (MVP/ for some domains)
```

**Client requirement: ABC components must exist under each and every domain folder.**
⚠️ **The batch-level and job-level task flows are NOT in DAA_COMMON** — they must be copied from a
domain that already has them and then modified.

### The procedure, in order

1. **Copy all ABC components** from `DAA_COMMON/ABC` into the domain's own `ABC` folder.
2. **Update the Snowflake connection name** in every component that has one. The common folder ships
   a generic name (e.g. `CONN_ABC_SNOWFLAKE`); the standard is **`CONN_TGT_<DOMAIN>`**
   (`CONN_TGT_BROKER`, `CONN_TGT_CLAIMS`, …). Roughly **6–7 components** carry one. Done **manually**,
   one at a time. Requirement: **all ABC components AND the stage-load and target-load mappings must
   use a single Snowflake connection.** Connection creation itself is owned by Gayathri.
3. **Batch prerequisite task flow**: it deliberately lives in the **common** folder (its structure —
   one mapping, a decision, notifications — never varies). Copy/move it into the domain's **MAIN**
   folder, rename it, and set its two input fields: parameter file directory and parameter file name.
4. **Batch-level and job-level task flows**: copy them from an existing domain.
   > ⚠️ **CRITICAL GOTCHA.** When you copy a task flow from another domain, every sub-task flow and
   > component inside still points at **that domain's** ABC components. You must **manually repoint
   > every one** at your own domain's ABC folder and re-supply all input fields. Do this once for your
   > first table; from then on copy *within* your own domain.
5. **IDMC setting**: on both the batch prerequisite and the batch task flow, select
   **"disable concurrent execution"**.
6. **When a common component changes**, the team is notified by **mail** and must re-copy it and
   re-apply the connection change. **There is no automatic propagation.**

> ⚠️ **There is no check-out / check-in process.** Multiple teams edit the same task flows
> simultaneously and things get changed without notice. When asked for a reference task flow,
> Aishwarya could only offer one (account) that she believed was currently valid and untouched.

### The config-driven / simplified variant

For a **config table** load — no DQ checks, no balance reconciliation, truncate-and-reload, no stage
table — the job task flow collapses to:

- a single **job preload mapping task** instead of the full ABC job preload sub-task flow (no source
  window is needed for truncate-and-reload, no `job_rule_execution_log` load, no stage-load skip, no
  restart cleanup);
- a notification task under a Throw step on failure;
- **the skip Decision task is still needed** — a restart must still skip an already-completed job;
- a fully parameterised 1-to-1 loader mapping;
- on failure, reuse just the `job_run_stats_post_load_failure` mapping task;
- job post load success collapses to that same mapping task plus a notification — no RA, no error
  detail, no balance.

---

## 6. Step S3 — Write the parameter file

One **static parameter file per domain**, organised into a global section and per-component sections.

### GLOBAL

| Parameter | Notes |
|---|---|
| ABC **Aurora** connection name | |
| **Snowflake** connection name | `CONN_TGT_<DOMAIN>` |
| ABC connection name, **ABC database name**, **ABC schema name** | The last two are the **Snowflake** ABC ones |
| stage table name / object | |
| **RA temp table** (3 params) and **main RA table** (3 params) | Parameterised because the names weren't settled at build time |
| `source_name`, `domain_name`, `target_zone`, `application_layer_name` | **The four keys that fetch the batch** |
| `source_zone` | e.g. `ZONE1 STAGE 2` — Zone1's layer holding the Snowflake Iceberg tables. Used in notifications. Can change per table and per wave: all Wave-1 assets source from Zone1 Stage 2, but for Wave 2/3 the source zone could become Zone2. Confirm with Swayam or Gayathri |
| `source_system_code` | Written into the target table |
| **the RERUN `execution_run_id`** | The batch run to rewind to. Set to **`'NA'`** for a normal run; updated **manually** when a Zone2 rerun is required |

### `job_preload`

| Parameter | Notes |
|---|---|
| **`DQ_CHECK_INDICATOR`** | **Mandatory.** `'Y'` only if DQ checks are actually assigned. Drives the Decision that skips all DQ steps |
| `job_name` | Used to fetch job_id |
| target object, stage table object, stage table name | For the target-cleanup and stage-count mappings (both write to dummy targets, so these are partly defensive) |
| `error_type` / `error_code` / `error_message` — **NETWORK error** | For the restart case where the previous run is stuck in 'Started' |
| `error_type` / `error_code` / `error_message` — **SOURCE TABLE LOAD FAILED** | |

### `job_post_load_success`

| Parameter | Notes |
|---|---|
| **`TARGET_EXPRESSION`** | The balance-reconciliation target aggregation expression, injected verbatim into the SELECT clause |
| **`TARGET_BALANCE_RECON_FILTER`** | The WHERE clause. **Set to `1=1`** — see Phase 5 |
| `RECORD_COUNT_BALANCING` error type/code/message | For `record_count_balancing_flag = 'N'` |
| error type/code/message for **every other failure combination** | "All the combinations of failures are jotted down and used separately based upon the scenario" |

### `job_post_load_failure` and `job_preload_failure`
Their own error type / error code / error message parameters.

### Plus mapping-task-level parameters bound to the source queries.

**Notes on the error parameters**: they must be supplied for **every table on every run**, because
they cannot be assigned at task-flow level. Only the network-error set is restart-specific — every
other error scenario can occur in a perfectly normal run. **The error strings never change between
tables**; the dynamic parts (job_id, job_run_id, batch name, job name) are injected by the mapping
logic. The client asked for these messages to live in the parameter file rather than be hard-coded.

### September 2026 additions
Two new job-task-flow input fields, **`batch_run_id`** and **`batch_type`**, replacing three removed
ones. See §15.

---

## 7. Step S4 — Hand-build the per-table ABC logic inside the mappings

Three things are **not** generated by the framework and must be written by hand into the
**source→stage mapping** of each table. This is the integration effort the design goal refers to.

1. **The DQ `error_description` expression** — with the `rule_id` and severity code **hard-coded**
   per check (§9, Phase 4).
2. **The `critical_error_check` / `validation_flag` expressions** — listing the critical columns.
3. **The balance-reconciliation source flow** — sorter/aggregator per metric, plus the
   `source_aggregate_text` expression.

Everything else — the job preload, post load, failure, RA and balance components — is reusable and
parameterised.

**Conditional build advice**: every table gets the `job_run_stats` temp flow; build the DQ flow only
if the table has DQ checks; build the balance flow only if it has reconciliation metrics.

---

# The chain

## 8. The chain at a glance

```
        STONEBRANCH
            │  hard dependency: Zone1 job must complete
            ▼
┌─────────────────────────────────────────────────────────────┐
│ PHASE 1 · BATCH PRELOAD PREREQUISITE        (own task flow)  │
│   Is the LATEST ZONE 2 batch run Completed?                  │
│   NO  → notify + FAIL → batch task flow never starts         │
│   YES → succeed → Stonebranch triggers the batch task flow   │
└─────────────────────────────────────────────────────────────┘
            ▼
┌─────────────────────────────────────────────────────────────┐
│ PHASE 2 · BATCH PRELOAD                    (batch task flow) │
│   batch_metadata → batch_id                                  │
│   batch_run_stats → latest status + batch_rerun_flag         │
│   → decide EXECUTION TYPE, insert/update batch_run_stats     │
│   → emit batch_id, execution_run_id, execution_type          │
└─────────────────────────────────────────────────────────────┘
            ▼   (for each job, in orchestration run order)
┌─────────────────────────────────────────────────────────────┐
│ PHASE 3 · JOB PRELOAD                        (job task flow) │
│   1. job_metadata → job_id             → job_run_stats row   │
│   2. etl_data_ingestion_source_window  → the sourcing window │
│   3. job_rule_execution_log rows       (if DQ)               │
│   4. target cleanup                    (restart only)        │
│   5. stage table record count          (restart only)        │
│   ── SKIP the whole job if restart + already Completed ──    │
│   ── FAIL the job if any Zone1 source job Failed ──          │
└─────────────────────────────────────────────────────────────┘
            ▼
┌─────────────────────────────────────────────────────────────┐
│ PHASE 4 · JOB LOAD                              (2 mappings) │
│   stage count > 0 ? ──yes──► skip to stage→target            │
│   source→stage  [ALL ABC integration lives here]             │
│     ├─ counts          → job_run_stats TEMP    (Snowflake)   │
│     ├─ DQ checks       → job_rule_error_detail TEMP          │
│     ├─ balance source  → balance_reconciliation TEMP         │
│     ├─ RA records      → RA TEMP                             │
│     └─ valid records   → STAGE table                         │
│   stage→target  (SQL MERGE; no ABC logic)                    │
└─────────────────────────────────────────────────────────────┘
            ▼
┌─────────────────────────────────────────────────────────────┐
│ PHASE 5 · JOB POST LOAD                                      │
│   1. RA temp → MAIN RA  (+ mark process_flag='Y')            │
│   2. error detail temp → job_rule_error_detail (TRANSPOSE)   │
│   3. job_rule_execution_log → Passed / Failed                │
│   4. balance reconciliation: compute TARGET, compare         │
│   5. job_run_stats final counts + 4 flags + FINAL STATUS     │
└─────────────────────────────────────────────────────────────┘
            ▼   (after every job)
┌─────────────────────────────────────────────────────────────┐
│ PHASE 6 · BATCH POST LOAD                                    │
│   error_count = 0 ? → batch_run_stats Completed / Failed     │
└─────────────────────────────────────────────────────────────┘
```

---

## 9. Phase by phase — the full sequence

### Phase 0 — Scheduler trigger and the Zone1 dependency

**Where it runs**: Stonebranch.

Stonebranch holds two separate dependencies, both outside IDMC:

1. **Zone1 job → Zone2 job.** A hard dependency: if the Zone1 Stonebranch job fails, the Zone2
   Stonebranch job is never triggered.
2. **Zone2 batch prerequisite task flow → Zone2 batch task flow.** Also hard: if the first fails, the
   second never starts, and a manual trigger is required.

The Zone2 batch is scheduled per its own `load_frequency` and schedule time. Zone1 loads their batch
**at least four times a day** (stage-2 jobs).

> For detail on how the two task flows are wired at the scheduler level, the POCs are **Deepankar**
> and **Durkesh**.

---

### Phase 1 — Batch preload prerequisite

**Where it runs**: its own IDMC **main** task flow — *not* a sub-task flow, and not part of the batch
task flow.

**What it asks**: *is the LATEST **Zone 2** batch run Completed?*

> ⚠️ This was asked explicitly in the design session and answered unambiguously: the check is on the
> **TARGET (Zone 2) batch entry, NOT the source batch.** The source is implicitly already done or
> Stonebranch would not have got this far.
>
> The reasoning: *"When I start my execution for my 10th day, my 9th-day batch should have completed
> properly. If it has not, something is messed up — I should not go ahead and corrupt the system more
> by executing the 10th-day batch. Let me fix the 9th-day batch first."*

**Mechanics** — one mapping task, two CTEs:

1. `batch_metadata` filtered on `source_name + domain_name + application_layer_name + target_zone +
   is_active='Y'` → `batch_id`, `application_source_batch_id`.
2. `batch_run_stats` for that batch_id, `ORDER BY ... DESC`, take the latest → `status`,
   `batch_run_id`.

An expression sets an output parameter **`skip_flag`**:

```
IF status IN ('Started','Failed') THEN 'Y' ELSE 'N'
```

> ⚠️ **Naming confusion, raised in the session.** `'Y'` means *the batch run is to be SKIPPED* — i.e.
> do **not** proceed. *"We are skipping the batch run."* It does not mean "OK to go".

Two extra transformations exist purely to satisfy an **IICS standard requiring a target in every
mapping** — a filter with a FALSE condition writing to a dummy target. They never write anything.

A Decision on `skip_flag`:

- **`'Y'`** → send a notification and **FAIL** the task flow. Body:
  > *"The latest batch run has not been completed successfully. Please check the batch status and
  > rerun the task flow once the batch is completed successfully."*
- **`'N'`** (status Completed) → End; the task flow succeeds; Stonebranch triggers the batch task flow.

**Generic across zones**: the `target_zone` parameter means the same task flow checks the latest Zone3
batch status for a Zone3 load.

**Recovery after a prerequisite failure** — the team chooses, per situation:

- (a) fix the underlying problem, **manually set the latest batch status to Completed**, then
  re-trigger the **prerequisite** task flow; or
- (b) bypass it and trigger the **batch task flow directly** — the code then reads the failed latest
  run as a **restart**.

⚠️ Aishwarya flagged this choice as needing confirmation from Swayam.

**The prerequisite is NOT evaluated for**: restart, Zone2 rerun, Zone1 rerun, and (Aishwarya's belief,
to be confirmed with Swayam) historical, catchup and first-time incremental. For all of these the
Zone2 batch task flow is triggered directly.

⚠️ **Known gap**: on an *execution* error the prerequisite task flow currently just fails without
sending a mail. *"If I upgrade this, I'll send out a mail."*

---

### Phase 2 — Batch preload

**Where it runs**: the first mapping task inside the **batch task flow**.

**What it does**, per the LLD: *"creates a SINGLE RECORD in the `batch_run_stats` table at the start of
the batch execution."*

**Batch task flow setup at this point**:
- Start-step input fields: parameter file directory, parameter file name, `audit_user_id` (the service
  account, via an IDMC built-in function), batch task flow name. Directory and file name are
  hard-coded; these values are then passed down into every job task flow.
- Temp variables declared: **`error_count`** (initial 0) and **`batch_status`** (initial NULL).

**Inputs** (all from the static parameter file): `source_name`, `domain_name`, `target_zone`,
`application_layer_name`, `abc_database_name`, `abc_schema_name`, `audit_user_id`.

#### The source query — three CTEs

1. **Batch details** — `batch_metadata` by the four keys + `is_active='Y'` →
   `batch_id`, `application_source_batch_id` (the Zone1 batch_id), `batch_name`.
   *Exactly one row must come back.*
2. **Previous/latest TARGET run** — `batch_run_stats` for that batch_id, latest row → previous
   `batch_run_id`, `execution_run_id`, `status`, `batch_rerun_flag`, `sourcing_start_time`,
   `sourcing_end_time`.
3. **Latest SOURCE run** — `batch_run_stats` for `application_source_batch_id`, **filtered on
   `status IN ('Completed','Partial')`**, latest row → source `execution_run_id`, source
   `batch_end_time`.

> ⚠️ Note the **asymmetry**: for the **target** batch we take the latest run *whatever its status*;
> for the **source** batch we take the latest **Completed-or-Partial** run.

The final SELECT left-joins all three, and adds audit columns via
`CURRENT_TIMESTAMP AT TIME ZONE UTC` plus `GEN_RANDOM_UUID()` (the Aurora/Postgres function) to mint a
new `execution_run_id` / `batch_run_id` when one is needed.

#### The decision tree

```
batch_rerun_flag = 'N' ?
├── YES
│   ├── previous status = Completed (or NULL) → NEW / regular
│   │     insert: NEW execution_run_id, status 'Started', rerun flag 'N'
│   │     sourcing_start = previous run's sourcing_END
│   │     sourcing_end   = latest Zone1 batch_end_time (Completed or Partial)
│   │     execution_type = NEW
│   ├── previous status = Failed → RESTART
│   │     insert: SAME execution_run_id, same sourcing start/end, 'Started'
│   │     execution_type = RESTART
│   └── previous status = Started → RESTART (abrupt/network death)
│         FIRST update that stale row to 'Failed'
│         THEN insert: SAME execution_run_id, same sourcing start/end, 'Started'
│         execution_type = RESTART
└── NO  → the row was already created MANUALLY. Batch preload makes NO entry and NO change.
    'Y' → execution_type = RERUN          (Zone 2 rerun)
    'Z' → execution_type = ZONE 1 RERUN
    'H' → historical      ┐
    'C' → catchup         ├─ NOT IMPLEMENTED
    'I' → first-time incremental ("Zone 2 First Time Incremental")  ┘
```

#### Expression transformation outputs

| Output | Logic |
|---|---|
| `insert_flag` | **0** when previous status = 'Started' AND `batch_rerun_flag IN ('Y','Z')` — because those rows are created manually. Otherwise 1 |
| `insert_status` | Hard-coded **`'Started'`** |
| `insert_execution_run_id` | previous status IS NULL **or** 'Completed' → a **new** UUID; else the **previous** execution_run_id |
| rerun flag on the inserted row | `'N'` (both for a new run and for a restart) |
| `update_flag` | previous status = 'Started' **AND** previous rerun flag = 'N' — the abrupt-death case |
| `update_status` | Hard-coded **`'Failed'`** |
| `sourcing_start_time` | status IS NULL → the low-end date; previous status = 'Completed' → previous **sourcing_END**; else → previous **sourcing_START** (restart keeps the same window) |
| `sourcing_end_time` | NEW/regular → the **source (Zone1) batch_end_time**; else → previous sourcing_end_time |
| `execution_type` | rerun flag `'Y'`→RERUN · `'Z'`→ZONE 1 RERUN · previous status NULL/Completed→NEW · previous status Started/Failed→RESTART |

Also set as variables and passed downstream: `execution_run_id`, `batch_id`,
`source_batch_end_time`, `source_execution_run_id`, `source_batch_id`.

A **Router** with two output groups — `insert_flag = 1` and `update_flag = 1`. The UPDATE path targets
the **previous** `batch_run_id` and sets `batch_end_time`, `status = 'Failed'`,
`audit_updated_datetime`, `audit_updated_by_user_id`.

**Emitted to Phase 3**: `batch_id`, `execution_run_id`, `execution_type`, `batch_name`,
`source_batch_id`, `source_execution_run_id`, `source_batch_end_time`, the parameter file
coordinates and `audit_user_id`.
*(September 2026: `source_batch_id`, `source_execution_run_id` and `source_batch_end_time` are
replaced by `batch_run_id` and `batch_type` — see §15.)*

If this mapping task fails on an execution error, a notification is sent and the batch task flow is
failed.

---

### Phase 3 — Job preload

**Where it runs**: the **ABC job preload** sub-task flow, the first component of the **job task flow**.
Runs once per job; the job task flows are arranged in the batch task flow **in run order per the
orchestration design**.

Job task flow Start-step inputs: `batch_id`, `execution_run_id`, `batch_name`, `execution_type`,
`source_batch_id`, `source_execution_run_id`, `source_batch_end_time`, parameter file directory,
parameter file name. Plus `job_name` and `stage_table_record_count` (initialised to **0** — also the
value used for tables that have no stage table at all).

Job preload performs **five steps**:

#### Step 3.1 — `job_run_stats` preload

Source query joins `job_metadata` and `job_run_stats`:

- From **`job_metadata`**, filtered by `batch_id + job_name + is_active = 'Y'`: `job_id`,
  `table_name`, `schema_name`, `database_name`, `load_type`, `count_threshold_indicator`,
  `amount_balance_check_indicator`.
- From **`job_run_stats`**, looked up by `job_id` **AND `execution_run_id`**: `previous_job_run_id`,
  `previous_status`, `previous_execution_run_id`.
  > The `execution_run_id` filter matters: previous-run details are only needed for a **restart**;
  > for new/rerun/Zone1-rerun they are irrelevant.
- Plus audit values and a fresh UUID for a new `job_run_id` / `job_error_id`.

**The restart decision table** — the heart of the phase:

| execution_type | previous status | Action |
|---|---|---|
| RESTART | **Completed** | **SKIP the entire job.** `skip_flag = 'Y'` → the task flow Decision goes straight to End. **No entries whatsoever** — no source window, no execution log, no error stats |
| RESTART | **NULL** (no prior row) | Insert a new row |
| RESTART | **Failed** | **UPDATE** that same row's status back to `'Started'` — reuse the row, do not insert |
| RESTART | **Started** | Treat as an **interrupted run**: reuse the existing row, **AND insert a row into `job_error_stats`** logging that the earlier run was interrupted by an abrupt/network failure |
| NEW / RERUN / ZONE1 RERUN (and, expected, H / C / I) | — | Insert a brand-new row: new `job_run_id`, status `'Started'`, current UTC timestamp. All of these carry a fresh `execution_run_id` so the handling is identical |

> **Why the `job_error_stats` row for the 'Started' case**: when a run dies abruptly, nothing gets the
> chance to mark it Failed or log the error. That log entry is written retrospectively, on the next
> restart, using the NETWORK error type/code/message from the parameter file.
>
> ⚠️ It does **not** mark the old `job_run_stats` row Failed — the row is reused as-is.

**Expression outputs**: `insert_status` (`'Started'`), `insert_flag` (1 for NEW/RERUN/ZONE1 RERUN,
and also for RESTART when no prior row exists), `update_flag` (RESTART + previous Failed),
`skip_flag` (RESTART + previous Completed), a **restart-previous-status-started** flag,
and `job_run_id` — **reuse the previous `job_run_id` when execution_type = RESTART and the previous
execution_run_id equals the current one**, otherwise mint a new UUID.

**Router with 3 output groups**: insert · update · restart-previous-started (→ `job_error_stats`).

**Contrast worth holding on to**: in a **RERUN**, previous status Completed but execution_run_id
**different** → the job **must** be reloaded. In a **RESTART**, previous status Completed and
execution_run_id **the same** → skip.

⚠️ If **this** mapping fails, the notification is sent from inside the sub-task flow and the whole job
task flow fails immediately. If any **other** job-preload component fails, the task flow sets
`preload_status_flag = 'N'` and routes to the **ABC job preload failure** sub-task flow instead.

#### Step 3.2 — `etl_data_ingestion_source_window`

This is the most intricate part of the framework. It exists because of one fact: **Zone 2 may start
when the Zone 1 batch is Partial**, so the window must be computed **per source table**, from each
source job's own end time — not once per batch.

> *"Your sourcing_start_datetime is the previously completed sourcing_end_datetime. Your
> sourcing_end_datetime is Zone1's latest job_end_time."*
>
> A relationship table with two source tables may have one ending at 10:31 PM and the other at
> 10:35 PM. Each gets its own range. **Consequence, confirmed on a direct question: the source
> qualifier query must contain multiple window lookups, one per source table.** *"Yes, that is how it
> is happening today."*

**Four components** implement this.

##### 3.2a — The "preload check" mapping *(restart path only)*

- CTE 1: `etl_data_ingestion_metadata` by `batch_id + job_id + is_active='Y'` → **how many source
  tables this job should have**.
- CTE 2: `etl_data_ingestion_source_window` by `batch_id + job_id + current job_run_id` → **how many
  rows already exist**.
- Compare, and set a flag:
  - no rows → **LOAD**
  - counts equal → **SKIP** (the previous run already wrote every source table's row)
  - counts differ (**a partial load**) → **DELETE AND LOAD**
- Dummy target + FALSE-condition filter; writes nothing.

##### 3.2b — The delete mapping
Dummy source, FALSE-condition filter, and the real work in the **target transformation's PRE-SQL
command**: delete from `etl_data_ingestion_source_window` by the current `job_run_id`. Only fires on
the DELETE-AND-LOAD path.

##### 3.2c — The main source-window mapping — **NEW, RESTART, ZONE1 RERUN**

Source query CTEs:

1. **Metadata** — `etl_data_ingestion_metadata` by `batch_id + job_id + is_active='Y'` →
   `target_batch_id`, `target_job_id`, `target_table_name`, `source_table_name`.
2. **Source jobs** — `job_metadata` by `source_batch_id + source_table_name + is_active='Y'` →
   the source `job_id`**s** and the source **`job_name`**.
   > **Why plural: Zone 1 creates FOUR job_ids per table**, for four different purposes.
3. **Latest source run** — from Zone 1's runtime **view**, restricted to runs whose `job_end_time`
   is **`<= source_batch_end_time`**, then
   `ROW_NUMBER() OVER (PARTITION BY source_table_name ORDER BY ...)` keeping `RN = 1`.
   > ⚠️ **The partition is by SOURCE TABLE NAME, not by source job_id** — deliberately stressed in the
   > session, precisely because there are four job_ids per table and only the single latest run across
   > all of them matters.
4. **Latest completed target run** — `job_run_stats` where `job_id` = the current Zone2 job_id and
   `status = 'Completed'`, ordered desc, `LIMIT 1`.
5. **Previous window** — `etl_data_ingestion_source_window` joined on that previous completed
   `job_run_id` → its `sourcing_end_datetime` **per source table**.

Final SELECT, per source table:

- **`source_job_run_id`** = the latest run's job_run_id.
- **The status rule** — mark **Completed ONLY IF** the latest run's status is Completed **AND** its
  `job_name` equals the hard-coded **"raw to current data movement"** job name.
  > That job is the **final step of Zone 1's load process** — the one that actually moves data from the
  > source system into the Zone1/Iceberg table. If the latest run belongs to any of the other three
  > job_ids, the data movement did not happen, so the source is treated as **FAILED**.
  >
  > The job name is **hard-coded** in the query. Confirmed with Swayam that Zone 1 always uses the
  > same job name for that step.
- **`sourcing_end_datetime`** = that run's `job_end_time` (only when Completed).
- **`sourcing_start_datetime`** = the `sourcing_end_datetime` of the **previous completed Zone 2 job
  run** for the same source table (CTE 5).
- If the source job **FAILED**: write `source_job_run_id` and status `'Failed'`, and leave
  sourcing start **and** end **NULL**. ⚠️ **And when any one source fails, start/end are left NULL for
  ALL of that job's source-table rows**, not just the failed one.

Downstream:
- An **Aggregator** counts how many source jobs failed.
- A **Router**: if `failed_count > 0` → update `job_run_stats` status to **Failed**, insert a row into
  `job_error_stats` (error type/code/message from the parameter file), and set **`fail_flag = 'Y'`**,
  which the task flow uses to send the failure notification and throw.
- The insert goes to **BOTH** the Aurora table **and its Snowflake copy** — because the job-load
  source-qualifier query joins this table **in Snowflake** to get the window. A **PRE-SQL delete by
  job_id** clears the Snowflake copy before each insert.

##### 3.2d — The rerun source-window mapping — **Zone 2 RERUN only**

- The operator supplies the **`execution_run_id` of the batch run to rewind to** in the **static
  parameter file**, under the global section. For a normal run it is `'NA'`.
- From `job_run_stats`, by target `job_id` + that supplied `execution_run_id` + `status='Completed'`
  → the **START `job_run_id`**. Separately, the **latest** completed job_run_id for that job → the
  **END `job_run_id`**.
- From `etl_data_ingestion_source_window`:
  - using the **START** job_run_id → **`sourcing_start_datetime`** (per source table);
  - using the **END** job_run_id → `source_table_name`, `source_job_run_id`, job status and
    **`sourcing_end_datetime`**.
- The two are joined **on `source_table_name`**, then written through to both the Aurora and Snowflake
  tables (same PRE-SQL delete).
- Same failure handling. A source failure here is *"a very extreme scenario"* because the end time
  comes from the latest **Completed** Zone2 job.

> This is where a Zone2 rerun's window actually comes from. Worked example: the load has run correctly
> until 8 Sep; a logic bug is found; you need to redo 1 Sep → 8 Sep. You put **1 September's
> execution_run_id** in the parameter file, and the framework reconstructs the window from the source
> window rows written on that date.

#### Step 3.3 — `job_rule_execution_log` preload

Runs only when the **`DQ_CHECK_INDICATOR`** parameter is `'Y'`.

- Source: `job_rule_assignment` filtered by `job_id + is_active = 'Y'` → all active
  `job_rule_assignment_id`s.
- Insert **one row per assignment**: `job_rule_execution_id` = **`GEN_RANDOM_UUID()` per row**,
  `job_rule_assignment_id`, `job_run_id`, `start_time` = current timestamp, **`status = 'Started'`**,
  audit columns.
- **On a restart**, any existing rows for the **same `job_run_id`** are **DELETED first**, then
  re-inserted. (Possible because restart reuses the same job_run_id.)

#### Step 3.4 — Target cleanup *(restart only)*

Dummy source, FALSE-condition filter, real work in the target transformation's **PRE-SQL command**;
**both connection and object are parameterised**.

> ⚠️ **Only implemented for SCD Type 2 tables** — *"we have automated logic for type 2 table cleanup;
> if a new table type comes in future we can take care of it later."*

Two operations:

1. **DELETE** the rows inserted by the failed run, identified by `execution_run_id + job_run_id`
   (plus row_created/row_updated audit columns).
2. **UPDATE BACK** the rows that the failed run had *expired*: rows with the same execution_run_id and
   job_run_id **where create_date ≠ update_date** are restored — resetting the **row expiration date**
   **and the row active indicator**.

> **History of that last clause**: during KT 3 Aishwarya noticed the **active indicator was NOT being
> reset**, because at design time she had been told no such column existed, and said *"we have to
> update this, I'll update this."* By KT 7 she confirmed the cleanup mapping had been updated to
> handle the row active indicator, and told the team by mail. **The gap is closed.**

*(The mapping contains two differently-named variables, `failed_job_run_id` and `current_job_run_id`,
which are "one and the same" — a leftover from an earlier design.)*

#### Step 3.5 — Stage table record count *(restart only)*

A mapping counting rows in the stage table filtered by **current `job_run_id` + `execution_run_id`**
(stage table name is a parameter), setting the count into an **in-out parameter** consumed by the job
task flow's next Decision.

> **Why this works**: the stage load runs under full PDO, which is all-or-nothing. A non-zero count is
> therefore proof the previous stage load **completed**. It is a **client requirement** not to reload
> the stage in that case.

#### The job preload sub-task flow, assembled

```
job_run_stats preload
  └── Decision: skip_flag = 'Y' ? ──► End (job skipped entirely)
        │ no
        ▼
  Decision: execution_run_type
    ├── RERUN ──────────────► rerun source-window mapping (3.2d)
    └── NEW / RESTART / ZONE1 RERUN
          └── Decision: execution_type = RESTART ?
                ├── yes ──► preload check (3.2a)
                │             └── Decision on its flag
                │                   ├── DELETE AND LOAD ─► delete (3.2b) ─► load (3.2c)
                │                   ├── SKIP ────────────► (bypass the insert)
                │                   └── LOAD ────────────► load (3.2c)
                └── no  ──────────────────────────────────► load (3.2c)
  Decision: fail_flag = 'Y' ? ──► notification + throw
  Decision: DQ_CHECK_INDICATOR = 'Y' ? ──► job_rule_execution_log preload (3.3)
  Decision: execution_type = RESTART ? ──► target cleanup (3.4) ─► stage count (3.5)
```

**Outputs forwarded to Phase 4**: `job_run_id`, `job_id`, `table_name`, `schema_name`,
`database_name`, `load_type`, the two balance indicators, `skip_flag`, `stage_table_record_count`,
and the sourcing dates.

---

### Phase 4 — Job load

**Two mapping tasks**: source→stage, then stage→target.

> **All ABC integration lives in the source→stage mapping.** Stage→target carries none.

The job task flow first evaluates a **Decision on `stage_table_record_count`**: `> 0` → skip the
source→stage mapping entirely and go straight to stage→target.

#### 4.1 — The source qualifier query

The source-qualifier query does almost everything. It was written by **Bharat**, who gave a separate
KT on it; it is *"very complex and very exhaustive"*. Its CTEs, in order:

1. **Deduplication** — records sharing the same business key **and** `row_effective_date` are
   deduplicated via `ROW_NUMBER()`, keeping the one with the **highest source/ARH timestamp**.
   Then: **join `etl_data_ingestion_source_window`** (the Snowflake copy) to obtain
   `sourcing_start_datetime` / `sourcing_end_datetime`, and apply the **incremental filter** on the
   watermark column.
   > ⚠️ Aishwarya first stated the watermark column would be the same across tables, then observed
   > teams were using different ones — *"this keeps changing."*

   Also here: **RA reprocessing** — records previously routed to RA are UNIONed back into the
   incoming set (see Phase 5 for the loop). **Ignored**: deleted records, and "dead" records where
   `row_effective_date = row_expiration_date`.
2. **Parent lookup and hashing** — lookup on the **parent table** to fetch the FK value; compute a
   **current hash** and **previous hash** and compare. **The hash covers the business keys only**, not
   `row_expiration_date`, so two records sharing a business key but with different effective dates
   that hash-match are ignored and version-numbered.
   Also computes **`row_expiration_date`** = the NEXT record's `row_effective_date`, or a **high-end
   date** for the last record.
   Also builds **`zone1_uuid`** as a **VARIANT/JSON** value `{source_table_name : GRS_UNIQUE_ID}`, the
   **`child`** value used for the RA table, and the **RA parent** columns (parent table name, parent
   business key column name, parent business key value).
3. **Target columns** — bring all columns from the target, **not just the active rows**.
4. **Dual target lookup** — (a) business keys **+ effective date** → the **back-dated** scenario;
   (b) active rows only → the normal SCD path. The **`change_flag`** is computed separately for
   **forward-dated** records and **back-dated** records, and the two are **UNIONed** into the
   source-qualifier output.

#### 4.2 — The DQ expression *(hand-built per table)*

Reference implementation: `broker_party_address`, with **4 `job_rule_assignment` rows on 4 columns,
all null checks — 3 CRITICAL, 1 INFORMATIONAL**.

**`error_description`** is built by a DECODE/IF chain. For each check, if the source column is null it
appends, in this exact positional order:

```
target column name | source column name | source value | rule_id | severity code
```

and successive checks are joined with **`;`** — so one source record produces **one**
`error_description` covering all of its failures. Phase 5 splits on `;` then on `|`.

Details that matter:

- **For a foreign key column, the null check is applied to the SOURCE column used in the join
  condition, not the FK column itself.** Example: `broker_party_address`'s FK is `broker_party_id`;
  to null-check it you validate `src_party_id`, the source column compared against `broker_party`'s
  business key.
- **`rule_id` and the severity code are HARD-CODED in the expression** (`1` = null check;
  **`'C'` = critical, `'I'` = informational**). Both must be looked up by hand from `job_rule_master`
  and `job_rule_assignment` and typed in, per table.
- ⚠️ **Known inconsistency**: broker populates an **empty string** for a null source value; the newer
  CCO logic populates a **hard-coded literal `null`**, which is more meaningful. **Broker was not
  retrofitted.** The visible symptom appears in Phase 5: `source_error_text` reads
  *"Null values found  "* with an empty value.

Two more expressions:

- **`critical_error_check`** — `'Y'` if ANY **critical** column is null, else `'N'`. Only the critical
  columns appear here; the informational one is excluded.
- **`validation_flag`** — `critical_error_check = 'N'` → **VALID**, else **INVALID**.

Hard-coded per table: `source_database_name`, `source_schema_name`, `source_table_name`.
**`source_record_identifier`** = the Zone1 audit column **`GRS_UNIQUE_ID`** (it may carry an alias
prefix such as `SRC_`, but that is the real Zone1 column name).

#### 4.3 — The Router — five paths

| Path | Condition | Destination |
|---|---|---|
| **job_run_stats counts** | **No condition — takes ALL records** | `job_run_stats` **temp** (Snowflake) |
| **Stage** | valid **AND** not no-change **AND** not RA (`NOT ISNULL(<fk>)`) | The **stage** table |
| **RA** | `ISNULL(<fk>)` **AND** the record is **valid** | **RA temp** table |
| **Error** | **`NOT ISNULL(error_description)`** | `job_rule_error_detail` **temp** |
| **Balance reconciliation** | the **same condition as the stage group** | `balance_reconciliation` **temp** |

Notes on each:

- **Counts**: group by `job_run_id`; **`source_record_count = COUNT(1)`**;
  **`target_unchanged_record_count = SUM(CASE WHEN change_flag = 'No Change' THEN 1 ELSE 0 END)`**.
  The `change_flag` is produced inside the source-qualifier query.
- **Error**: the condition deliberately catches **both** critical and informational failures, since
  `error_description` is populated for either. Critical records are excluded from the stage by the
  `validation_flag`; informational ones are not — **so an informational record lands in BOTH the stage
  and the error temp table**. Which is the point:
  > *"Critical → routed to the error detail table only, not loaded to target. Informational → loaded
  > into BOTH the target and the error detail table, because we need to notify the team."*
- **RA**: **only valid records go to RA.**
- **Balance**: metrics are computed **only on records intended for the target** — excluding invalid,
  no-change and RA records. The two groups are written in mirrored form for historical reasons; the
  intent is identical and *"we can use the same group"*.

#### 4.4 — What lands in each Snowflake temp table

**`job_run_stats` temp**: `job_id`, `execution_run_id`, `job_run_id`, `source_record_count`,
`target_unchanged_record_count`, audit columns. **Only these counts** — not `job_start_time` or
anything already in Aurora.

**`job_rule_error_detail` temp**: `job_id`, `execution_run_id`, `job_run_id`, `source_database_name`,
`source_schema_name`, `source_table_name`, `source_record_identifier`, `error_description`, audit
columns. **One row per source record** — the transposition happens in Phase 5.

**`balance_reconciliation` temp**: `job_id`, `execution_run_id`, `job_run_id`,
**`source_aggregate_text`**, audit columns.

The `source_aggregate_text` is built like this:
- For a **DISTINCT COUNT**: a **Sorter** with the distinct option restricted to the needed columns
  (plus the ABC audit columns, which are constant across rows), then an **Aggregator** `COUNT`.
- For an **AMOUNT**: an Aggregator `SUM`, group by `job_run_id`.
- **Precision `DECIMAL(28,6)`** — 28 is the maximum; 6 decimal places chosen. Gayathri was asked to
  confirm and the precision may be revised.
- **Null handling**: each metric is wrapped so that if **every** value is null the sum returns **0**;
  mixed nulls and values still sum correctly.
- An Expression then concatenates: **`'COLUMN_NAME':aggregated_value`**, metrics joined by **`|`**.
  > ⚠️ **The column name written must be the TARGET column name; the value comes from the SOURCE.**
  > Asked explicitly by Bharat: when the source column is `AMT` and the target is `AMOUNT`, you write
  > **`AMOUNT`** — because that string is matched against `balance_reconciliation_metadata` and against
  > the target expression in Phase 5. The same target column names must appear **identically** in the
  > metadata table, the mapping expression and the parameter file.

**RA temp table**:
- **`child`** — a **VARIANT/JSON** column: the framed `GRS_UNIQUE_ID`, keyed and prefixed with the
  source table name. Built in the source-qualifier query, not taken verbatim from Zone1.
- **`parent`** — also VARIANT: **parent table name, parent business key column name, and the parent
  business key value** that found no match. Example seen live: parent table `AGREEMENT`, its business
  key column, and the failing value.
- **`target_zone2_key_column_names` / values** — ⚠️ despite the "Zone2" name these are populated with
  the **SOURCE** key column names and values. Aishwarya raised this with Nithika, who confirmed it is
  acceptable **because they are purely informational columns** used for later analysis.
- `job_id`, target table name, audit columns.

#### 4.5 — The stage table

- **TRUNCATE AND RELOAD** every run. Stage tables are **transient tables in Zone2 (Snowflake)**.
- ⚠️ **Audit column convention, and it is counter-intuitive**: on the stage and the target,
  **`audit_batch_id` is populated with the `EXECUTION_RUN_ID`**, and **`audit_job_id` with the
  `JOB_RUN_ID`** — *not* batch_id/job_id, despite the names. Per **Nithika's** design decision,
  because `execution_run_id` is the value that threads restart handling. Aishwarya called this out
  explicitly as a likely point of confusion.
- On **INSERT**: populate `row_create_datetime`, `row_update_datetime`, `row_created_by_user_id`,
  `row_updated_by_user_id`. On **UPDATE**: only the *updated* pair, **plus** `audit_batch_id` and
  `audit_job_id`, are refreshed with the current run's values.

#### 4.6 — Stage → target

- A **SQL `MERGE`** inside the source qualifier does the upsert; then a filter that blocks everything
  and a dummy target (the IICS target requirement again).
- **Full PDO does not work here** — the "create temporary view" option had to be **unticked** because
  a `MERGE` is not a plain `SELECT`.
- MERGE join condition: all the target's business key columns + `row_effective_date` + source system.
- MERGE branches:
  - **UPDATE** — refresh all non-key columns plus audit columns.
  - **UPDATE EXPIRATION DATE** — set only `row_expiration_date`, the record indicator and
    `audit_update_datetime` (4 columns).
  - **ZONE1 UUID update** — update only `zone1_uuid` and the audit fields.
    > **This is how the Zone 1 rerun scenario is absorbed without any target cleanup.**
  - **INSERT**.
  - A record can be both an update and an expiration-date update — **both are applied**.
- **Type-2 source nuance**: the source is itself SCD Type 2, so a single logical change arrives as
  **two records** — the deactivated one (→ update expiration date) and the newly inserted one
  (→ insert).
- **Surrogate key**: a sequence value is generated for insert records, but **for a given business key
  there is only ONE sequence number** — per Nithika, two records sharing the business key keep the
  same generated key. ⚠️ Aishwarya flagged this as surprising: *"not sure why."*

---

### Phase 5 — Job post load

**Where it runs**: the **ABC job post load success** sub-task flow. **Five sub-steps, in order.**

This is where everything written to Snowflake temps during Phase 4 is read back, computed, and
written into Aurora — *"an ETL mapping/sub-task-flow that reads the Snowflake temp tables, computes
final flags/counts, and issues the real INSERT/UPDATE against the Aurora tables."*

#### Step 5.1 — RA temp → MAIN RA table

Before loading, it **checks whether each record already exists in the main RA table; if so it is
skipped.**

Mechanics:
- **LATERAL FLATTEN** on the `child` VARIANT column — flatten once to get the per-table object, then
  again to reach the uuid value; key = Zone1 table name, value = `zone1_uuid`.
- `ROW_NUMBER() PARTITION BY job_id, table_name, source_table_name, zone1_uuid ORDER BY
  audit_create_datetime` → keep one version, dropping duplicates.
- From the **main RA table**, select only rows with **`process_flag IS NULL`**, matched on Zone2
  job_id, Zone2 table name and Zone1 table name.
- **FULL OUTER JOIN** temp ↔ main, then flag each row:

| Situation | Meaning | Action |
|---|---|---|
| present in **both**, identical | still unresolved | **NO CHANGE** — ignore |
| present in **temp only** | a new RA record | **INSERT** into main |
| present in **main only** (absent from temp) | **it got processed this run** | **UPDATE** → `process_flag = 'Y'` + audit columns |

A Router splits insert and update; the update flow joins on **`zone1_job_id` and `zone1_uuid`**.

Both the RA temp and main RA tables are **parameterised** and **both live in Snowflake only**.

> ### The RA reprocessing loop, end to end
>
> **RA = "late arriving records".** A target has an FK; the business key from source finds no matching
> row in the parent table → that record is an RA record.
>
> Worked example: `BROKER_PARTY_ADDRESS` has FK `broker_party_id` sourced from `BROKER_PARTY`. Some
> rows have no matching `broker_party_id` because the parent's source arrived late.
>
> - **Day 1**: 5 RA records → RA temp → all 5 inserted into main RA with `process_flag` **NULL**.
> - **Day 2**: the **source→stage source-qualifier query reads the main RA table**, filters
>   `process_flag IS NULL` + job_id, and pulls those records back from the source **by their Zone1
>   UUID**, UNIONed with the normal incremental set — **so they are re-attempted even though they fall
>   outside the current sourcing window**.
>   Say 3 now find their parent → they go to the stage table. The 2 that still don't, plus 2 brand-new
>   RA records, = 4 rows written to temp. **Temp is deleted for that job_id first**, then the 4 are
>   inserted.
>   The full outer join then finds the 3 records present in main but **absent** from temp → marks them
>   `process_flag = 'Y'`. The 2 still-failing match on both sides → no change. The 2 new ones exist
>   only in temp → insert.
> - **Day 3**: repeat with the 4 remaining NULL-flagged records. And so on, every day.
>
> **Why two tables**: the **temp** is truncate-and-load per job_id and holds *this run's* RA records;
> the **main** is the source of truth for what has been processed and what is outstanding. Without the
> intermediate temp you cannot tell which records got processed, because a processed record simply
> stops appearing. *"There are so many ways to handle the scenario; this is the way they have
> implemented."*
>
> `target_ra_record_count` in `job_run_stats` = how many source records were routed to RA.
>
> The RA temp→main component was written by **Bharat** but kept inside ABC as a reusable component.
>
> ⚠️ **September 2026 changed the outcome of this loop — see §15, Change 3.** The record is now loaded
> into the target even when the parent is missing, and the FK is **updated** on a later run.

#### Step 5.2 — `job_rule_error_detail` temp → `job_rule_error_detail` *(the transposition)*

A **reusable MAPPING** (explicitly *not* a Mapplet) with **two sources in two different databases**:
`job_rule_error_detail` **temp** (Snowflake) and `job_rule_assignment` (Aurora).

- **LATERAL FLATTEN on `error_description` split by `;`** → one element per failed rule assignment.
- **Split each element by `|`** → the positional fields written in Phase 4: **target column name,
  source column name, error column value, rule_id, error severity code**.
- Filtered to the current run and `error_description IS NOT NULL`.
- From `job_rule_assignment`, by `job_id + is_active`: `rule_id`, `target_column_name`,
  `error_message_text`, `job_rule_assignment_id`.
- An Expression **casts the extracted rule_id string to BIGINT**, then a **Joiner** matches on
  **`rule_id + target_column_name`** to attach the correct `job_rule_assignment_id` to each exploded
  row.
- `source_error_text` = `<error_message_text> <error_column_value>`.
- Columns captured: source database / schema / table / **column** name, error column value,
  `source_record_identifier`, `rule_id`, `job_rule_assignment_id`, severity.

**Multi-source-table case**: when a target draws from several source tables, each has its own UUID
column, so `source_record_identifier` is written as
**`source1_column:value|source2_column:value`** — pairs separated by **`|`**, name and value by **`:`**.

Written to **both** the Snowflake and Aurora `job_rule_error_detail` tables. ⚠️ **Unlike every other
Snowflake ABC table, NO pre-delete is done here** — it is permanent in both databases and rows
accumulate.

#### Step 5.3 — `job_rule_execution_log` update

- Find all rows for this `job_run_id` with status **`'Started'`**.
- Count the related rows in `job_rule_error_detail` **per `job_rule_assignment_id`**.
- **0 error records** → status **`'Passed'`**, `execution_details` populated (e.g. *"0 records with
  null values found"*), `error_message` NULL.
- **> 0** → status **`'Failed'`**, `error_message` populated with the error text **and the exact count
  of records that failed that assignment**, `execution_details` NULL.
- The two fields are mutually exclusive — *"vice versa based upon the status."*

> ### The grain distinction, with the clearest worked example (Walkthrough S1)
>
> 3 error records; 2 rules assigned (one per column). All 3 records fail rule 1 (column 1); only the
> 1st record also fails rule 2 (column 2).
>
> → **`job_rule_error_detail` = 4 rows** (3 for rule 1 + 1 for rule 2) — **record + column grain**.
> → **`job_rule_execution_log` = 2 rows** (one per assignment) — rule 1: *"3 records found with null
> values"*; rule 2: *"1 record found with null values"* — **job-rule-assignment grain**.
>
> And `job_error_stats` is at **job grain**. Three tables, three levels.

#### Step 5.4 — Balance reconciliation *(the reusable component)*

Runs only if `count_threshold_indicator = 'Y'` **OR** `amount_balance_check_indicator = 'Y'`;
otherwise the whole step is bypassed.

1. Fetch all **active** metrics for the job from `balance_reconciliation_metadata` by `job_id`.
2. Fetch the **source** metrics from the Snowflake `balance_reconciliation` temp table.
3. **Compute the TARGET metrics here**, using two parameter-file values:
   - **`TARGET_EXPRESSION`** — injected verbatim into the SELECT clause; builds the same
     `'COL':SUM(COL)|'COL2':SUM(COL2)` string for the target side.
   - **`TARGET_BALANCE_RECON_FILTER`** — the WHERE clause restricting which target rows count.
4. **`out_of_balance_value = source metric − target metric`**.
   - **= 0** → `balancing_flag = 'Y'` **and** `threshold_flag = 'Y'`.
   - **≠ 0** → `balancing_flag = 'N'`, then compare against `threshold_value`:
     within → `threshold_flag = 'Y'`, else `'N'`.
5. Write `balance_reconciliation_stats` with `job_run_id`, `execution_run_id` and audit columns.
   **`valuation_date` is populated NULL.**

> ### `valuation_date` — resolved
> It was originally mapped to **SYSDATE**. Aishwarya flagged genuine confusion about it in KT 1
> (*"there is confusion on this column, but I have implemented it correctly in the logic"*). Per
> **Nithika**, it represents **the date on which a valuation specifically took place** and **need not
> be populated for normal daily loads** — so it was changed to NULL. Only populate it if you are
> deliberately doing a valuation for a particular day.

> ### Why `TARGET_BALANCE_RECON_FILTER` is `1=1`
> Aishwarya originally assumed SCD Type 2 behaved as: one source record → expire the existing target
> row and insert one new row — so the target aggregate would have to be filtered to **active records
> only**, or the comparison would be wrong.
>
> **Bharat corrected her**: in the Zone2 design the source sends **two separate records** handling the
> update and the insert independently, and the **source** side counts both amounts separately.
> Therefore the target side must **also** count both — so the filter is **`1=1`**.
>
> `TRUE` also works (both were tested); `1=1` is preferred because IDMC can get confused by the `=`
> in some contexts. Practical instruction: **keep whatever filter is already present and just add
> this.**

#### Step 5.5 — `job_run_stats` post load update *(the final status calculation)*

1. Fetch **`source_record_count`** and **`target_unchanged_record_count`** from the Snowflake
   `job_run_stats` temp table.
2. If DQ is enabled: from `job_rule_error_detail`, compute **total error records, critical error
   records, informational error records**.
3. If balancing metrics exist: compute **how many metrics are out of threshold** and **how many are
   out of balance but within threshold** — two separate counts.
4. Compute **`target_insert_record_count`**, **`target_update_record_count`**,
   **`target_ra_record_count`** from the target table and the RA table.
   - **`target_delete_record_count` is hard-set to 0** — no calculation is done (see §16).
   - If nothing was inserted/updated, the count is written as **0**.
   - If the job died before post load, the counts stay **NULL**.
5. **`record_count_balancing_flag`** — compare `source_record_count` against the **sum of**:
   ```
   target_insert_record_count
   + target_update_record_count
   + target_critical_error_record_count
   + target_ra_record_count
   + target_unchanged_record_count
   ```
   Equal → `'Y'`, else `'N'`.
   > The intent: *"we want to ensure whatever data is coming from the source is distributed in a
   > meaningful, correct way."* Every source record must be accounted for somewhere.
6. Set the three check flags — **each is three-valued**:

   | Flag | `'Y'` | `'N'` | `'X'` |
   |---|---|---|---|
   | `critical_error_check_flag` | no critical error records | critical error records exist | **no DQ checks assigned to the job** |
   | `informational_error_check_flag` | no informational error records | informational error records exist | **no informational DQ checks assigned** |
   | `balance_reconciliation_check_flag` | **all metrics within threshold** — covers both perfectly balanced AND out-of-balance-but-within-threshold | any metric out of threshold | **no balancing metrics assigned** |

   > **`'Y'` is the green flag.** All-Y means the status is Completed.

7. **The final job status** — decided from those four flags:

   | Outcome | Conditions | Effect |
   |---|---|---|
   | **FAILED** | ANY of: `record_count_balancing_flag = 'N'` · any balancing metric **outside** the allowed threshold · any **critical** DQ check failed | status `'Failed'` + a **`job_error_stats`** entry + **failure notification** |
   | **COMPLETED (with warning)** | informational check failures, and/or any metric out of balance but **within** threshold | status `'Completed'` + **warning notification** |
   | **COMPLETED (success)** | all record counts balance **and** all metrics **completely** balanced **and** all critical **and** informational checks passed | status `'Completed'` + **success notification** |

   > ⚠️ **When both warning-level and failure-level conditions occur, it is a FAILURE** — and the
   > single failure notification carries **both** the failure details and the warning details.

**DQ checks and balance metrics are never mandatory.** When absent, every related step is bypassed in
preload, load and post load alike.

---

### Phase 6 — Batch post load

**Where it runs**: the last mapping task in the batch task flow, after **all** job task flows.

**What it does**: checks the final status of every job under the batch. All Completed →
`batch_run_stats` status **Completed** + success notification. One or more failed → **Failed** +
failure notification, and the batch task flow itself is failed.

**Task flow wiring, precisely**:

1. The Start step declared `error_count` (initial 0) and `batch_status` (initial NULL) back in Phase 2.
2. An **Assignment task sits under every job sub-task flow**, setting the error count to 1 on failure.
3. A **Decision task** — which **must be placed after ALL job sub-task flows in run order** — tests
   `error_count = 0`.
4. An Assignment sets `batch_status` = **`'C'`** (zero errors) or **`'F'`**.
5. That value is passed as an input field into the batch post load **mapping task**.

**The mapping**: the source query fetches the **latest `batch_run_id`** for the input `batch_id` with
**`status = 'Started'`**, plus the current timestamp and audit values. An expression maps
`'C'` → **`'Completed'`**, otherwise **`'Failed'`**. The target update keys on **`batch_run_id`** (the
PK) and sets **`batch_end_time`, `status`, `audit_update_datetime`, `audit_updated_by_user_id`**.

A final Decision on `batch_status` routes to the success or failure notification; the failure branch
fails the task flow after sending.

---

## 10. The failure chain

Two failure sub-task flows exist, and — a detail worth knowing — **they share the same two underlying
mappings**. Only the wrapping task flows and the notification text differ.

### The two shared mappings

**Mapping A — update `job_rule_execution_log`**
Select rows by `job_run_id` with status `'Started'`, take `job_rule_execution_id` (the PK), and set
`end_time`, **`status = 'Failed'`**, `error_message` = **"Job failed due to data issues"**,
`audit_updated_datetime`, `audit_updated_by_user_id`. If there are no `'Started'` rows, nothing is
updated.

**Mapping B — `job_run_stats` post load failure**
By `job_run_id`, fetch `batch_name`, `job_name`, `job_id` etc.; update `job_run_stats` status →
**Failed** with `end_time` and audit columns; and **INSERT into `job_error_stats`** using
error_type / error_code / error_message from the parameter file. Then the failure notification is sent,
naming job name, job_id and job_run_id.

*(An Expression sits between source and target purely because IDMC requires one, even though the logic
could live in the source query.)*

### When each is triggered

| Failure point | Handler |
|---|---|
| The **`job_run_stats` preload mapping itself** | Notification sent from inside the job preload sub-task flow; the **whole job task flow fails immediately** |
| **Any other job preload component** | `preload_status_flag = 'N'` → **ABC job preload failure** sub-task flow |
| **Source→stage mapping** | **Job post load failure** sub-task flow |
| **Stage→target mapping** | **Job post load failure** sub-task flow |
| **Job post load success** components | **Job post load failure** sub-task flow |
| **Batch preload / batch post load** mapping | Notification + the batch task flow is failed |
| Any **job** task flow | The batch task flow increments `error_count` and continues to the next job |

The job post load failure flow also **deletes any records already written into the temp tables** for
the run.

> ⚠️ **The Lucid diagram covers only the SUCCESS path.** Failure handling was described verbally:
> *"That is not added here because we are having this Lucid primarily for a successful run."*

> ⚠️ **The network-failure blind spot.** If a network failure kills the run outright, ABC cannot write
> a `job_error_stats` entry and cannot send a notification — *"in case of a network issue we won't be
> able to make an entry into the job error stats and notify someone."* This is precisely why Phase 3
> writes that entry retrospectively on the next restart.

### Where `job_error_stats` gets written
**At ANY point the `job_run_stats` status is set to Failed** — job preload failure, source-load
failure, stage load failure, main load failure, any job post load component failure, and the final
post-load FAILED status.

Columns: `job_error_id` (PK, UUID), `job_id`, `job_run_id`, `error_type`, `error_code`,
`error_message`, audit columns. Sample: error_type *"Execution error"*, message *"Job failed / job run
was failed during the load"* plus job name, batch name, job_id, job_run_id.

---

## 11. The seven execution types

Three are "horizontal" — recurring, part of normal operations. Three are "vertical" / **one-time**.
One (rerun) sits in between. *"There cannot be a 4th scenario — it's either regular or failure."*

| # | Type | `batch_rerun_flag` | `execution_type` | Implemented? | batch_run_stats row | Prerequisite evaluated? | Target cleanup |
|---|---|---|---|---|---|---|---|
| 1 | **New / regular** | `'N'` | `NEW` | ✅ | Auto insert, **new** execution_run_id | ✅ **yes** | n/a |
| 2 | **Restart** | `'N'` | `RESTART` | ✅ | Auto insert, **same** execution_run_id | ❌ no | ✅ **automatic** |
| 3 | **Zone 2 rerun** | `'Y'` | `RERUN` | ✅ | **MANUAL** | ❌ no | ⚠️ **MANUAL** |
| 4 | **Zone 1 rerun** | `'Z'` | `ZONE 1 RERUN` | ✅ | **MANUAL** | ❌ no | **none needed** |
| 5 | **Historical load** | `'H'` | — | ❌ **not built** | **MANUAL** | ❌ no (to confirm) | — |
| 6 | **Catchup load** | `'C'` | — | ❌ **not built** | **MANUAL** | ❌ no (to confirm) | — |
| 7 | **First-time incremental** | `'I'` | `Zone 2 First Time Incremental` | ❌ **not built** | **MANUAL** | ❌ no (to confirm) | — |

For all the manual cases, **batch preload performs no insert and no change** — the `insert_flag = 0`
branch. *(Riya pushed back in KT 2 that the LLD's wording "will not perform any additional changes" is
vague, and asked for an explicit line: "it will not make any new entry as the entry already exists.")*

---

### 1. New / regular run

The daily happy path. Covered fully in §9.

- `sourcing_start_time` = the previous Zone2 batch run's **sourcing_END_time**.
- `sourcing_end_time` = the **latest Zone1 batch end time** whose status is Completed or Partial.
- New `execution_run_id`, rerun flag `'N'`, status `'Started'`.

---

### 2. Restart

**Trigger**: *"Your batch is still running, you haven't completed your batch, but a job failed for any
reason"* — most often a network failure. You investigate, then restart; the framework absorbs it.

**How you actually trigger it**: after a failure, the prerequisite task flow will (correctly) refuse.
So you **trigger the Zone2 batch task flow DIRECTLY from Stonebranch, skipping the prerequisite**. The
code then sees the latest batch run = Failed and treats the run as a restart.

**Behaviour**:
- Insert a new `batch_run_stats` row with the **SAME `execution_run_id`** and the **same sourcing
  start/end as the prior run**.
- If the previous row is in **'Started'**, first **UPDATE it to 'Failed'**, then insert.
- **Jobs already Completed under that execution_run_id are NOT reprocessed** — `skip_flag = 'Y'`
  sends them straight to End with no entries at all.
- Jobs in Failed → the existing `job_run_stats` row is reset to 'Started'.
- Jobs in Started → the row is reused, and a `job_error_stats` entry is written for the earlier
  interrupted run.
- `job_rule_execution_log` rows for the job_run_id are **deleted and re-inserted**.
- The source-window rows are checked: all present → **SKIP**; partial → **DELETE AND LOAD**; none →
  **LOAD**.
- **Target cleanup is automatic** (type-2 only).
- **If the stage table already has rows for this job_run_id + execution_run_id, the stage load is
  skipped** — a client requirement.

---

### 3. Zone 2 rerun — `batch_rerun_flag = 'Y'`

**Trigger**: a batch must be reprocessed for a **backdated / controlled date range**.

> *"The batch is executing successfully for 10 days. On the 11th day you realise some transformation
> rule has gone wrong. Now you have to redo the exercise — rerun the entire execution from day one to
> day ten."*
>
> Or: today is 23 Jul, but a source-system change means 1 Jul → 23 Jul must be reloaded.

Unlike the one-time scenarios, **a rerun can recur any number of times**.

**Steps**:
1. ⚠️ **MANUAL CLEANUP FIRST.** Existing target records are **hard deleted**, driven by the application
   **load type** and the target's audit columns — **`audit_batch_id`, `audit_create_datetime`,
   `audit_update_datetime`**. **No script exists**; the process is owned outside ABC by Swayam and
   Saurabh. *"In case of rerun it should be manually done, and that we have to get from someone."*
2. **MANUAL** `batch_run_stats` row: new `execution_run_id`, rerun flag `'Y'`, status `'Started'`,
   `sourcing_start_time` and `sourcing_end_time` set **as required by the date range**.
3. Put the **`execution_run_id` of the batch run to rewind to** into the **static parameter file**
   (global section), replacing the usual `'NA'`.
4. Trigger the **batch task flow** directly.
5. **ALL tables associated with the batch are re-executed, including ones that previously succeeded.**
6. The rerun source-window mapping (§9, 3.2d) reconstructs the window from the START and END
   job_run_ids.

---

### 4. Zone 1 rerun — `batch_rerun_flag = 'Z'`

**Trigger**: Zone 1 itself did a rerun and resent the data.

> *"They have a DMS process, a CDC process, where they cannot put a checkpoint. If something messes up
> for three to four days they go ahead and do the entire rerun and send us the entire data volume.
> Instead of 10 records that you would be expecting today, you'll get all 110 records."*

**Behaviour**:
- **MANUAL** `batch_run_stats` row: new `execution_run_id`, rerun flag `'Z'`, status `'Started'`.
- Batch preload makes no entry; execution begins at job preload.
- The source-window logic is **identical to a new run**.
- ⚠️ **NO target table cleanup is done, and none is needed.**

> **Why no cleanup** — the clearest explanation, from Walkthrough S2: when Zone 1 reruns, the
> **`GRS_REFINED_TIMESTAMP`** (the time the record arrived in the Zone 1 table) **also changes**. So
> all those records fall inside the normal incremental delta, get compared against what is already in
> the target, and any change becomes an **update**. If there is no change, the record would be
> rejected — but in practice that almost never happens, because **the `GRS_UNIQUE_ID` UUID differs for
> every record**, so at minimum the `zone1_uuid` value is updated. That is exactly what the MERGE's
> dedicated **ZONE1 UUID update** branch is for (§9, 4.6).
>
> *"In case of a Zone 1 rerun, if the data for a particular key is changing, they are updating that
> record. They have the logic in place to handle backdated data within the source query itself."*
>
> This scenario is *"more of a functional thing, not really related to ABC"* — but ABC has to handle it.

---

### 5. Historical load — `batch_rerun_flag = 'H'` ❌ NOT IMPLEMENTED

**Purpose**: load historical data **Teradata → Snowflake Zone 2, via Zone 1**.

> ⚠️ **Direction reversal**: in the current state **Teradata is the TARGET** database. In the future
> state historical load, **Teradata is the SOURCE**.
>
> The Teradata → Zone 1 leg is done by the separate **DMigrator** framework, landing in the Zone 1
> Iceberg tables. **ABC is responsible only for the Zone 1 → Zone 2 leg.** (Riya asked for this to be
> stated explicitly in the LLD.)

**Manual `batch_run_stats` row**: new `execution_run_id`, new `batch_run_id`, rerun flag `'H'`, status
`'Started'`,
- **`sourcing_start_time = 1900-01-01`** (the low-end date)
- **`sourcing_end_time = MAX(GRS_REFINED_TIMESTAMP) across ALL tables for the given batch`**

> **`GRS_REFINED_TIMESTAMP`** is a column present on **every Zone 1 target table**. It is **not** in
> the ABC metadata tables. In production, whoever runs the load is responsible for computing that max;
> for dev/test any reasonable value (e.g. today's date) may be used. ⚠️ Who supplies it in production
> was unresolved — confirm with Swayam.

**Other behaviour**: prerequisite not evaluated; batch preload makes no change; execution begins at
**job preload**.

**Runtime tables used**: `batch_run_stats`, `job_run_stats`, `job_error_stats`,
`job_rule_execution_log`, `job_rule_error_detail`, `balance_reconciliation_stats`.
⚠️ **`etl_data_ingestion_source_window` is NOT used** — the window comes straight from
`batch_run_stats`, since the whole point of the source-window table is the *incremental* window.

**Checks still required**: null checks on key columns (supplied by the **data modelling team**);
source-vs-target count validation (handled by `job_run_stats` in job post load); balance reconciliation
on any amount columns.

---

### 6. Catchup load — `batch_rerun_flag = 'C'` ❌ NOT IMPLEMENTED

Same Teradata→Snowflake nature. The difference from historical is **purely the window**: the
historical load is so large it runs for days, and the days that elapse *during* it must be caught up.

**Manual row**: new `execution_run_id`, rerun flag `'C'`, status `'Started'`,
- **`sourcing_start_time` = the `sourcing_end_time` of the prior successfully completed (historical)
  batch**
- **`sourcing_end_time` = MAX(GRS refined timestamp)** again — ⚠️ *not* simply the current timestamp

Prerequisite not evaluated; batch preload does nothing; the source-window table is **not** used; same
critical / count / balance checks.

---

### 7. First-time incremental — `batch_rerun_flag = 'I'` ❌ NOT IMPLEMENTED

The initial incremental run after historical + catchup, with Zone 1 now taking data from the real
source systems again.

**Manual row**: new `execution_run_id`, rerun flag `'I'`, status `'Started'`,
- **`sourcing_start_time` = a deliberate OVERLAP before the catchup load's `sourcing_end_time`** — so
  no data is lost. Anything already in the target simply comes back as *unchanged*.
  > ⚠️ **The overlap size is a judgement call, not a fixed rule.** KT 2 (July) says **3 days prior**;
  > Walkthrough S1 (September) says **2 days prior**. Both are described as "to avoid any data loss".
- **`sourcing_end_time` = the Zone 1 batch end time.**

⚠️ **Unlike historical and catchup, this one DOES use `etl_data_ingestion_source_window`.** Per Swayam:
its `sourcing_start_datetime` must be populated **from the `batch_run_stats` manual entry**, must be
**consistent across all tables for the batch**, and must be **stored in UTC**. Its
`sourcing_end_datetime` follows the normal rule (from the source job end time). This requires new code
in the source-window component keyed on execution type.

> **The only difference between first-time incremental and a new run** is that the sourcing start is
> *told* to the process by a manual entry rather than derived. Everything else is identical.

**Parameter value for the execution type string**: **`"Zone 2 First Time Incremental"`**.

### The worked timeline for all three one-time scenarios

Two versions were given; they differ only in the dates and the overlap size.

**KT 2, July version:**
| Phase | Window | Notes |
|---|---|---|
| Historical | 1900-01-01 → **2026-12-31** | Triggered, runs ~10 days, finishes **10 Jan** |
| Catchup | **31 Dec → 10 Jan** | ~10 days of data, runs in about an hour |
| First-time incremental | **7 Jan** → current timestamp | **3 days** before the catchup end |
| Regular incremental | from **12 Jan** | Stonebranch takes over |

**Walkthrough S1, September version:**
| Phase | Window |
|---|---|
| Historical | 1900 → **31 Aug** |
| Catchup | **1 Sep → 10 Sep** (historical took ~10 days) |
| First-time incremental | from **8 Sep** — **2 days** before the catchup end |

Exact clock times are the operators' choice — if the regular batch is scheduled at 1:00 AM they would
likely align everything on 1:00 AM. *"All these decisions might differ in the production environment,
but this is the basic assumption we are having for this design."*

---

### Which sourcing columns each execution type actually uses

| Execution type | Where the window comes from |
|---|---|
| Historical, Catchup | **Directly from `batch_run_stats`** (now `batch_sourcing_stats`). The source-window table is not used |
| First-time incremental | `batch_run_stats` supplies the **start**; the source-window table is used, with the **end** from the source job end time |
| Regular, Restart, both reruns | The real per-source window lives in **`etl_data_ingestion_source_window`**. `batch_run_stats`' sourcing columns are still populated (Nithika asked for them to be) but **their values are not used** |

---

## 12. Flag legend — every flag, every value

### `batch_rerun_flag` (on `batch_run_stats`)

| Value | Meaning |
|---|---|
| **`N`** | Regular run **or** restart |
| **`Y`** | Zone 2 rerun |
| **`Z`** | Zone 1 rerun |
| **`H`** | Historical load *(not implemented)* |
| **`C`** | Catchup load *(not implemented)* |
| **`I`** | First-time incremental *(not implemented)* |

### The four `job_run_stats` decision flags

| Flag | `'Y'` | `'N'` | `'X'` |
|---|---|---|---|
| `record_count_balancing_flag` | source count = sum of target counts | mismatch | *(not used)* |
| `critical_error_check_flag` | no critical error records | critical error records exist | no DQ checks assigned |
| `informational_error_check_flag` | no informational error records | informational error records exist | no informational checks assigned |
| `balance_reconciliation_check_flag` | all metrics **within threshold** | any metric **out of** threshold | no balancing metrics assigned |

**`'Y'` is green throughout. All-Y → Completed.**

### `balance_reconciliation_stats` flags

| Flag | `'Y'` | `'N'` |
|---|---|---|
| `balancing_flag` | `out_of_balance_value = 0` | otherwise |
| `threshold_flag` | `\|out_of_balance_value\|` within `threshold_value` (and always `'Y'` when perfectly balanced) | outside the threshold |

### Control flags used only within the task flows

| Flag | Set by | Meaning of `'Y'` |
|---|---|---|
| `skip_flag` *(prerequisite)* | Phase 1 expression | **Skip the batch run** — the latest run is Started or Failed → notify and fail |
| `skip_flag` *(job preload)* | Phase 3.1 expression | Skip this entire job — restart + already Completed |
| `fail_flag` | Phase 3.2 router | A Zone 1 source job failed → notify and throw |
| `preload_status_flag = 'N'` | Job preload sub-task flow | A non-critical job preload component failed → route to the preload failure flow |
| `insert_flag` / `update_flag` | Phase 2 & 3.1 expressions | Route to the insert or update branch of the router |
| `error_count` | Batch task flow assignments | Count of failed job task flows |
| `batch_status` | Batch task flow decision | `'C'` → Completed, `'F'` → Failed |
| Source-window check flag | Phase 3.2a | `LOAD` / `SKIP` / `DELETE AND LOAD` |
| `process_flag` *(main RA)* | Phase 5.1 | `'Y'` = this RA record has been processed; **NULL = still outstanding** |

### DQ severity

| Code | Value | Behaviour |
|---|---|---|
| **`C`** | CRITICAL | Record → error detail table **only**. **Not loaded to target.** Sets `critical_error_check = 'Y'` → `validation_flag = INVALID` → job **FAILS** |
| **`I`** | INFORMATIONAL | Record → error detail table **AND** target. Job **completes** with a **warning** notification |

---

## 13. Table catalogue, keyed to the chain

### Metadata (static) tables — populated in Step S1

| Table | Grain | Written by | Read in |
|---|---|---|---|
| `batch_metadata` | one batch | manual DML | Phase 1, Phase 2 |
| `job_metadata` | one target table | manual DML | Phase 3.1, Phase 3.2 (for source job ids), Phase 5.5 |
| `etl_data_ingestion_metadata` | one source table per job | manual DML | Phase 3.2a, 3.2c |
| `job_rule_master` | one rule, globally | manual DML | Phase 4.2 (by hand, to find the rule_id) |
| `job_rule_assignment` | one rule per column per job | manual DML | Phase 3.3, Phase 5.2 |
| `balance_reconciliation_metadata` | one metric | manual DML | Phase 5.4 |
| batch-prerequisite config table | one dependency | manual DML | Phase 1 |

### Runtime tables — where each is touched in the chain

| Table | Inserted | Updated | Grain |
|---|---|---|---|
| `batch_run_stats` | **Phase 2** | **Phase 6** (and Phase 2 for the restart-from-Started case) | one batch run |
| `batch_sourcing_stats` *(Sept 2026)* | manual, one-time per source batch | — | one (target batch, source batch) pair |
| `job_run_stats` | **Phase 3.1** | **Phase 5.5** (and Phase 3.1 for restart-from-Failed) | one job run |
| `etl_data_ingestion_source_window` | **Phase 3.2c / 3.2d** | — (deleted + reloaded) | one source table per job run |
| `job_rule_execution_log` | **Phase 3.3** | **Phase 5.3** | one job_rule_assignment per job run |
| `job_rule_error_detail` | **Phase 5.2** | — | one record **× column** |
| `job_error_stats` | **any failure point** | — | one error event |
| `balance_reconciliation_stats` | **Phase 5.4** | — | one metric per job run |
| RA temp *(Snowflake)* | **Phase 4.3** | truncated per job_id | one RA record this run |
| main RA *(Snowflake)* | **Phase 5.1** | **Phase 5.1** (`process_flag`) | one outstanding RA record |
| `job_run_stats` temp *(Snowflake)* | **Phase 4.3** | — | one row per job run |
| `balance_reconciliation` temp *(Snowflake)* | **Phase 4.3** | — | one row per job run |
| `job_rule_error_detail` temp *(Snowflake)* | **Phase 4.3** | — | one **record** (pre-transposition) |

### Key column detail

**`batch_run_stats`**: `batch_run_id` (PK, UUID), `batch_id` (FK), `execution_run_id`, `instance_id`
(unused), `database_name` / `table_name` (unused), `sourcing_start_time`, `sourcing_end_time`
*(moved to `batch_sourcing_stats` in Sept 2026)*, `batch_start_time` (Phase 2),
`batch_end_time` (Phase 6), `status`, `source_batch_execution_run_id` (the latest execution_run_id of
the Zone1 source batch), audit columns, `batch_rerun_flag`, `KRS` (Zone1), `schema_name` (unused).

**`job_run_stats`**: `job_run_id` (PK, UUID), `execution_run_id`, `job_instance_id` (NULL, Zone1),
`job_id` (FK), `job_start_time` (Phase 3.1), `job_end_time` (Phase 5.5), `status`,
`target_table_name` / `target_schema_name` / `target_database_name` (informational),
`source_record_count`, `target_insert_record_count`, `target_update_record_count`,
`target_unchanged_record_count`, `target_error_record_count`, `target_delete_record_count`,
`target_ra_record_count`, `record_count_balancing_flag`, `critical_error_check_flag`,
`informational_error_check_flag`, `balance_reconciliation_check_flag`, audit columns, `KRS`.

**`etl_data_ingestion_source_window`**: target `execution_run_id`, `target_batch_id`, `target_job_id`,
`target_job_run_id`, `target_table_name`, `source_name`, `source_table_name`, source
`execution_run_id`, `source_job_run_id`, `source_job_status`, `sourcing_start_datetime`,
`sourcing_end_datetime`.

**`job_rule_execution_log`**: `job_rule_execution_id` (PK, UUID), `job_rule_assignment_id` (FK),
`job_run_id`, `start_time`, `end_time`, `status` (Started → Passed | Failed), `error_message`,
`execution_details`.

**`job_rule_error_detail`**: `job_rule_assignment_id`, `job_run_id`, `execution_run_id`, `rule_id`,
`source_database_name`, `source_schema_name`, `source_table_name`, **`source_column_name`**,
`source_record_identifier`, `source_error_text`, severity, audit columns.

**`job_error_stats`**: `job_error_id` (PK, UUID), `job_id`, `job_run_id`, `error_type`, `error_code`,
`error_message`, audit columns.

**`balance_reconciliation_stats`**: PK, `valuation_date` (**NULL** for normal loads), `source_value`,
`target_value`, `balancing_flag`, `out_of_balance_value`, `threshold_flag`, audit columns,
`balance_reconciliation_metric_id` (FK), `job_run_id`, `aggregation_run_id`.

---

## 14. Notifications

| Trigger | Type | Sent from |
|---|---|---|
| The prerequisite task flow fails (latest Zone2 batch not Completed) | Failure | Phase 1 |
| A Zone 1 **source** load failed | Failure | Phase 3.2 |
| A **critical** validation check failed | Failure | Phase 5.5 |
| `record_count_balancing_flag = 'N'` | Failure | Phase 5.5 |
| A balance metric is **out of threshold** | Failure | Phase 5.5 |
| **Informational** validation failures | **Warning** | Phase 5.5 |
| Balance differences **within** the threshold | **Warning** | Phase 5.5 |
| A job completes with all checks passed | Success | Phase 5.5 |
| Any component execution error | Failure | the relevant failure sub-task flow |
| **Final batch-level result** | Success or Failure | Phase 6 |

**Content requirement**: the client explicitly asked that **batch name and job names** appear — not
just the IDs (job_id, batch_id, job_run_id, execution_run_id). This was added as **rework after client
feedback**.

> ### ⚠️ Notification volume — raised as a concern, not resolved
> A batch of 10 jobs produces **11 notifications** on **every** run, including fully successful ones
> (10 job-level + 1 batch-level). Riya flagged this as excessive given that daily success is the norm.
> Aishwarya's answer: it is a **client requirement**.

**Recipients**: today the developers mail themselves. `batch_metadata.email_id` is populated but
**not wired in**. The real distribution list — presumably an admin/support team — was never decided.

---

## 15. The September 2026 changes

These post-date the July/August KT series and are the **newest known state** of the framework. At the
time of the 9 Sep walkthroughs they were in the LLD (highlighted **yellow**) but **not yet in the data
model diagram and not in the Lucid flow**, and **not yet reviewed or signed off**.

> Aishwarya's explicit advice: *"If you didn't get it, please wait until these changes are properly
> reviewed and signed off."*

### Change 1 — `batch_run_stats` SPLIT into `batch_run_stats` + `batch_sourcing_stats`

**Why**: the framework was built on the assumption that **one Zone 2 batch run depends on exactly ONE
Zone 1 batch run**. A later requirement arrived where a **Zone 2 batch depends on MULTIPLE Zone 1
batches**. Since `sourcing_end_datetime` is the Zone 1 batch end time, multiple source batches need
multiple sourcing rows — but a batch run must stay a single row. So the sourcing columns moved out.

- **`batch_run_stats`** now holds only the batch **run** details.
- **`batch_sourcing_stats`** holds the **sourcing window** details — the LLD's own wording: *"stores
  multiple source batches information for a target batch."*
- **The sourcing window timestamps now come from `batch_sourcing_stats`**, and
  `etl_data_ingestion_source_window` picks up its start/end from there.
- **Manual entries** for historical / catchup / first-time-incremental / rerun must now be made in
  **BOTH** `batch_run_stats` **AND** `batch_sourcing_stats` — still **never** in
  `etl_data_ingestion_source_window`, which the framework always loads automatically.

**`batch_sourcing_stats` columns** (from the real CRC row inserted on 8 Sep):

| Column | Value in the example |
|---|---|
| PK | **auto-increment — do not supply** |
| `target_batch_id` | 455 (CRC) — from `batch_metadata` |
| `source_batch_id` | 151 (the Zone 1 batch) |
| `execution_run_id` | copied from `batch_run_stats` for that batch |
| `batch_run_id` | copied from `batch_run_stats` for that batch |
| `source_batch_execution_run_id` | the execution_run_id of that source batch's run |
| `sourcing_start_datetime` / `sourcing_end_datetime` | **1900** → **31 Aug** (the day of insertion) |
| audit columns | |

⚠️ **It is a ONE-TIME entry per (target batch, source batch) pair** — one row per source batch, not
one per run.

### Change 2 — Job task flow input fields

At the **job-level task flow Start step**, and mirrored in the **job preload** sub-task flow's input
mapping:

- **ADD** two parameters — **`batch_run_id`** and **`batch_type`** — and tick their "required" box.
- **REMOVE / untick** the three they replace — **`source_batch_id`**, **`source_execution_run_id`**,
  **`source_batch_end_time`**.
- In the job preload sub-task flow, the two new incoming fields must be re-bound from **Content** to
  **Field** and mapped to the Start-step parameters.
- **`batch_run_id`'s value is taken from the `batch_sourcing_stats` row** and is **the same for every
  task flow of that asset**.
- **`batch_type`** — set to **`"data share"`** when the source is a data share; left blank otherwise.
  (CRC's source is not a data share, so it was left empty.)
- **Only these two places change at job level.** The domain-level changes had already been applied by
  another team for the claims and contract domains.

### Change 3 — RA / referential integrity behaviour REVERSED

| | Old | **New** |
|---|---|---|
| FK not found in the parent | Record routed to RA temp and **NOT loaded into the target** | **The record IS loaded into the target** |
| On a later run, once the parent appears | The record is loaded into the target for the first time | **The foreign key value is UPDATED** on the already-loaded target row |

The main RA table still drives the reprocessing loop, but the outcome is now an **update** rather than
a first-time insert: records brought back from main RA *"would go to the target either as insert or
**update** — update is the latest change."*

### Change 4 — `etl_data_ingestion_metadata` gained three columns

**`database_name`, `schema_name`, `source_object_name`** — added so a source table can be **uniquely
identified in `job_metadata`**, because the same source table name can exist in multiple schemas or
databases. Added "very recently"; at walkthrough time **not yet updated everywhere**.

### Change 5 — The ABC data model gained two more tables
Per the status tracker: *"we have created two more tables, I have added them"* — consistent with
`batch_sourcing_stats` plus one other.

### Still expected
**Periodic balance reconciliation**, plus the history, catchup and incremental load changes.

> **All change announcements go out on a single mail chain to a DL.** *"Go from the bottom, you will
> understand what changes have happened."* **That mail chain is the de-facto change log for ABC.**

---

## 16. Open items, risks and known gaps

### Not built

| Item | Status |
|---|---|
| **Historical load** (`'H'`) | Design described in the LLD; **no code at any phase** |
| **Catchup load** (`'C'`) | Same |
| **First-time incremental** (`'I'`) | Same. **The main pending item**, handed to Riya at KT 1 |
| **Automation of DQ checks in the main mapping** | ⚠️ **Parked.** Aishwarya raised it **multiple times** and was told to park it each time |
| **Multiple sources → single domain load** | Not designed. *"We are considering a single source and single dependency"* — though Sept 2026's `batch_sourcing_stats` is the first step toward it |
| **Delete scenario** | `target_delete_record_count` is **hard-coded 0**. No asset has needed it. Two options discussed: hard delete from target, or **soft delete via an `audit_delete_indicator`** column (currently hard-coded `'N'`). If it arises, job post load must change. Route via Swayam → Nithika |
| **Dedicated Aurora ABC database** | See the risk below |
| **Per-domain Snowflake ABC schemas** | Target state; today one shared testing schema |
| **The second Zone 2 application layer** ("Functional") | Nobody was certain of its name; no work done |

### Standing risks

> **⚠️ RISK 1 — The Aurora database migration.**
> The Zone 1 ABC team is creating a **new Aurora database via Liquibase** with standards-compliant
> database and schema names. **No communication has ever arrived**, despite being chased at
> collocation. When it lands, **every static parameter file must be updated**, because today
> everything points at `default DB` / `ABC` schema, and parameter files are deployed to other
> environments. Also: once pointed there, all DML must go through Liquibase rather than by hand.
> POCs: **Vidya** and **Vaishnavi**.

> **⚠️ RISK 2 — Metadata shortcuts copied across the team.**
> Developers copied Aishwarya's POC entries verbatim. Each of these must be corrected **before any
> SIT promotion** — she called it a "treat-equal check":
> 1. **`application_source_batch_id` is a DUMMY value** in most `batch_metadata` rows. It must be
>    replaced with the **actual Zone 1 batch_id**.
> 2. **`schema_name` and `database_name` in `job_metadata` point at testing schemas.** The Snowflake
>    data model now has real domain-level databases and schemas. Left uncorrected, the failure is
>    subtle but total: **job post load uses those names to compute the target counts**, so
>    `source_record_count` is N while the target count comes back 0 → `record_count_balancing_flag`
>    = `'N'` → **the job fails**.
> 3. **`count_threshold_indicator` / `amount_balance_check_indicator` are being copied verbatim**
>    rather than set from the table's real functionality.
> 4. **`etl_data_ingestion_metadata` has only ONE source-table row per job**, because the POC example
>    had one. Multi-source tables need multiple rows.
> 5. **`job_rule_master` has only the null-check entry.** Any new rule type must be inserted there
>    first — *"that functionality they are missing, is what I'm feeling."*
> 6. **`job_rule_assignment` and `balance_reconciliation_metadata`** must be set per real
>    functionality.

> **⚠️ RISK 3 — No source control discipline in IDMC.**
> No check-out / check-in. Multiple teams edit the same task flows concurrently. Changes to common
> components propagate only by **mail** plus manual re-copying.

### Known gaps and inconsistencies

| Gap | Detail |
|---|---|
| **Network-failure blind spot** | An abrupt failure means no `job_error_stats` entry and **no notification**. Mitigated retrospectively on the next restart, but the alert is genuinely lost |
| **Prerequisite sends no mail on execution error** | *"If I upgrade this, I'll send out a mail"* |
| **Broker's empty-string vs CCO's `'null'`** | Broker writes an empty string for a null source value; CCO writes a literal `'null'`. **Broker was not retrofitted.** Visible in `job_rule_error_detail.source_error_text` |
| **`is_active` on `job_rule_assignment` is not honoured** | See §4, S1.5. Requires a matching ETL edit |
| **Target cleanup is type-2 only** | Any other load type has no automatic restart cleanup |
| **Rerun cleanup is entirely manual** | No script exists. Owned by Swayam / Saurabh, outside ABC |
| **The surrogate-key sequence** | Two records sharing a business key keep the **same** generated key, per Nithika. Aishwarya: *"not sure why"* |
| **`target_zone2_key_column_names` holds SOURCE values** | Confirmed acceptable by Nithika because they are informational only |
| **Batch and job NAME conventions not final** | Pending agreement with Nithika |
| **`source_to_target_layer` inconsistency** | Some CCO rows say "Zone1 to Zone2 Data Domain" instead of "Refined to Zone2 Data Domain" |
| **Mock runtime entries** | Dummy Zone 1 **and** Zone 2 runtime rows exist because Zone 1's entries aren't usable. **Unit testing only — must not exist in any other environment** |
| **No Technical Design Document** | *"There is no TD in this project."* The task flows + parameter file are the technical reference. Aishwarya's **UT document** is the substitute and is *"very exhaustive"* |
| **Component names undocumented** | Riya insisted the list of ABC IDMC component names be recorded somewhere; Aishwarya agreed to add the folder and component names to the LLD during KT 7 |
| **The Lucid flow is deliberately not updated** for H/C/I or the Sept changes | Only the LLD text carries them. Rationale: the picture should follow the code once it's actually built |
| **Whether the prerequisite applies to H/C/I** | Aishwarya believes not; **to be confirmed with Swayam** |
| **Who supplies `MAX(GRS_REFINED_TIMESTAMP)`** in production | Unresolved; confirm with Swayam |
| **Static tables** (~3 in Producer/CCO) | Unknown whether they use ABC at all or go via DMigrator |
| **`etl_data_ingestion_metadata` multi-source limitation** | Works today only when all source tables load under a **single** source batch |

### Client sign-off status

**ABC is NOT signed off by the client.**

A full technical walkthrough of every component was given in person at a US collocation (Aishwarya
presented online; the client was onshore). Attendees named: **Bogdan, Tina, Chris**. Feedback was
incorporated — notably the requirement that batch and job **names** appear in notifications and table
entries.

Sign-off was **never initiated**, because first-time incremental and history/catchup remain pending.
The route: finish first-time incremental, then approach **Nithika or Swayam** to arrange client review
and sign off the LLD and ABC.

### Status tracker snapshot (4 Aug 2026, the dedicated ABC tab)

| Item | Status |
|---|---|
| Metadata entries | Done, sent for review |
| All ABC components build | **80%** — to be revisited for first-time incremental |
| UT | **95%** — document written and shared; component-level review done; end-to-end lead review uncertain (Swayam had read it and called it exhaustive) |
| Lucid flow | Done — **not** updated for H/C/I |
| LLD | Done — H/C/I in text only |
| UT document | Done |
| History / catchup load | **Not completed** |
| First-time incremental | **Not completed** |
| DQ automation in the main mapping | **Parked** |
| New Aurora database setup | **Blocked on Zone 1** |
| Parameter file location / parameterisation | Done |
| ABC data model | Updated — two more tables added |
| Folder structure for history-load components | Undecided — history components would be domain-specific |

---

## 17. People, external documents, and where things live

### People

| Name | Role in ABC |
|---|---|
| **Aishwarya** | Built the framework; gave every KT in this set; owned the LLD, Lucid and UT document |
| **Riya / Liya** | Co-owner of the framework; **took over the pending H / C / I implementation** at KT 1 |
| **Swayam** ("Swam") | Design POC — **escalate here first** |
| **Nithika / Nitvika / Netwika** | Design POC — escalate after Swayam. Made the `audit_batch_id`, surrogate-key and `valuation_date` calls |
| **Saurabh** | Owns the rerun cleanup process (with Swayam) — **outside ABC** |
| **Bharat** | Wrote the **source qualifier query**, the deduplication logic, and the **RA temp→main** component; gave a separate KT on the query |
| **Gayathri** | IDMC **connections** creation; CCO functional information; GitHub PR process |
| **Deepankar**, **Durkesh** | **Stonebranch** — how the prerequisite and batch task flows are interrelated at scheduler level |
| **Vidya**, **Vaishnavi** | POCs for the **ABC data / new Aurora database** question |
| **Vaibhav**, **Anand** | Access assignment |
| **Kushi**, **Kavya** | Reverse engineering (with Gayathri); later moved to build |
| **Bogdan**, **Tina**, **Chris** | Client side — attended the technical walkthrough and gave feedback |

### Documents — all external to this repository

| Document | What it is |
|---|---|
| **LLD** (Word) | ⭐ **The single source of truth.** Every table description, every column description with sample values, all activities across all phases. **Recent changes are highlighted YELLOW.** Contains the data model link and the Lucid flow link |
| **Lucid chart** | The coded framework as a flow diagram. ⚠️ **Primarily drawn for the SUCCESS path**; not updated for H/C/I or the Sept changes |
| **ABC data model** | PK/FK diagram. Metadata tables in **red**, runtime tables in **green**. ⚠️ Does not yet include `batch_sourcing_stats` |
| **Scenarios workbook** (`ABC_load_across_phases_scenrios.xlsx`) | How each table should be populated per scenario — success, restart, rerun, incremental, catchup — including the config table and the ETL ingestion window |
| **Metadata entries Excel** | The CONCAT-formula INSERT generators, per table, environment-portable |
| **Runtime entries Excel** | The unit-test mock-entry scripts (a separate workbook from the above) |
| **UT document** | Per-run evidence of the entries made and how they change at each phase. Described as *"very exhaustive"* |
| **UID generation doc** | How the UUID is generated via the Aurora built-in function |
| **Data share doc** | Kept **separate** because tuning ABC for data share was still under discussion with no conclusion |
| **The ABC change mail chain** | ⭐ **The de-facto change log.** Every framework change is announced here to a DL |
| **Daily status tracker, ABC tab** | Build/UT/design completion percentages |

### Recorded KT sessions (Deloitte SharePoint / VDI)

Beyond the 16 transcripts here, Aishwarya enumerated a folder of recordings:

- Framework high-level flow walkthrough (older but complete)
- ABC Zone1 framework — the Lucid-level walkthrough given to the testing team
- How to **copy ABC components** from the common folder into a domain folder, and what to change
  (recorded against a claims table — *"this is the prerequisite, use it as the first step"*)
- Two recordings on **ABC metadata entries**
- **IDMC build — how to integrate ABC inside the mappings** (Parts 1 and 2)
- **ABC task flow implementation end-to-end + how to create the parameter file** (CCO)
- **How to make dummy mock-up entries in the ABC RUNTIME tables for unit testing**
- **Bharat's KT** on framing the source qualifier query and the deduplication logic
- GitHub / pull-request process — **no known recording**; ask Gayathri

⚠️ Several of these links were inaccessible during the KT sessions themselves.

### Appendix — the unit-test mock-entry recipe

Because first-time-incremental logic doesn't exist in code, and Zone 1's own runtime entries are not
in a usable condition, runs are tested against hand-made rows. **All ABC tables have FK constraints**,
so nothing can be inserted into an FK column without its parent row existing — which is why every row
in the chain must be created in order.

**Zone 1 writes TWO rows per batch run and TWO per job run**, sharing the same `execution_run_id` and
`instance_id`. Mocks must reproduce that shape.

**Seven inserts, for a single-source table:**

*Source (Zone 1) side — first-time incremental:*
1. `batch_run_stats` row 1: `batch_run_id` = `GEN_RANDOM_UUID()`, `execution_run_id` =
   `GEN_RANDOM_UUID()`, `instance_id` = a hard-coded dummy, `batch_start_time` set, `batch_end_time`
   NULL, **status `'Started'`**, `batch_rerun_flag` `'N'`, audit columns.
2. `batch_run_stats` row 2: **query the table to get the execution_run_id generated in step 1 and
   reuse it**; `batch_start_time` NULL, `batch_end_time` set, **status `'Completed'`**.
3. `job_run_stats` row 1: same execution_run_id, dummy `job_instance_id`, `job_start_time` set,
   status `'Started'`.
4. `job_run_stats` row 2: `job_end_time` set, status `'Completed'`.
   **job_run_ids differ between the two rows; execution_run_id, instance_id and job_id are the same.**
   > ⚠️ **Which job_id to mock**: Zone 1 has several job_ids per table. Mock **only** the one whose
   > `job_name` is the **"raw to current data movement"** step — the only one ABC's status logic looks
   > at.

*Target (Zone 2) side — first-time incremental:*

5. `batch_run_stats`: **one row only** (Zone 2's pattern); `batch_id` + a `GEN_RANDOM_UUID()`
   `execution_run_id`.
6. `job_run_stats`: the **same** execution_run_id as step 5, the job_id, start/end times, status
   `'Completed'`.
7. `etl_data_ingestion_source_window`: one row per source table. execution_run_id from step 5,
   batch_id, target_job_id, the job_run_id from step 6, target/source table names,
   **`source_job_run_id` = the job_run_id of the source row whose status is `'Started'` (step 3)**,
   status `'Completed'`, and **both `sourcing_start_datetime` and `sourcing_end_datetime` set to
   `1900-01-01`** so the run takes all the data from the source.

Then **repeat the source-side pair (and the target batch row) for the CURRENT run**, so there is both
a "previous" run and a "current" run. If Zone 1's real entries **are** valid for a table, skip the
mocking: use the latest real entry as the current run and the one before it as the first-time
incremental.

**If testing from the JOB-level task flow** rather than the batch task flow — which is the norm,
because multiple people test concurrently — batch preload never runs, so you must **manually insert
the `batch_run_stats` row with status `'Started'`** that batch preload would have created, and supply
every input field on the job task flow's Start step by hand.

⚠️ **Unit testing only. These entries must not be made in any other environment.**
