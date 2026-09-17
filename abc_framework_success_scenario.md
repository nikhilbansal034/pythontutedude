# ABC Framework — Complete Reference

Companion notes to [`abc_framework_deck.html`](abc_framework_deck.html) (the visual deck, currently covering only
the Success scenario). This file is the full, top-to-bottom technical reference: every table, every column,
every naming convention, every formula, every phase of the batch/job lifecycle, every execution-type scenario
(including the ones not yet built into the deck), and the current state of every open question.

**Sources**: the original design workbook (`ABC_load_across_phases_scenrios.xlsx`) and 17 KT transcripts in
`KT transcripts/` (all read in full — see the per-topic extraction notes in `claude/transcript_notes/` for
timestamped detail and verbatim quotes). Where transcripts disagree or audio was ambiguous, both readings are
given and flagged — nothing below is invented to fill a gap.

---

## 1. What ABC is

**Audit Balancing Control** — the metadata-driven orchestration layer every Zone1→Zone2 ETL job integrates
with, so individual jobs don't separately implement row-count tracking, restart handling, DQ enforcement, or
balance reconciliation. The stated design goal: any job, in any wave/domain, should be able to plug into the
framework rather than hand-build this logic — the only real per-job integration effort is wiring the framework
into that job's task flow; the framework itself owns counts, restart state, and audit trail.

A **batch** = the unique combination of **(source, domain, application layer)** — e.g. source=CMPM,
domain=Broker, layer=Data Domain → one batch. A domain can have multiple batches if it has multiple distinct
sourcings (e.g. one source feeding both an "Account" batch and a "Contract" batch). Today every asset uses the
**Data Domain** layer only; a **Functional** layer exists in the model but is unpopulated.

A batch is an umbrella of **jobs** (one job per target table). Every job runs through (up to) five phases:
**batch preload → job preload → job load → job post load → batch post load**. Two workflow levels exist per
batch: a **job-level workflow** (one per table) and a **batch-level "wrapper" workflow** that invokes all job
workflows as sub-task-flows — only the batch-level wrapper is directly triggered by the scheduler.

---

## 2. Architecture — Aurora vs. Snowflake

**Aurora** (AWS-managed, Postgres-compatible) is a real OLTP engine — proper constraint enforcement, built for
frequent small transactional writes. It is the **system of record for every ABC control/metadata/status table**
today, sitting in one shared "default" database (a dedicated ABC-only Aurora database was still pending/under
discussion as of the most recent KTs — not yet stood up). Zone2 was directed to **reuse the same Aurora ABC
schema Zone1 already had** (Zone1's ETL is AWS-native/Lambda-Glue-based and their ABC tables already lived
there) rather than build a separate one.

**Snowflake** holds the actual Zone2 business/target tables, and is OLAP — decoupled storage/compute, no
enforced PK/UNIQUE constraints (informational only).

**Why Snowflake also gets a set of *temporary* ABC tables**: the framework relies on **full push-down
optimization (PDO)** — an all-or-nothing load where source and target sit in the *same* database engine, so
record-count math, DQ checks, and balance reconciliation can execute natively during the load. Since the
Zone2 target tables are in Snowflake, a handful of ABC tables get a **Snowflake-side temporary/staging copy**
used only during job load, so that math can run there instead of round-tripping to Aurora mid-load:

| Aurora table (system of record) | Snowflake counterpart | Nature |
|---|---|---|
| `job_run_stats` | `job_run_stats` temp table | Transient — cleared/reloaded per job_id each run |
| `job_rule_error_detail` | `job_rule_error_detail` **temp** table, *and* a **permanent** Snowflake copy | The only table confirmed permanent in **both** databases |
| `balance_reconciliation_stats` | `balance_reconciliation` temp table | Transient |
| *(no Aurora equivalent)* | **MAIN_RI_TABLE** (a.k.a. "RA"/"main RI" table) + its temp companion | Snowflake-only, no Aurora counterpart at all |
| `etl_data_ingestion_source_window` | Same-named Snowflake copy | Dual-written to both — needed because the sourcing-window join happens inside a Snowflake-side source-qualifier query |

**What actually writes the Snowflake temp-table contents back into Aurora**: the **job post load** step,
explicitly — an ETL mapping/sub-task-flow that reads the Snowflake temp tables, computes final flags/counts,
and issues the real INSERT/UPDATE against the Aurora tables. This is a deliberate, code-level write-back step,
**not** an automatic mirror or Snowflake "Dynamic Table" feature — no KT transcript ever used that term, and
none described an automatic sync mechanism. (Two transcripts had genuinely ambiguous audio on whether the
Snowflake object is literally called a "temp table" vs. some other construct — flagged here as a minor
terminology point still worth a direct SME confirmation, not a substantive gap.)

**Target-state plan (not yet built)**: each Snowflake business domain gets its own dedicated `ABC` schema
holding these tables; today everything points at one shared testing schema.

**Time zones**: Aurora, all ABC control data, and every ETL extraction/audit column are meant to run in **UTC**.
Actual business data-value fields are deliberately left in their native/source time zone (business signed off
that source systems don't need normalizing). IDMC/Informatica and Teradata run natively in EST; Snowflake/
Aurora/S3-Iceberg run in UTC — extraction logic always keys off the UTC audit columns of the already-ingested
tables, never off native business date fields, to avoid the mismatch.

---

## 3. Naming conventions

| Object | Convention | Example |
|---|---|---|
| `batch_name` | `Zone<N> <Source><Domain>` **or** `Z2_batch_<source>_<domain>` (both forms seen across KTs — appears to vary by when/who authored the entry; not yet reconciled to one standard) | `GRS-Zone2-ADW_Producer-Datadomain`, `Z2_batch_CMPM_broker` |
| `batch_description` | Templated: "Batch to load [source] tables for [domain] in zone2 data [layer]" | — |
| `job_name` | `Z2_job_<source>_<domain>_<table>_load` | `Z2_job_CMPM_broker_broker_party_address_load` |
| `job_description` | Templated: "Job to load [table] from [source] in [domain] data domain [layer]" | — |
| `workflow_name` (job level) | Standard template, e.g. `TSKFL_load_<target_domain>_<source_domain>` | — |
| `wrapper_workflow_name` (batch level) | Same naming family, one level up — wraps all job workflows as sub-task-flows | — |
| Snowflake connection name | `CONT_EJT_<domain>` — a hard client requirement, applied manually per domain (6–7 components hold a Snowflake connection needing this rename) | `CONT_EJT_BROKER`, `CONT_EJT_CLAIMS` |
| IDMC component folder structure | Shared ABC components live in a common `DI Common` / `DA_Common > ABC` folder; each new domain **copies** (not references) these into its own domain folder, then updates only the connection name | — |

---

## 4. Table catalog — full detail

Every table below: purpose, database location, and full column list with meaning. "Formula" callouts capture
derivation logic where one exists. Column names vary slightly in spelling/case across sources (transcripts are
inconsistent) — the form used here is the most common; variants are noted where materially different.

### 4.1 Static / config tables (Aurora only — populated by manual DML today; long-term plan is Liquibase-managed, not yet built)

#### `batch_metadata`
Purpose: static definition of a batch. One row per (source, domain, layer) combination.

| Column | Meaning |
|---|---|
| `batch_id` | PK, auto-increment |
| `batch_name` | See naming conventions |
| `batch_description` | Templated free text |
| `is_active_flag` | Y/N — **gates whether this batch is picked up at all**; N means no batch_run happens, ever, for it |
| `email_id` | Reserved for future notification wiring — unused today |
| `source_name` | e.g. "CMPM" |
| `domain_name` | e.g. "Broker" |
| `application_name` | Currently always unused/null |
| `application_layer_name` | "Data Domain" (only value in use) or "Functional" (modeled, not used) |
| `application_dependency_name` | The Zone1 application this batch depends on |
| `application_source_batch_id` / `application_dependency_batch_id` | The **Zone1 (source) batch's own `batch_id`** — used for the cross-zone dependency lookup |
| `target_zone` | e.g. "Zone2" |
| `zone_load_frequency` / `load_frequency` | How often the batch runs |
| `load_schedule_time` / `batch_scheduled_time` | Currently **dummy placeholder values** pending real scheduler (StoneBranch) integration |
| `load_expected_completion_time` | Also currently a dummy placeholder |
| audit columns | `audit_create_datetime`, `audit_created_by_user_id`, `audit_update_datetime`, `audit_updated_by_user_id` — via Aurora's UTC `CURRENT_TIMESTAMP` |

**Lookup formula**: `batch_id` is resolved via the 4-column combination `source_name + domain_name +
application_layer_name + target_zone`.

**Multi-source note**: today's design assumes **one source : one batch** (`application_dependency_name` =
`source_name`). True multi-source-per-batch support is explicitly *not yet built* — deferred until a source
system actually needs it. (The new `batch_sourcing_stats` table, §4.2, is the first concrete step toward this.)

