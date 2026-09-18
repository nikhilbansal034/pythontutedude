# W3 glossary — zones, buckets, and source systems

Working definitions for the terms used in the SCD multi-source effective-date split work (W3). See
`README.md` for the workstream index.

**Confidence warning.** None of these terms are defined in `../w2-abc-framework/reference.md` — the word
"bucket" does not appear in it at all. Everything here is assembled from the 2026-09-18 meeting transcript,
`sources/scenario_screenshot.png`, and cross-references in the ABC doc. Each entry is marked:

- **[Confirmed]** — stated directly in a source file, quoted below
- **[Inferred]** — a reading consistent with the sources but not stated outright
- **[Unknown]** — flagged as needing an answer from an SME or from the data

---

## The layer stack

```
┌─ S4 / live source system ──────────┐   ┌─ Teradata (legacy warehouse) ─┐
│  "the SOR"                         │   │  history from before cutover  │
│  go-forward source of truth        │   │  one-time backfill only       │
└──────────────┬─────────────────────┘   └───────────────┬───────────────┘
               │                                         │
               ▼                                         ▼
┌──────────────────────── ZONE 1 (S3 / Iceberg) ─────────────────────────┐
│                                                                        │
│   current bucket ──────── mirrors what the SOR looks like *now*        │
│                                                                        │
│   history bucket ──┬── sor ......... S4's history, appended over time  │
│                    └── legacy_TD ... Teradata's history (the backfill) │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │  ← IDMC pipelines, push-down optimization
                               ▼
┌──────────────── ZONE 2 (Snowflake) — the target tables ────────────────┐
└────────────────────────────────────────────────────────────────────────┘
```

---

## Terms

### SOR — System of Record **[Confirmed as a term, [Inferred] as to which system]**

The authoritative source for a piece of data. In this program it means the live operating source system,
which the transcript calls **S4**.

What S4 actually is (SAP S/4HANA, or a specific policy/claims admin platform) is **[Unknown]** — it is named
in the transcript but never expanded, and does not appear in the ABC doc. It does not change any of the
logic, but should not be asserted in a deck without confirmation.

Note a labelling collision: the transcript uses "SOR" generically for the live source system, while the
screenshot uses `sor` as the name of the **S4-specific sub-area of the history bucket**. Same underlying
system, two different scopes — worth stating explicitly whenever the word is used.

### legacy_TD — legacy Teradata **[Confirmed]**

The outgoing warehouse. The transcript's *"the legacy 3D bucket"* is a mis-transcription: the screenshot has
a cell reading literally `legacy_TD`, so **TD = Teradata**.

Its role is temporary and shrinking. From the ABC doc:

> *"One-time full backfill: Teradata → Zone1 → Zone2. Today Teradata is the actual source-of-record target
> DB; in the future state it becomes purely the historical source for this one-time load."*

> *"The first normal incremental run immediately following catchup completion — from here on Zone1 sources
> directly from the live source system, not Teradata."*

So Teradata supplies the one-time historical backfill (`batch_rerun_flag='H'`), after which S4 feeds
everything. That is why the history bucket splits into `sor` and `legacy_TD`.

### Zone 1 **[Confirmed]**

The landing/ingestion zone, on S3 with Iceberg tables. Its ETL is AWS-native (Lambda/Glue), separate from the
IDMC pipelines that move Zone1 → Zone2. The ABC doc states the Zone1→Zone2 hop is the only part ABC owns:
*"ABC is responsible for the load happening from Zone1 to Zone2 only."*

Zone1 creates **four** separate `job_metadata` entries per source table for different pipeline stages; Zone2's
dependency check keys off the one named *"raw to curated/current data movement"*. So "current" is a named
Zone1 pipeline stage. What the other three stages are is **[Unknown]** — not documented in any file here, and
knowing them would probably answer the open question below.

### Zone 2 **[Confirmed]**

The Snowflake target layer holding the business tables this work loads into. OLAP; no enforced PK/UNIQUE
constraints (informational only).

### current bucket **[Confirmed definition, [Unknown] mechanics]**

Transcript, verbatim:

> *"Current bucket will reflect what is there in SOR."*

### history bucket **[Confirmed]**

Transcript, verbatim:

> *"...whereas in history bucket any change that would have happened would come and get added as an appended
> record. It won't overwrite it. They are not merging the data, rather they will append it."*

And its structure:

> *"In Zone 1 you have current bucket and history bucket. Within history you again have two subsections: one
> is S4-specific history, and the legacy which is the Teradata history."*

The screenshot's bottom-left block confirms the same shape: `Zone1` → `current` / `history` → `sor`,
`legacy_TD`.

What "bucket" physically is — literal S3 buckets, or loose jargon for a layer — is **[Unknown]**. Zone1 is
S3/Iceberg so either reading is plausible. It does not affect the logic; do not assert it.

---

## Why the current/history distinction matters here

There are two different kinds of time in play:

| | Meaning | Example |
|---|---|---|
| **Valid time** | when a fact was true in the business | "this key's status was A from 10-Sep to 21-Sep" |
| **Transaction time** | when the warehouse found out | "we learned it on 18-Sep; the source corrected it on 20-Sep" |

A **current bucket** carries valid time only — the source's *current* assertion about history.
A **history bucket** adds transaction time, because it appends instead of overwriting, so you can still see
what the source *used to say* before correcting itself.

That makes the history bucket **bi-temporal** and the current bucket uni-temporal.

---

## Open question — Q1, blocking the scenario matrix

The transcript confirms the source systems keep Type 2 themselves:

> *"Because the source is maintaining them as a SCD type 2, we are going to receive the changes."*

If so, then "current bucket reflects what is in the SOR" may mean the current bucket holds **all of the
source's valid-time versions**, not one row per business key — i.e. "current" means *current state of the
source*, not *current version per key*.

- **Q1a** — Does the current bucket preserve the source's own effective-dated versions, giving multiple rows
  per business key?
- **Q1b** — Or does Zone1 collapse the current bucket to exactly one row per business key?

**Why it matters.** The team's working rule is:

> *"You may still have scenarios where multiple history bucket tables are used, or maybe one history bucket
> table is used and rest from the current bucket tables. In that case, mostly your driving table is going to
> define what should be your effective and expiration dates."*

If **Q1b**, that rule is structural and safe. If **Q1a**, it is a **convention** that happens to hold for the
assets built so far, not a guarantee — a current-bucket source could still contribute to target effective
dates, and the problem is wider than the transcript implies.

### How to settle it

1. Ask an SME one question: *"For a source table that is SCD2 in the SOR, does the Zone1 current bucket hold
   one row per business key, or all of the source's effective-dated versions?"*
2. Or check the data directly — on any SCD2 source table's current-bucket table, compare `COUNT(*)` against
   `COUNT(DISTINCT <business_key>)`. Equal → Q1b. Greater → Q1a.

---

## Terms deliberately not defined here

ABC framework vocabulary (`batch`, `job`, `execution_run_id`, the five phases, PDO, the Aurora/Snowflake
split) is covered in `../w2-abc-framework/reference.md` — see W2 in `README.md`. This file covers only the
zone/bucket/source vocabulary that the ABC doc leaves undefined.