#### `job_metadata`
Purpose: one row per job (= one target table load) under a batch.

| Column | Meaning |
|---|---|
| `job_id` | PK, auto-increment |
| `job_name` | See naming conventions |
| `job_description` | Templated |
| `is_active_flag` | Y/N — same on/off semantics as `batch_metadata` |
| `batch_id` | FK |
| `target_table_name` / `target_schema_name` / `target_database_name` | Where this job loads to |
| `target_load_type` | Type0 / Type1 / Type2 / Append-only |
| `workflow_name` | Job-level task flow name |
| `wrapper_workflow_name` | Batch-level task flow name |
| `count_threshold_indicator` | Y/N — enables **count-type** balance reconciliation for this job |
| `amount_balance_check_indicator` / `amount_balance_threshold_indicator` | Y/N — enables **amount-type** balance reconciliation |
| `source_to_target_layer` / `target_zone_layer` | e.g. "Refined to Zone2 data domain" — Zone1-relevant field, null for pure-Zone2-only context |
| audit columns | same pattern as above |

**Formula**: balance reconciliation runs for a job if **either** `count_threshold_indicator` or
`amount_balance_check_indicator` = Y; if both are N, all balance-recon steps are skipped entirely for that job.
Similarly, if a job has zero active `job_rule_assignment` rows, all DQ-related steps (preload/load/postload)
are bypassed for it.

#### `job_rule_master`
Purpose: catalog of every DQ/RI rule *type*, defined once and reused across every job that needs it (no
duplication per table).

| Column | Meaning |
|---|---|
| `rule_id` | PK, auto-increment |
| `rule_name` | e.g. "Null check", "S3 file size check" |
| `rule_scope` | "Column" or "Table" |
| audit columns | — |

As of the most recent KTs this table had only **one dummy entry** in the environment observed — new rules need
to be explicitly added as they come up; flagged in-transcript as a functionality gap the wider build team
hadn't yet addressed.

#### `job_rule_assignment`
Purpose: binds one `job_rule_master` rule to one job + target column, with a severity.

| Column | Meaning |
|---|---|
| `job_rule_assignment_id` | PK |
| `job_id` | FK |
| `rule_id` | FK to `job_rule_master` |
| `target_column_name` | Column the rule checks |
| `validation_type` | "pre" or "post" — **informational only, not read by any code path** |
| `pattern_available` | Y/N — currently always N/unused |
| `pattern_name` | Unused |
| `error_severity_code` | **Critical** or **Informational** — see §7 for exact behavioral difference |
| `error_message_text` | Hardcoded per rule type, e.g. "null values found in the key" |
| `is_active_flag` | Y/N |
| audit columns | — |

**Important operational gotcha (confirmed in KT4)**: these checks are **hard-coded per column inside the ETL
source-qualifier-query expression** — they are not dynamically re-derived from this table at runtime. If a rule
is later deactivated here (`is_active_flag = N`), the mapping will **not automatically stop enforcing it** — a
developer must separately edit the query. Treat `is_active_flag` on this table as documentation of intent, not
a live kill-switch.

#### `balance_reconciliation_metadata`
Purpose: which jobs need $/count reconciliation, and the threshold.

| Column | Meaning |
|---|---|
| `balance_reconciliation_metric_id` | PK, auto-increment |
| `job_id` | FK |
| `description` | Templated free text, e.g. "Reconcile distinct count of broker_party_identifier from source to target" |
| `balancing_type` | "Count" or "Amount" |
| `target_database_name` / `target_schema_name` / `target_table_name` / `target_column_name` | **Present but NOT actually used** — the comparison logic is hardcoded into the reusable balance-reconciliation component instead |
| `source_query` / `target_query` | **Also present but unused**, same reason |
| `threshold_type` | "Value" (absolute) or "Percentage" |
| `threshold_value` | e.g. `5` (meaning 5% for a percentage-type threshold on the CC/policy POC) |
| `is_active_flag` | Y/N |
| an ordering column | Used when multiple metrics apply to one job |
| audit columns | — |

Thresholds are **business-owned, case-by-case** — no framework default. Some amount fields (e.g. certain
premium/claim types) may be configured to tolerate zero variance; others 1–2%. A count-only table with no
natural amount column can get a "dummy" balance metric purely to exercise a distinct-count-of-1-column check.

#### `etl_data_ingestion_metadata`
Purpose: static source→target job mapping. One row per (target table × source table) pair — a target fed by 5
source tables gets 5 rows.

| Column | Meaning |
|---|---|
| `target_batch_id` | — |
| `target_job_id` | — |
| `target_table_name` | — |
| `source_name` | — |
| `source_table_name` | — |
| `database_name` / `schema_name` / `source_object_name` | Added recently, specifically to disambiguate a source table name that exists identically across multiple schemas/databases |
| `active_indicator` | Y/N |
| audit columns | — |

#### Unnamed "batch prerequisite" / dependency-gating table — **name not confirmed**
Purpose: appears to be the actual object backing the Zone1-dependency + "previous run completed" checks
described in §6 (Gate 1/2). No transcript gave this table a clean, confirmed formal name — described loosely
as "config load" in one KT. Columns discussed: `target_batch_id`, `source_batch_id`, `source_name`,
`domain_name`, a "mandatory time check" active-entry flag, and `dependency_batch_timestamp` (the cutoff time).
**Action item, not yet resolved**: confirm this table's real name and full column list with the ABC team before
adding it as a first-class entry in the deck's table catalog.

---

### 4.2 Runtime / status tables (Aurora system-of-record; Snowflake temp copies noted where they exist)

#### `batch_run_stats` (Aurora)
Purpose: one row per batch attempt; carries the batch-level thread (`execution_run_id`) and (historically) the
sourcing window.

| Column | Meaning |
|---|---|
| `batch_run_id` | PK, auto-increment per insert |
| `batch_id` | FK |
| `execution_run_id` | Stable across a Restart of the same logical run; a **new** value is generated for every genuinely new run or manual Rerun/History/Catchup/FTI entry |
| `source_batch_execution_run_id` | The dependency batch's latest `execution_run_id` at the time of this run — **single-source assumption**; superseded for multi-source cases by `batch_sourcing_stats` below |
| `batch_rerun_flag` | See the code-value legend in §9 — **N / Y / Z / H / C / I**, not a plain Y/N |
| `status` | `Started` / `Completed` / `Failed` (Zone2 side never uses `Partial` at the batch level — that's Zone1-only, see §6) |
| `batch_start_time` / `batch_end_time` | — |
| `sourcing_start_time` / `sourcing_end_time` | Now effectively duplicated/superseded by `batch_sourcing_stats` for any batch with more than one source dependency |
| audit columns | — |

**Zone1 vs. Zone2 behavioral asymmetry (worth knowing when reconciling row counts)**: Zone2 makes **one** row
per batch run (insert at preload, update at postload). **Zone1 makes two separate rows** per batch run — a new
insert at its own preload *and* another new insert at its own postload — linked by the same
`execution_run_id`/`instance_id`. Because of this, Zone2 code that needs "Zone1's latest status" queries a
**consolidated view** built on top of Zone1's `batch_run_stats`/`job_run_stats`/`job_error_stats` (three such
views exist), not the raw tables directly.

#### `batch_sourcing_stats` (Aurora) — **new table, added ~2 weeks before the Sept 2026 KTs**
Purpose: introduced because the original design assumed a Zone2 batch depends on exactly **one** Zone1 batch
run; the real requirement is that it can depend on **multiple**. Splits sourcing-window tracking out of
`batch_run_stats` into its own table — one row per (target batch, source batch) pair.

| Column | Meaning |
|---|---|
| `target_batch_id` | FK |
| `source_batch_id` | — |
| `source_batch_execution_run_id` | (worded slightly differently across sessions — "source execution run ID") |
| `sourcing_start_date_time` / `sourcing_end_date_time` | — |
| `batch_run_id` | FK to `batch_run_stats` — auto-increment surrogate for the sourcing-stats row itself |
| audit columns | — |

**Worked example given in-transcript**: asset "CRC" — `target_batch_id = 455`, `source_batch_id = 151`, a
one-time manual entry (only one source currently active), placeholder window `1900 → Aug 31` (the batch's
original inception window).

**Migration impact — this changes existing task-flow parameters**: every job-level task flow that previously
read 3 fields directly off `batch_run_stats` ("source batch ID, source execution run ID, source batch end
time") must instead read **2 new parameters** sourced from `batch_sourcing_stats`. This was, as of the KT date,
already rolled out for some domains (Client, Contract) and actively being applied to others — treat any
documentation or code referencing the old 3-parameter pattern as **stale** unless confirmed otherwise for a
specific domain. For **First-Time-Incremental** specifically, the manual sourcing-start entry must now go into
**both** `batch_run_stats` and `batch_sourcing_stats`.

#### `job_run_stats` (Aurora, system of record) + Snowflake **temp** counterpart
Purpose: one row per job attempt; final counts and status land here. The Snowflake temp version holds
in-flight counts computed during job load, before job post load writes them back to Aurora.

| Column (Aurora) | Meaning |
|---|---|
| `job_run_id` | PK |
| `execution_run_id` | FK / thread column |
| `job_instance_id` | Zone1-relevant only; null for Zone2 |
| `job_id` | FK |
| `job_start_time` / `job_end_time` | — |
| `status` | `Started` / `Completed` / `Failed` (never `Partial` at job level) |
| `target_table_name` / `target_schema_name` / `target_database_name` | Informational only |
| `source_record_count` | — |
| `target_insert_record_count` / `target_update_record_count` / `target_unchanged_record_count` | — |
| `target_error_record_count` | Records excluded by a **Critical** DQ failure |
| `target_delete_record_count` | **Hard-coded to 0** — delete/soft-delete propagation is not implemented for any asset yet |
| `target_RA_record_count` / RI count | Records routed to the referential-integrity queue (§4.2, MAIN_RI_TABLE) |
| `stage_table_record_count` | Used for the Restart skip-logic (§10) |
| `record_count_balancing_flag` | Y/N — see formula below |
| `critical_error_check_flag` | Y / N / **X** (X = no DQ checks assigned to this job at all) |
| `informational_error_flag` / `informational_check_error_flag` | Y / N / X, same 3-state pattern |
| `balance_flag` | Overall balance-reconciliation flag, Y / N / X |
| `audit_delete_indicator` | **Hard-coded to N** — same reason as delete count |
| audit columns | — |

**Formula — `record_count_balancing_flag`**:
```
record_count_balancing_flag = 'Y'  if  source_record_count
                                      = target_insert_record_count
                                      + target_update_record_count
                                      + target_unchanged_record_count
                                      + target_error_record_count      (critical-DQ-excluded)
                                      + target_RA_record_count          (RI-queue-routed)
                               else 'N'
```

**Snowflake temp table columns**: `job_id`, `execution_run_id`, `job_run_id`, `source_record_count`,
`target_unchanged_record_count` (+ the other in-flight counts above), audit columns. Cleared (deleted by
`job_id`) before each job run and reloaded fresh — the temp table is disposable scratch space; Aurora holds the
durable truth.

#### `job_rule_execution_log` (Aurora only — **no** Snowflake temp counterpart)
Purpose: one row per (job run × rule assignment); the aggregate pass/fail rollup for one rule on one run.

| Column | Meaning |
|---|---|
| `job_rule_execution_id` | PK |
| `job_rule_assignment_id` | FK |
| `job_run_id` | — |
| `start_time` / `end_time` | — |
| `status` | `Started` → `Passed` or `Failed` |
| `error_message` | Null if Passed |
| `error_execution_details` | Count of failed records for that rule; null if Passed |

**Formula**: for a given (`execution_run_id`, `job_run_id`, `job_rule_assignment_id`), if the corresponding
`job_rule_error_detail` rows for it total **zero** → `status = Passed`; otherwise → `status = Failed`, with the
count and a message populated.

On Restart, existing rows for the same `job_run_id` are **deleted and reinserted fresh** (status reset to
Started) rather than reused.

#### `job_rule_error_detail` (Aurora, **permanent**) + Snowflake **temp** + Snowflake **permanent** copy
Purpose: record-level, column-level DQ failure detail — one row **per failing column per failing record** (not
one row per failing record).

| Column | Meaning |
|---|---|
| `source_database_name` / `source_schema_name` / `source_table_name` / `source_column_name` | — |
| `source_record_identifier` | The Zone1 `GRS_unique_id` audit column; if the record spans multiple source tables, stored as `sourcetable1_col:value\|sourcetable2_col:value` (colon separates column:value, pipe separates multiple source components) |
| `source_error_text` | — |
| `job_rule_assignment_id` / `rule_id` | FKs |
| `execution_run_id` / `job_id` / `job_run_id` | Thread columns |
| `severity` | Critical / Informational |
| audit columns | — |

**Worked example (from KT)**: 3 records fail rule 1 (column 1); 1 of those 3 *also* fails rule 2 (column 2) →
`job_rule_execution_log` shows "3 failed" for rule 1 and "1 failed" for rule 2, while `job_rule_error_detail`
gets **3 + 1 = 4 total rows**.

This is the one table confirmed **permanent in both Aurora and Snowflake** — the Snowflake copy is treated as
append-only (never purged per job_id, unlike most other ABC tables which get cleared/reloaded per run). A
*separate* Snowflake **temp** copy also exists, used transiently to make the record→column transposition
easier to do in SQL before the final write into the permanent tables.

#### `balance_reconciliation_stats` (Aurora) + Snowflake temp counterpart
Purpose: source vs. target reconciliation result, per metric, per job run.

| Column | Meaning |
|---|---|
| `balance_reconciliation_metric_runid` | PK |
| `balance_reconciliation_metric_id` | FK |
| `execution_run_id` / `job_run_id` | Thread columns |
| `source_value` / `source_aggregated_text` | Pipe-delimited `column:value\|column:value…` string (multiple metrics on one job concatenate this way) |
| `target_value` / `target_aggregated_text` | Same shape, target side |
| `balancing_flag` / `balance_flag` | Y if source and target aggregates match exactly |
| `out_of_balance_value` | Numeric difference (source − target) when not balanced |
| `within_threshold_flag` / `threshold_flag` | Y if the difference is within the configured threshold |
| `valuation_date` | Intentionally **always left NULL** ("need not be populated," per the design owner) |
| audit columns | — |

**Formula**:
```
balance_flag     = 'Y'  if source_aggregate == target_aggregate,  else 'N'
out_of_balance_value = source_aggregate - target_aggregate      (only meaningful when balance_flag = 'N')
threshold_flag   = 'Y'  if ABS(out_of_balance_value) is within threshold_value
                          (absolute, or as a % of source if threshold_type = Percentage)
                   else 'N'
```

**Mechanics feeding this table (from the source-to-stage mapping, at job-load time)**:
- Computed via an aggregator transformation grouped by `job_run_id` (a constant per run, used purely to force
  one aggregate row), summing each amount/count column with an NVL-style expression so an all-NULL column sums
  to 0 rather than NULL.
- **Decimal precision convention: `NUMBER(28,6)`** (Snowflake's max total precision is 28; 6 digits reserved
  for scale) — flagged in-transcript as something that "may be revisited" if requirements change.
- **Only runs against "valid" records** — explicitly excludes records dropped by a Critical DQ failure and
  records routed to the RI/RA queue from the source-side aggregate. Balance metrics are computed *net* of those
  exclusions, not against the raw source count.
- **Column-name handling gotcha**: because source and target column names sometimes differ (e.g. source `AMT`
  vs. target `AMOUNT`), the aggregate-expression **key must always use the target column name**, while the
  **value** summed is whatever is actually being loaded into stage. This must stay consistent across
  `balance_reconciliation_metadata`, the parameter file, and the mapping's hardcoded column references, or the
  match silently fails.
- **SCD Type-2 filter nuance**: this domain uses separate insert-flag/update-flag columns (not a single
  active/expiry indicator), so the target-side aggregate filter must select only the current
  active/insert-or-update row per business key, not the full version history. The filter itself
  (`target_balance_recon_filter`, a parameter-file field) is metadata-driven per table; a placeholder `1=1` /
  `TRUE` was used during testing.
- If a domain hasn't implemented balance reconciliation for a table, its parameter file is otherwise identical
  — it simply omits the `target_expression`/`target_balance_recon_filter` fields.

#### `etl_data_ingestion_source_window` (Aurora **and** Snowflake — dual-written)
Purpose: the actual per-source-table window a job reads its date range from. This is the mechanism behind the
Q2 "does Zone1 Partial let Zone2 proceed" answer — see §6.

| Column | Meaning |
|---|---|
| `execution_run_id` | — |
| `target_batch_id` / `target_job_id` / `target_table_name` | — |
| `source_table_name` | — |
| `job_run_id` | The **source (Zone1)** job's run id |
| `job_status` | — |
| `sourcing_start_time` / `sourcing_end_time` | — |

**Formula**: for each source table a job depends on, find the one Zone1 job whose name matches the
**hard-coded** "raw to curated/current data movement" job name for that table (Zone1 creates 4 separate
`job_metadata` entries per source table for different pipeline stages — only one of the four is the one Zone2
actually checks). If that job's latest run `status = Completed` **and** `job_end_time ≤ source_batch_end_time`
→ mark this source `Completed`, `sourcing_end_time` = that job's own `job_end_time`. Otherwise mark this source
`Failed`, leave the times **NULL**, and fail the whole target job (no partial load attempted).

**Restart-specific partial-load detection**: count expected source tables (from `etl_data_ingestion_metadata`)
vs. rows already present here for the current `job_run_id` — zero rows = load fresh; counts match = skip
(already fully loaded); partial = delete the partial rows and reload.

**Not used** for History, Catchup, or (originally) First-Time-Incremental loads — those take their sourcing
dates straight from the manually-entered `batch_run_stats`/`batch_sourcing_stats` row instead (First-Time-
Incremental is the one exception that *does* populate this table too, via new custom logic — see §10).

**Fragility flagged in-transcript**: the hard-coded job-name matching means any Zone1 naming change would
silently break Zone2's dependency detection — worth calling out as a risk in the deck.

#### `job_error_stats` (Aurora)
Purpose: framework/execution-level error log. **Not** for DQ rule failures (those go to
`job_rule_error_detail`/`job_rule_execution_log` instead) — this table is specifically for "something in the
framework itself broke."

| Column | Meaning |
|---|---|
| `job_error_id` | PK, UUID via `gen_random_uuid()` |
| `job_id` / `job_run_id` | — |
| `error_type` / `error_code` / `error_message` | Sourced from the **static parameter file** — some values hardcoded per scenario, some built dynamically (concatenating `batch_name`, `job_name`, `previous_job_run_id`) |

**Fires on**:
1. Any job/stage/target load failure (any of the three Failed triggers in §8).
2. A source-table dependency failure (per `etl_data_ingestion_source_window` logic above).
3. **Restart-specific**: retroactively, when the *previous* run was interrupted abruptly (e.g. a network drop)
   and got stuck at `status = Started` without ever being marked `Failed`. On the restart attempt, the
   framework logs the missed entry here (`error_type` = "network error" is the concrete example given) — and,
   in this specific case, the prior `job_run_stats` row is **not** marked Failed and **is reused as-is** for
   the restart (no new row inserted).
4. **Explicit gap, not new**: a true infrastructure/network failure that prevents the framework code from
   running *at all* cannot be captured here — there's no code path to log an error nobody's code ever executed.

#### `MAIN_RI_TABLE` (Snowflake only — **no Aurora equivalent**) + its temp companion
Purpose: referential-integrity reprocessing queue. Holds records whose foreign-key/parent-table lookup failed
at load time, so they can be automatically resolved once the parent record eventually arrives.

**Naming caveat**: no transcript ever says "MAIN_RI_TABLE" literally — it's called "RA table" / "main RA table"
/ "RI report" throughout. Functionally it matches what this doc (and the deck) call `MAIN_RI_TABLE`, but the
name should be confirmed directly with the team before being presented as settled terminology.

| Column | Meaning |
|---|---|
| `job_id` / `target_table_name` | — |
| `child` | Variant/JSON: `{source_table_name + GRS_unique_id}` — a UUID-style key identifying the child record |
| `parent` | Variant/JSON: `parent_table_name`, `parent_business_key_name`, `parent_business_key_value` — informational, taken from the failed lookup |
| `process_flag` | **NULL** = unresolved (still being retried); **'Y'** = resolved |
| join columns | `zone1_job_id`, `zone1_uuid`, `zone2_job_id`, `zone1_table_name`, `zone2_table_name` — used for the FULL JOIN between the temp and main tables |
| audit columns | — |

**Mechanics**:
1. **Load time**: a record whose FK/parent lookup fails is — **per the current (superseded) requirement** —
   still **loaded into target regardless**, and *additionally* routed to the temp RI table with `process_flag`
   defaulted to NULL. *(Older design intent, now superseded, was to reject/withhold such records instead —
   see §11.)*
2. **Job post load, every run**: FULL JOIN the temp RI table against `MAIN_RI_TABLE`, keyed on
   job_id + target_table_name + UUID:
   - Present in temp, not in main → **INSERT** into `MAIN_RI_TABLE` (a newly-discovered unresolved issue).
   - Present in main, not in temp (i.e. not found again this run — its parent has arrived) → **UPDATE**
     `MAIN_RI_TABLE.process_flag = 'Y'`.
   - Present identically in both → no change.
3. **Every subsequent run**: the source-to-stage mapping re-pulls every `process_flag IS NULL` row and
   re-attempts the parent-table join; if it now resolves, the **already-loaded** target record is **updated**
   with the real FK value (it was loaded speculatively at step 1, remember — this step corrects it).
4. The temp table itself is cleared (deleted by job_id) and reloaded fresh every run — pure scratch space;
   `MAIN_RI_TABLE` carries the durable, cumulative truth of what's outstanding vs. resolved.

---

## 5. How the tables link (foreign keys and threading)

| Config table | → | Runtime table | via |
|---|---|---|---|
| `batch_metadata` | → | `batch_run_stats` | `batch_id` |
| `batch_run_stats` | → | `batch_sourcing_stats` | `batch_run_id` |
| `job_metadata` | → | `job_run_stats` | `job_id` |
| `job_rule_assignment` | → | `job_rule_execution_log` | `job_rule_assignment_id` |
| `balance_reconciliation_metadata` | → | `balance_reconciliation_stats` | `balance_reconciliation_metric_id` |
| `etl_data_ingestion_metadata` | → | `etl_data_ingestion_source_window` | `target_job_id` |

Two thread columns chain everything within one attempt:
- **`execution_run_id`** — shared by `batch_run_stats`, `batch_sourcing_stats`, and every `job_run_stats` row
  under that batch attempt. Described in-transcript as "the single unifying key... every single table in your
  entire runtime tables is stacked with this particular value."
- **`job_run_id`** — shared by `job_run_stats`, `job_rule_execution_log`, `job_rule_error_detail`, and
  `balance_reconciliation_stats` for that specific job attempt.

---

## 6. Zone1 → Zone2 dependency and the "Partial" status

Zone1 batches can end in **four** states: `Started`, `Completed`, `Failed`, **`Partial`** (Partial = some of
that batch's table loads succeeded, some failed). Zone1's own *job*-level status, by contrast, is only ever
`Completed` or `Failed` — Partial is a batch-level rollup concept only, never a job-level one.

**Zone2 proceeds if the dependent Zone1 batch is either `Completed` or `Partial`** — confirmed consistently
across every transcript that addressed it. This dependency is enforced at the **scheduler (StoneBranch)
level**, via a hard dependency between the Zone1 and Zone2 scheduler jobs — *not* inside IDMC task-flow logic
or a metadata table.

But a batch-level Partial does **not** mean Zone2 silently proceeds with stale data. The real gate is
**per-source-table**, via `etl_data_ingestion_source_window` (§4.2): each Zone2 job independently checks its
own specific Zone1 source job(s). If a given source's job actually failed, **that specific Zone2 target job**
fails outright (entry to `job_error_stats`, failure notification) — while other Zone2 jobs whose sources
succeeded continue normally. So "Zone1 Partial" in itself is not informative at the Zone2-job level; what
matters is only whether *that job's own* dependency succeeded.

**Sourcing window is capped at whatever Zone1 actually finished by cutoff** — confirmed: for a successful
source job, `sourcing_end_time` = that specific Zone1 job's own `job_end_time` (not a single uniform batch
cutoff — each source table can have a different effective end time).

---

## 7. Critical vs. Informational DQ severity

| | Critical | Informational |
|---|---|---|
| Record loaded to target? | **No** — excluded, routed only to `job_rule_error_detail` | **Yes** — loaded to target *and* logged to `job_rule_error_detail` |
| Effect on job's final status | **Fails the whole job** (`critical_error_check_flag = N`, one of the three Failed triggers, §8) | Job stays **Completed**, but a **warning notification** is sent |
| Notified? | Failure notification | Warning notification (async, non-blocking) |

**Mechanics**: a per-record expression flags `critical_error_check_flag = 'Y'` if there are **no** critical
failures for that job's run (i.e. Y = clean), `'N'` if any exist, `'X'` if no DQ checks are assigned to the job
at all (not-applicable, distinct from Y/N). The same three-state pattern applies to the informational flag.
A null/failing value in a column whose *only* assigned rule is Informational never sets the critical flag —
only columns with a **Critical**-severity rule assigned feed that check. Separately, `error_description IS NOT
NULL` (built from either a critical or informational rule's text) drives whether an error-detail row gets
written at all — so a record can be simultaneously **valid** (loaded) and have a logged error-detail row, if
the only rule it failed was Informational.

**One important correction to an earlier assumption**: Critical does *not* mean "only that record is affected,
rest of the job proceeds unaffected." A single Critical DQ failure anywhere in the run **also flips the whole
job's status to Failed** — the record-level exclusion and the job-level failure both happen together.

---

## 8. What decides a job's final status (Completed / Failed / Completed-with-warning)

Computed in **job post load**, from four flags:

1. `record_count_balancing_flag` (§4.2 formula)
2. `critical_error_check_flag`
3. `informational_error_flag`
4. The overall balance-reconciliation `balance_flag` (whether every configured metric is within threshold)

**Three explicit outcomes**:

| Outcome | Condition | Notification |
|---|---|---|
| **Failed** | `record_count_balancing_flag = N` **OR** any Critical DQ check fails **OR** any balancing metric is out **of threshold** | Failure notification, `job_error_stats` entry |
| **Completed — with warning** | Any Informational DQ check fails **OR** any balancing metric is out of balance but **within** threshold | Warning notification, job status still `Completed` |
| **Completed — clean** | `record_count_balancing_flag = Y`, no critical/informational issues, all balancing metrics fully balanced | Success notification |

If both a Failed condition and a Warning condition are true simultaneously, a **consolidated** notification is
sent, and the Failed outcome takes precedence for the stored status.

**Batch-level status** (job post load's rollup, in batch post load): `Completed` only if **every** job under
the batch completed successfully; if **any** job failed, the whole batch is `Failed`. Each job sends its own
notification, *and* the batch sends one more on top — so an N-job batch generates **N+1 notifications total**
(called out in one KT as a real volume concern for a client expecting quiet, all-green daily runs).

**Open thread, not yet resolved**: two independent transcripts each separately surfaced language suggesting a
distinct **"Warning"** *status value* (not just a notification category) might exist alongside Completed/Failed
in the notification-routing logic. It's unclear whether this is an actual third stored status or just a
message-type label layered on top of "Completed." Needs a direct SME confirmation — don't treat "Completed vs.
Failed" as a strict binary in code without checking this.

---

## 9. `batch_rerun_flag` — full code-value legend

| Value | Meaning | Manual entry required? |
|---|---|---|
| `N` | Regular/New run, **or** an automatic Restart of a regular run | No — automatic |
| `Y` | Zone2 Rerun (repeatable, date-range-driven, business-initiated) | Yes |
| `Z` | Zone1 Rerun (source-driven correction pass-through) | Yes |
| `H` | Historical load (one-time) | Yes |
| `C` | Catchup load (one-time, gap-filler between historical and incremental) | Yes |
| `I` | First-Time-Incremental (one-time, first regular incremental run after catchup) | Yes |

For every value except `N`, the `batch_run_stats` (and, since the recent split, `batch_sourcing_stats`) row is
inserted **manually by an operator**, ahead of batch invocation, with the execution type communicated via the
static parameter file — the automated batch-preload logic never touches these rows itself.

---

## 10. The "last-run gate" — how a new batch run actually gets started

This is layered, not one single compound condition. Three distinct mechanisms, confirmed consistently:

**Layer 1 — is the batch even eligible at all?**
`batch_metadata.is_active_flag = 'Y'` is required just to resolve a `batch_id` in the first place. If `N`, no
`batch_run_stats` entry is ever made and no job runs — full stop. (This layer was confirmed clearly in the
foundational KT1–4 series; it was not separately re-confirmed in the more recent Sept-2026 walkthroughs, though
nothing contradicts it either — treat as still-correct but worth a re-confirmation if it matters for a specific
decision.)

**Layer 2 — the scheduler-level "batch prerequisite" self-check (regular/New runs only).**
A separate task flow, run by the scheduler (StoneBranch) *before* the real batch task flow, checks only the
**batch's own most recent run**:
- Latest `batch_run_stats.status = Completed` (or no prior run) → the prerequisite succeeds, and the real batch
  task flow is triggered automatically.
- Latest status = `Started` or `Failed` → the prerequisite **fails on purpose**, sends a notification ("please
  validate and rerun once the batch is completed"), and **the real batch task flow never gets triggered at
  all** for that scheduled run. A human must intervene: either fix/validate and manually re-trigger the
  prerequisite, or bypass it and trigger the batch task flow directly (which then runs in Restart mode).
- This gate is **only evaluated for the regular/New path** — it is explicitly skipped for Restart, Rerun,
  Zone1-Rerun, History, Catchup, and First-Time-Incremental, all of which are manually triggered directly.
- A related, in-progress POC (as of one KT) is checking whether StoneBranch can natively auto-chain the next
  batch off the upstream task flow's own completion status, rather than needing this separate prerequisite
  flow — **not yet confirmed either way**.

**Layer 3 — inside batch preload itself, once triggered: the New-vs-Restart determination.**
Fetch the batch's latest `batch_run_stats` row and check `batch_rerun_flag` first:
- **`batch_rerun_flag = 'N'`**, latest `status = Completed` (or no prior row) → `execution_type = New`; insert a
  fresh row, new `execution_run_id`, `status = Started`.
- **`batch_rerun_flag = 'N'`**, latest `status ∈ (Started, Failed)` → `execution_type = Restart`; reuse the
  **same** `execution_run_id`. If the prior status was `Started` (an abrupt, uncaught failure — e.g. a network
  drop), that row is first updated to `Failed`, then a new row with the same `execution_run_id` is inserted
  with `status = Started`, and a corresponding `job_error_stats` entry is logged for the abrupt failure.
- **`batch_rerun_flag != 'N'`** → no automatic entry at all; the row is expected to already exist (manually
  inserted per §9).

**Net**: there is **no** single compound `isactive='Y' AND batch_rerun_flag='N' AND status='Completed'` gate.
Layer 1 (`is_active`) gates eligibility; Layer 2 gates the *automatic scheduler trigger* specifically; Layer 3
is the internal New-vs-Restart branch that fires once the flow actually runs — which is the part closest to
the original guess, just relocated to a different point in the sequence than assumed.

---

## 11. Batch/job lifecycle — full mechanics, phase by phase

### Phase 0 — Batch preload prerequisite (scheduler level)
See §10, Layer 2. Runs only for the regular/New path.

### Phase 1 — Batch preload
1. Resolve `batch_id` (+ dependency batch id) from `batch_metadata` via `source_name + domain_name +
   application_layer_name + target_zone` (+ `is_active_flag='Y'`).
2. Fetch the target (Zone2) batch's own latest `batch_run_stats` row.
3. Fetch the dependency (Zone1) batch's latest run with `status IN (Completed, Partial)` (never just "latest,"
   since Zone1 can be Partial) — giving `source_execution_run_id`, `source_batch_end_time`.
4. Determine `execution_type` per §10 Layer 3 / §9.
5. **New**: insert new `batch_run_stats` row — new `execution_run_id`, `status='Started'`,
   `sourcing_start_time` = previous run's `sourcing_end_time`, `sourcing_end_time` = latest Zone1
   Completed-or-Partial batch end time, `batch_rerun_flag='N'`.
6. **Restart**: insert with the **same** `execution_run_id` and **same** sourcing window as the interrupted
   run (not recalculated). If the interrupted row's status was `Started`, update it to `Failed` first.
7. For Rerun/Zone1-Rerun/History/Catchup/FTI, **this whole insert step is skipped** — the row already exists,
   inserted manually ahead of time.

### Phase 2 — Job preload (per job, 5 steps)
1. **`job_run_stats` preload**: fetch job metadata via `job_name + batch_id`; fetch the job's own latest run.
   - New / Rerun / Zone1-Rerun / History / Catchup / FTI → new `job_run_id` + `execution_run_id`,
     `status='Started'`.
   - Restart, branching on the **job's own** previous status (not the batch's): `Completed` → **skip this
     job entirely**; `null` → new entry; `Failed` → reuse `job_run_id`, update status to `Started`; `Started`
     (interrupted) → reuse `job_run_id` **and** write a `job_error_stats` row for the interruption.
2. **`etl_data_ingestion_source_window` preload**: for New/Restart/Zone1-Rerun, look up each source table via
   `etl_data_ingestion_metadata`, apply the source-window formula in §4.2; if any source failed, fail this
   job's `job_run_stats` + write `job_error_stats`. For **Rerun**, instead pull a manually-supplied
   `execution_run_id` from the parameter file, find that run's starting `job_run_id` and the job's current
   latest-completed ("ending") `job_run_id`, and derive a sourcing window spanning that **entire range** (every
   run since the rerun point gets reprocessed, not just the one that originally failed).
   - Restart-specific partial-load detection: see §4.2.
3. **`job_rule_execution_log` preload**: for each active `job_rule_assignment` row for this job, insert a new
   execution-log row (`status='Started'`). On Restart, existing rows for the same `job_run_id` are deleted and
   reinserted first.
4. **Restart-only target cleanup**: automated today only for **Type 2** tables; other load types deferred.
5. **Stage record-count check**: if the stage (transient) table already has rows for this `job_run_id`
   (meaning it fully loaded in a prior attempt — stage load is all-or-nothing PDO), **skip the stage reload**
   on restart and go straight to the target load.

A shared preload/postload-failure component (reused for both phases) marks `job_run_stats` → `Failed` and any
`Started` `job_rule_execution_log` rows → `Failed`, then sends a notification, whenever anything in preload
other than the `job_run_stats`-preload step itself fails.

### Phase 3 — Job load (2 steps, one mapping, full push-down optimization in Snowflake)
1. **Source → Stage**: one source-qualifier query does almost everything in a single pass — FK/parent lookups
   (both forward- and back-dated join paths), hash-based change detection (comparing current vs. previous hash
   of business-key-only content, deliberately ignoring the row-effective-date) to compute a `change_flag`,
   row-expiration-date computation for Type-2 tables, the Critical/Informational DQ check (§7), and the RI/RA
   JSON construction (§4.2). Records split: valid+changed → stage; Critical-failed → error detail only, not
   staged; RI-unresolved → still loaded speculatively **and** routed to the temp RI table (§4.2); unchanged →
   not staged at all. Source-side balance-recon aggregates are computed here too, staged into the
   `balance_reconciliation` temp table; `job_run_stats` temp gets `source_record_count`/
   `target_unchanged_record_count`. The stage table itself is **truncate-and-reload** every run, never upsert.
2. **Stage → Target**: a SQL **MERGE** (not a standard update-strategy transformation) using every business-key
   column as the join condition. Type-2 handling: if the source is itself Type 2 and a record changed, two
   stage rows arrive (the new version, and the prior version now needing its expiration fields closed) — the
   merge updates the old row and inserts the new one. Full PDO is specifically **disabled for this one step**
   (the "create time view" pushdown check doesn't work with a MERGE statement), though PDO is used everywhere
   else in the load.

**Unresolved oddity flagged in-transcript, not yet explained**: on a Type-2 update+insert pair, the **same**
generated surrogate sequence value gets reused for both the old (expiring) and new row sharing a business key
— the presenter wasn't sure this was intentional and planned to check the code.

**Audit-column naming quirk**: on the Snowflake stage/temp/RA tables, columns literally named `audit_batch_id`
/ `audit_job_id` are actually populated with **`execution_run_id`** / **`job_run_id`** respectively (not the
metadata `batch_id`/`job_id`) — a deliberate choice specifically to support restart handling, since the
run-scoped IDs are what's needed to identify/clean up a specific run's rows.

### Phase 4 — Job post load
1. **RI-to-main load**: temp RI table → `MAIN_RI_TABLE` (mechanics in §4.2).
2. **Job rule error detail load**: fetch active `job_rule_assignment` IDs (Aurora) for this job, check the temp
   job-rule-error-detail table, load into the permanent (Aurora + Snowflake) `job_rule_error_detail`,
   transposed to record+column level.
3. **Job rule execution log update**: per §4.2 formula — Pass if zero error rows for that rule assignment,
   else Fail + count + message.
4. **Balance reconciliation** (only if the job has active metrics): fetch active metrics from
   `balance_reconciliation_metadata`, compute target aggregates using the stored `target_expression`/
   `target_balance_recon_filter`, compare, and write `balance_reconciliation_stats` per §4.2's formula.
5. **`job_run_stats` finalization**: pull source/target counts, calculate the four status flags (§8), roll
   into the job's final status, send the appropriate notification.
6. **Job postload-failure component** (used whenever any prior step fails): simpler — just marks
   `job_rule_execution_log`/`job_run_stats` `Started` rows → `Failed`, sends the failure notification.
   Preload-failure and postload-failure are kept as **separate task-flow components** even though the
   underlying mapping logic is largely shared, because their notification handling differs.

### Phase 5 — Batch post load
Checks the final status of every job under the batch. All succeeded → `batch_run_stats.status = Completed` +
success notification. One or more failed → `Failed` + failure notification. Implementation detail: two
in-flow variables (`temp_count`/`temp_error_count`) increment on each job's failure inside the sub-task-flow
loop; a decision task checks `error_count = 0` to set `temp_batch_status`; a mapping task then updates
`batch_run_stats` (keyed on `batch_run_id`) with end time/status/audit columns; a final decision task sends the
notification and, on failure, **explicitly fails the batch task flow itself** after sending it.

**Client-driven notification requirement**: notifications must include human-readable **batch name and job
names**, not just IDs — added as rework after initial client feedback (the default design only passed
job_id/batch_id/job_run_id/execution_run_id).

---

## 12. Execution-type scenarios — trigger, mechanics, and build status

| Scenario | `batch_rerun_flag` | Built in code? |
|---|---|---|
| New / Regular | `N` (prior status Completed/null) | **Yes** |
| Restart | `N` (prior status Started/Failed) | **Yes** |
| Zone2 Rerun | `Y` | **Yes** |
| Zone1 Rerun | `Z` | Mostly — see below (handled largely outside ABC) |
| Historical load | `H` | **No — design only**, not yet built |
| Catchup load | `C` | **No — design only**, not yet built |
| First-Time-Incremental | `I` | **No — design only**, not yet built |

### Restart (fully implemented)
- Trigger: batch/job's latest run is `Failed` or `Started`, with `batch_rerun_flag='N'`.
- Cleanup is **automatic**, handled in code.
- Batch level: reuses the same `execution_run_id`; the scheduler-level prerequisite (§10 Layer 2) is
  **skipped** — the batch task flow must be triggered manually (or, per the in-progress StoneBranch POC,
  potentially auto-chained in future).
- Job level: only jobs whose previous run was **not** Completed get reprocessed; already-Completed jobs are
  skipped outright. A job whose prior run was `Started` (interrupted) reuses its `job_run_id`, logs the
  abrupt-failure entry to `job_error_stats`, and resumes.
- Stage table: skipped-and-resume if the stage load already fully completed (row count > 0 for that
  `job_run_id` — remember, PDO loads are all-or-nothing, so a non-zero count is unambiguous).
- Target cleanup: automated only for **Type 2** tables today; other load types explicitly deferred.
- `etl_data_ingestion_source_window`: reuse-if-full, delete+reload-if-partial, load-fresh-if-none.
- `job_rule_execution_log`: existing rows for the same `job_run_id` deleted and reinserted fresh.

### Zone2 Rerun (fully implemented) — `batch_rerun_flag='Y'`
- Definition: reprocessing a **specific date range** — e.g. after a logic/transformation-rule fix, or a
  business ask to reload a past window. **Can recur** over time (unlike the one-time scenarios below).
- Explicitly **not dependent on a prior failure** — a rerun can be initiated even when the prior run succeeded,
  purely for data-correction purposes.
- A **manual** `batch_run_stats` entry: new `execution_run_id`, `batch_rerun_flag='Y'`, `status='Started'`,
  sourcing window set to the custom range being reprocessed.
- The scheduler-level prerequisite is **not** evaluated.
- **Unlike Restart, previously-successful jobs/tables ARE re-executed** — this is the key mechanical
  difference from Restart. (Confirmed both ways across transcripts — one framing says the *whole* window from
  the specified start through "now" gets reprocessed in one pass, not just the originally-affected days.)
- **Manual cleanup required before rerunning** — existing target rows for the affected range must be
  hard-deleted (based on `load_type` + audit-timestamp columns) by an operator; this cleanup step is explicitly
  **out of ABC's scope** (owned separately, described in one KT as "not related to ABC").
- At job level: the operator supplies the historical `execution_run_id` to rerun from in the static parameter
  file; job preload finds that run's starting `job_run_id` and the job's current latest-completed
  ("ending") `job_run_id`, and derives `sourcing_start_time`/`sourcing_end_time` spanning the whole range.
- Should be performed **only after validation** of the underlying issue.

### Zone1 Rerun (mostly outside ABC's scope) — `batch_rerun_flag='Z'`
- Trigger: Zone1's own CDC/DMS-style ingestion can't checkpoint cleanly through a multi-day failure, so it
  resends the **entire multi-day extract** in one pass once healthy again (e.g. Zone2 gets 110 records for
  what should have been a 10-record day).
- Zone2 treats this closer to a **New/full-reload** than an incremental — described as "more functional than
  ABC," i.e. most of the actual handling lives in the underlying job-load mapping's own upsert logic, not in
  ABC's control layer.
- **Key difference from Zone2 Rerun: no target cleanup is performed.** Zone1's own source-to-stage upsert logic
  naturally overwrites corrected values for a changing key without needing Zone2 to delete anything first.
- A dedicated **`zone1_uuid`** column on target tables gets updated to tag records associated with a Zone1
  rerun.
- A manual `batch_run_stats` entry: new `execution_run_id`, `batch_rerun_flag='Z'`, `status='Started'`; batch
  preload makes no further changes; execution starts directly at job preload.

### Historical load (design only, not yet built) — `batch_rerun_flag='H'`
- One-time full backfill: **Teradata → Zone1 → Zone2**. Today Teradata is the actual source-of-record target
  DB; in the future state it becomes purely the historical source for this one-time load.
- Runs via a **separate migration tool** ("Demigrator"/similar — name garbled across transcripts), through
  Zone1 **Iceberg** intermediate tables — explicitly **outside ABC's own scope**; "ABC is responsible for the
  load happening from Zone1 to Zone2 only."
- Manual `batch_run_stats` entry: new `execution_run_id`, `batch_rerun_flag='H'`, `status='Started'`,
  `sourcing_start_time = '1900-01-01'` (literal floor sentinel), `sourcing_end_time` = a defined cutover date
  (worked example: **Aug 31**) — in production, computed as `MAX(GRS refined timestamp)` across all the
  batch's Zone1 source tables (an audit column present on every Zone1 target table marking when that row was
  last refined).
- `etl_data_ingestion_source_window` **not used** — sourcing dates come straight from the manual
  `batch_run_stats`/`batch_sourcing_stats` row.
- Can take multiple days to actually run (worked example: historical range ends Aug 31, but the load itself
  doesn't finish executing until **Sept 10**).
- DQ/critical/count-validation/balance-reconciliation checks are stated to be the **same** as regular loads.

### Catchup load (design only, not yet built) — `batch_rerun_flag='C'`
- Purpose: bridges the gap between when the historical load's *data window* ends and when the historical load
  *actually finishes running* (worked example: historical data cuts off Aug 31 but the load itself doesn't
  complete until Sept 10 — catchup then covers Sept 1 → Sept 10, a much smaller volume that finishes quickly).
- Manual entry: `sourcing_start_time` = the historical run's `sourcing_end_time`; `sourcing_end_time` = current
  timestamp (this exact detail — current timestamp vs. max GRS timestamp again — was flagged in-transcript as
  still needing confirmation with the design owner).
- Same pattern as Historical: prerequisite not evaluated, no batch-preload changes, `etl_data_ingestion_source_
  window` not used.

### First-Time-Incremental (design only, not yet built) — `batch_rerun_flag='I'`
- The first normal incremental run immediately following catchup completion — from here on Zone1 sources
  directly from the live source system, not Teradata.
- Manual entry: `sourcing_start_time` = **2–3 days prior** to the catchup load's `sourcing_end_time`
  (deliberately overlapping as a safety buffer against data loss — records already present simply get marked
  "unchanged"); `sourcing_end_time` = the Zone1 batch's own end time.
- Worked example: catchup ends Sept 10 → first-time-incremental window = **Sept 7/8 → current timestamp**.
  From the *next* regular run onward, everything is fully automatic New/Regular.
- **Unlike Historical/Catchup**, `etl_data_ingestion_source_window` **is** used here, but requires new custom
  logic to populate it from the manually-entered `sourcing_start_time` (only New/Restart/Zone1-Rerun paths are
  coded for this table by default).
- Per the recent `batch_sourcing_stats` split (§4.2), the manual sourcing-start entry must now go into **both**
  `batch_run_stats` and `batch_sourcing_stats`.
- Execution-type parameter value format: `"Zone2 First Time Incremental"`.
- **Explicitly still pending as of the most recent KTs** — dummy entries were being used in
  `batch_run_stats`/`job_run_stats`/`etl_data_ingestion_source_window` purely for interim testing/build
  purposes, with the real logic deliberately parked ("told to mark it aside").

---

## 13. Success scenario — worked example (fully implemented, real sample values)

Batch 1 (`ADW_Producer`), 3 jobs: 101 `prty_mstr_t`, 102 `prty_dtl_t`, 103 `cntc_t`.

**Sequence (11 steps, 5 phases):**
1. **Batch preload** — read `batch_metadata` (`isactive='Y'`) → check last `batch_run_stats` row for this
   `batchid` (see §10 for the full gate mechanics) → insert new `batch_run_stats` row (new `executionrunid`,
   `status='Started'`)
2. **Job preload** — read `job_metadata` for the batch → insert `job_run_stats` per job (3 rows, same
   `executionrunid`, each own `jobrunid`)
3. read `job_rule_assignment` per job → insert `job_rule_execution_log` per assignment, `status='Started'`
4. read `balance_reconciliation_metadata` per job → seed `balance_reconciliation_stats`
5. **Job load** — data moves; inline DQ runs; failing records staged to a temp error table
6. source count + target-unchanged count written to `job_run_stats` and `balance_reconciliation_stats`
7. **Job postload** — temp error rows persist into `job_rule_error_detail`
8. `job_rule_execution_log` rolled up: 0 errors → `Passed`; some errors → error message + count
9. `balance_reconciliation_stats` gets target counts, `out_of_balance`, `balancing_flag`, `within_threshold_flag`
10. `job_run_stats` closes with final counts and status
11. **Batch postload** — once every job under the batch is `Completed`, `batch_run_stats` flips to `Completed`

**Real values from the workbook:**
- `executionrunid = 8c17e0c2…`, jobs' `jobrunid`s = `88f8d17f…` (101), `7a554253…` (102), `da057574…` (103)
- Job 102's Null-check rule found **3 records** with a null `prty_id` (severity **Critical**). Job 102's final
  error count later shows 0, consistent with those records not landing in the target — confirmed by §7/§8:
  Critical exclusion + the record-count-balancing formula both account for this cleanly.
- `balance_reconciliation_stats`: metric 1 (count, job 101) 100/100 balanced; metric 2 (count, job 102) 100/100
  balanced; metric 3 (amount, job 102) source=5000, target=4500, `balancing_flag='N'`, but threshold=1000 and
  500<1000 → `within_threshold_flag='Y'`
- All 3 jobs closed `Completed`; batch closed `Completed`

**What we can directly observe:** `balancing_flag='N'` alone did not fail job 102 — it's out of balance by
$500, but the configured threshold is $1000, so `within_threshold_flag='Y'`. Combined with a final error count
of 0 for that job, it closes `Completed` despite the earlier flagged records and the balance mismatch — this is
now fully explained by §8's three-outcome logic: no Failed trigger was tripped, and no Informational/near-
threshold condition existed either, so it's a clean `Completed`, not even a `Completed-with-warning`.

---

## 14. Open items — still genuinely unresolved after all 17 transcripts

Everything else in this document is now cross-corroborated across multiple independent KT sessions. What's
left is narrow and specific:

1. **Terminology**: is the Snowflake-side staging mechanism literally a "temp table" or something else
   (possibly "dynamic table")? Audio was ambiguous in two sources on this specific word. Doesn't change the
   mechanics (§2), just the precise term to use in the deck.
2. **`MAIN_RI_TABLE` naming**: no transcript ever uses this exact name — always "RA table"/"RI report."
   Functionally it's the same object described consistently everywhere, but confirm the real name before using
   it externally.
3. **Possible third "Warning" status value** (§8): two independent sources hint at this; unclear if it's a
   stored status or just a notification-message category. Needs direct SME confirmation.
4. **Unnamed "batch prerequisite"/dependency-gating table** (§4.1): real name and full column list unconfirmed.
5. **`batch_metadata.is_active_flag` as part of the last-run gate** (§10, Layer 1): solidly confirmed in the
   earliest KT series (KT1–4), but not independently re-confirmed in the later, more detailed Sept-2026
   walkthroughs — worth a quick re-check that it's still accurate, not because anything contradicts it, but
   because it simply wasn't mentioned again.
6. **Job post load's exact write-back SQL** for Aurora `job_run_stats`/`balance_reconciliation_stats` — the
   *what* and *when* are well documented (§11 Phase 4), but the literal SQL/field-by-field mapping was never
   walked through step-by-step in any transcript.
7. **Sign-off status**: the ABC framework LLD was walked through with client stakeholders but was **not yet
   formally signed off** as of the most recent KTs, partly blocked on First-Time-Incremental design still being
   unresolved. Any of the "design only, not yet built" items in §12 should be treated as subject to change.

**Recommended next step**: confirm items 1–6 directly with the ABC framework owners (per the KT transcripts:
individuals referred to as Aishwarya/Nidhika/Swayam/Saurabh, plus the LLD document itself) rather than inferring
further from transcript audio alone.

## 15. Deck build progress

`abc_framework_deck.html` is being rebuilt section by section against this md, discussed with the user before
each build. Current state: **12 slides**.

| # | Section | Slide(s) | Status |
|---|---|---|---|
| 1 | What ABC is & why it exists | 2 &mdash; Overview | Built |
| 2 | Architecture (Aurora vs. Snowflake) | 3 &mdash; Execution by phase, 4 &mdash; How tables connect | Built (2 slides; chevron+matrix layout for phases, two-lane diagram + full-sentence purpose cards for table connections) |
| 3+4 | Table catalog (config + runtime) | 5 &mdash; Table catalog | Built &mdash; merged into **one** slide per user's call: a 4-column table (Config/Static &middot; Runtime&mdash;Aurora only &middot; Runtime&mdash;Aurora+Snowflake &middot; Runtime&mdash;Snowflake only), table names only, bulleted, no per-table detail on-slide |
| &mdash; | How it all links (FKs + threading) | was slide 6 (ER diagram) | **Removed, not rebuilt** &mdash; user has the ER diagram in Lucidchart already; it (plus the table-catalog detail) will be attached as separate artifacts alongside a Word doc, not redrawn in the HTML |
| 6 | Zone1&harr;Zone2 dependency & Partial status | 6 &mdash; three scenarios (pictorial flow, chip rows), 7 &mdash; worked example (`etl_data_ingestion_metadata` + combined `job_run_stats`/`batch_run_stats` tables, illustrative business-table names) | Built, but **flagged for revision** &mdash; user says it needs multiple changes; specifics not yet given, discussion paused here. Don't treat these 2 slides as final. |
| 7 | DQ severity + job status decision logic | &mdash; | Not started |
| 8 | `batch_rerun_flag` & the last-run gate | &mdash; | Not started |
| 9 | Full lifecycle, step by step | &mdash; | Not started |
| 10 | Execution-type scenarios (New/Restart/Rerun/Zone1-Rerun/History/Catchup/FTI) | &mdash; | Not started |
| 11 | Success scenario worked example | 8&ndash;11 (pre-existing, kept as-is) | Built (predates this restructure; not yet re-verified against the corrected table catalog/naming) |
| 12 | Open items / SME follow-ups | 12 &mdash; Open questions | **Stale** &mdash; still shows the original Q1&ndash;Q7 in "unresolved, hidden-worksheet" framing; most of these are now answered (see &sect;14 above) and this slide needs a rewrite before it's shown to anyone, not just a renumber |

**Standing decisions made during the deck build (apply going forward):**
- Full column-by-column table detail goes in a **combined Word doc** (config + runtime tables together, one
  document) &mdash; parked, not yet built. Slides stay name-only/teaser-level for the catalog.
  the ER diagram itself lives in **Lucidchart** (user's own), attached as a separate artifact, not redrawn in HTML.
- RI table naming standardized everywhere (deck and this md): the durable table is **`MAIN_RI_TABLE`**, its
  disposable per-run companion is **`RI_TEMP_TABLE`** &mdash; do not reintroduce "RI temp table"/"temp RI table"
  variants.
- When a slide references another slide by number (e.g. "an open question, slide 10"), that number drifts every
  time a slide is added/removed/reordered &mdash; always grep the whole deck file for stale cross-references
  after any renumber, not just update the moved slide's own footer/tab.
