# POC07 — Test design: proving CTAS + Swap on Snowflake, built on POC01 and POC02

**How to prove, on the Snowflake account, the parts of CTAS + Swap that the point of view (POV) says are
still unproven — reusing POC01's tagging and masking model and POC02's swap and test tooling, and not
re-testing anything they already proved.**

| # | Field | Value |
|---|-------|-------|
| 1 | Status | **Draft v2, for review. Nothing built or run.** No SQL or scripts written yet — they follow once this design is agreed |
| 2 | Date | 26 October 2026 |
| 3 | Built from | [`POC07_POV.md`](<../2_Deliverables/POC07_POV.md>) v10 — §1.2 requirements, §2.3 steps, §2.4 rules, §3 safety checks, §4.2 tag options, §7 tests, §8.2 Snowflake behaviours, §10 roles and pseudo-SQL · [`ALREADY_PROVEN_POC_FINDINGS.md`](<../../ALREADY_PROVEN_POC_FINDINGS.md>) · POC01's final build (`POC01_pii_masking_policies/2_Deliverables/POC/S3v2_complete_proof/`) · POC02's shared build (`POC02_zero_downtime_refresh/2_Deliverables/POC/_common/`) · Snowflake documentation (§11) |
| 4 | Reviewed by | [CoCo's critique of draft v1](<POC07_Test_Design_CTAS_Swap_critique.md>), 26 October 2026. Draft v1 is archived as [`3_Archive/POC07_Test_Design_CTAS_Swap_v1_20261026.md`](<../3_Archive/POC07_Test_Design_CTAS_Swap_v1_20261026.md>) |
| 5 | What changed in v2 | All of the critique's suggested changes, as the user asked on 26 October 2026: a **base-against-config check** in the security check, so the scope and new-column tests can fail (§3.3, tests 7–10) · an **untagged-window test** with two candidate fixes (test 11) · the grants test moved onto the **published tables** (test 18) · a **requirement matrix** (§5) · tag methods 2 and 3 **required**, method 3 on a POC07 test tag (tests 12–14) · a step that makes **staging match the table list** (test 5) · a **restart after a refused publish** rebuilds the refused tables (test 23) · a rule against running two POC01 scripts, and a wider guard (§7) · the low-severity fixes (tests 16, 22, 24, 26; §3.4; the caller role in §3.5; sequences in §9 row 9) |
| 6 | Scope | **CTAS + Swap only.** All three tag methods are tested: method 1 (re-apply from the tag config table — the POV's working recommendation), method 2 (`COPY TAGS`) and method 3 (propagation, on a test tag only). The Clone + Swap thread is **not** in this build (§9) |
| 7 | Shape | One unified build, like POC02 (`POC_CONVENTIONS.md` §2a): one SQL file split into parts, one set of runners, one evidence pack, in one `_common/` folder. Which folder holds it is to be agreed (§10 row 6) |
| 8 | Next step | Review this draft. Then write the SQL and runners, run part 0 (read only), and stop for a go-ahead before anything is created on the account |

**How to read the "Basis" column** — the same labels as the POV: **Proven** (run and passed on our
account) · **Docs — stated** · **Docs — partly stated** (part stated, the rest only shown in an example or
missing — the row says which) · **Proposal** (a design choice this document puts forward, for agreement) ·
**Reasoning** · **Code** (read in POC01's or POC02's scripts on disk, 26 October 2026) · **Critique** (raised
in CoCo's review of draft v1).

---

## 0. In brief

| # | Point | Basis |
|---|-------|-------|
| 1 | **Yes, it can be built and run on Snowflake.** Most of the tests in POV §7 are plain SQL against a small test domain; the rest need two sessions at once, which POC02's scripts already do | Code (POC02 `capture_evidence.py` opens a second connection and runs a query while a swap commits) |
| 2 | **It builds on POC01's tagging model rather than copying it.** It uses POC01's two tags, three masking rules and approval table as they are, the same way POC02 did: read them, add to them, never change or remove what is there | Code (POC02 `poc02_names.py`, build parts 0, B and H) |
| 3 | **It does not re-test anything already proven** — the schema swap's all-old-then-all-new behaviour, CTAS losing tags, a clone keeping them, the pre-switch check refusing a bad load, `APPLY` on the two named tags being enough. It starts from those results | Proven (register §3) |
| 4 | **What it proves:** the checks before a publish (completeness, readiness gate, staging matching the table list, security check), re-tagging under the least rights, whether the tag config is complete, masking through thin reader views, grants on the published tables over many publishes, restart, partial release, who owns and who writes inside the publishing procedure, and all three tag methods | POV §7 · Critique |
| 5 | **What it can't prove** (§9): real volumes and timing, the effort of converting real views, and the facts only the team can give (domain lists, load timing, report names, where batch status comes from) | POV §7, §8.1 |
| 6 | **Safety:** its own database, roles, users, scope values and approval rows, all prefixed `P7`; a fingerprint of POC01's approval rows and scope values before and after; no `ACCOUNTADMIN`; no account setting changed. **One account-level grant** — the right to apply tags, for the propagation test only — is flagged, approved separately and revoked at teardown (§7 row 6) | Proposal, following POC02's rules |

---

## 1. What this POC answers

The question, from the POV: **can a domain be published as one switch — rebuilt by CTAS from its views,
re-tagged, checked, then swapped — with tags, masking, grants and ownership correct, under the batch
service account, with no manual step?**

| # | Group | What the group answers | POV tests covered |
|---|-------|------------------------|-------------------|
| 1 | Gating | Nothing is published unless loads are complete, every required table is ready, staging holds exactly the domain's tables and the security check passes; a repeat or parallel publish is refused; changes to live after the build starts are caught | T10, T34, T17, T14, T19 |
| 2 | Tags — method 1 | Re-tagging from the config table works with only `APPLY` on the two named tags; the config itself is checked against the base tables, so a wrong scope or a missing column is caught; tables in staging are not readable in plaintext before they are tagged | T4, T3, T16 · new: lineage limits, untagged window |
| 3 | Tags — methods 2 and 3 | `COPY TAGS` from a view; automatic propagation on a test tag, including its side effects on existing loads | T1, T2, T5, T6 |
| 4 | Masking | Approved and unapproved readers see real and masked values through the thin views after a swap; width and type limits are caught | T7, T9 |
| 5 | Grants | Readers reach only the thin views; grants on the published tables stay as set over many publishes; a leftover grant on an original view exposes mid-batch data | T8, T15, T27 |
| 6 | Running under the service account | Inside the owner's-rights procedure: which user the masking rule sees, who owns the rebuilt tables, whether real values are stored with the all-access approval row and masks without it; the whole publish runs with no manual step, under a role that can only call the procedure | T12, T11 |
| 7 | Restart and partial release | A failed or refused rebuild publishes nothing and the restart rebuilds only what is missing or refused; an approved exception carries yesterday's table forward and lapses with its batch | T35, T36, T37 |
| 8 | Straight after the swap | A new statement in a second session, issued right after the swap, sees all tables new, never one of each — repeated many times | T20 |
| 9 | Optional | Reading views "as of" one moment; streams on a published table | T18, T28 |

---

## 2. What it reuses

### 2.1 From POC01 — the tagging and masking model

All names were read from POC01's `poc_names.py` and confirmed against POC02's `poc02_names.py`, which
reused the same objects.

| # | Object | Name on the account | How POC07 uses it | Basis |
|---|--------|---------------------|-------------------|-------|
| 1 | Attribute tag | `LM_S3_GOVERNANCE_DB.CENTRAL_TAGS.PII` | Set on the published tables' columns by the re-tag step | Code |
| 2 | Scope tag | `LM_S3_GOVERNANCE_DB.CENTRAL_TAGS.PII_SCOPE` | Set on the test database and both swapped schemas; on one table as an override | Code |
| 3 | Masking rules | `…PII_GOVERNANCE.PII_STRING_MASK`, `PII_NUMBER_MASK`, `PII_DATE_MASK` | Used unchanged; they are attached to the `PII` tag, so tagging a column brings its masking. Their comments give the width limits: text "must be VARCHAR(64) or wider"; the masked number "is up to 10 digits" | Code (POC01 build SQL, lines 312 and 326) · Proven S1-F2 |
| 4 | Approval table | `…PII_GOVERNANCE.PII_ENTITLEMENT` | POC07 adds its own rows only, with ids starting `PIA-P7-` | Code (POC02 part H did the same with `PIA-P2-`) |
| 5 | Tag and rule owner roles | `LM_PII_TAG_ADMIN`, `LM_PII_POLICY_ADMIN` | Used only for the additive steps: add POC07's scope values, grant `APPLY` on the two tags, insert POC07's approval rows | Code |
| 6 | Warehouse | `LM_PII_POC_WH` | Runs everything | Code |
| 7 | Findings | Register §3 and §4 | Not re-tested; the design depends on them (§2.3) | Proven |

### 2.2 From POC02 — the swap and the test tooling

| # | What | How POC07 uses it | Basis |
|---|------|-------------------|-------|
| 1 | Runner that runs one part of the SQL file in **one session, under one named role**, stopping on the first error | Copied and renamed; so a missing privilege stops the build instead of being hidden by an admin role | Code (`run_sql_part.py`) |
| 2 | The **target-aware guard**: a statement that changes a POC01 or POC02 object is refused before it runs, except the documented additive steps | Copied, with POC07's own exceptions and POC02's names added to the protected list — **and widened** (§7 row 3): POC02's patterns catch `CREATE OR REPLACE` but not a plain `CREATE`, and not `GRANT OWNERSHIP` | Code (`run_sql_part.py` lines 183–201, 250–265) · Critique |
| 3 | **Part 0 preflight**: read only; checks every reused object exists and fingerprints POC01's approval rows and scope values | Copied, so the build stops at once if POC01's objects are gone | Code (`poc02_build.sql` part 0) |
| 4 | The **pre-switch check** — control row reads as plaintext, no hash-shaped text, tags present, scope as expected | Becomes part of the security check (§3.3), driven by the tag config table instead of hard-coded counts | Code (`run_masking_tests.py` `_run_gate`) · Proven P2-T26 |
| 5 | The **two-session pattern**: start a long query in one session, commit a swap in another, compare | Used for "straight after the swap" and "publish twice at once" | Code (`capture_evidence.py`) |
| 6 | Key-pair test users and the key generator | Four new POC07 users (§3.5), keys in `_common/keys/` | Code (POC01 `generate_user_keys.py`) |
| 7 | Evidence capture: each claim with its SQL, the user that ran it and the verbatim result, into a self-contained HTML pack | Copied | Code · `POC_CONVENTIONS.md` §5 |

### 2.3 Already proven — not re-tested, but relied on

| # | Proven | Id | Why this POC relies on it |
|---|--------|----|---------------------------|
| 1 | A schema swap switches a set at once; a running query sees all-old, then all-new | P2-T-row6b | The publish step. This POC tests only the gap next to it: a **new** statement in another session straight after the swap (test 26) |
| 2 | The scope tag follows the schema through a swap; masking still works after | P2-T-row6c, T-row6d | Both swapped schemas carry the scope |
| 3 | A plain CTAS loses column tags; a clone keeps them | P2-T8, P2-T1 | Why the re-tag step exists; why the carry-forward clone keeps yesterday's tags; why tables in staging are untagged until re-tagged (test 11) |
| 4 | The pre-switch check refuses a corrupted load | P2-T26 | Reused inside the security check |
| 5 | `APPLY` on the two named tags is enough to set them | S2-F8 | Proven for the data owner. This POC tests it for the **publishing role inside a procedure** (test 6) |
| 6 | A writer that sees masks stores them; an all-access approval row prevents it | G1, S3-F8 | Proven for CTAS run directly. This POC tests it **inside the owner's-rights procedure** (test 21) |
| 7 | Swaps need ownership of both schemas | P2-T14a, T-row6a | The publishing role owns both |
| 8 | A masked text value can overflow its width with no error; a masked number that doesn't fit fails | G6 (S3-F20) | The width test (test 16) checks the security check catches it; it does not re-prove the behaviour |
| 9 | Removing a table-level scope override can grant access | G5 (S3-F21) | Why a wrong scope row in the config must be caught (test 7) |
| 10 | A tagged column is not always a protected one — a type with no masking rule is returned in plaintext | G3 (S2-F10, S3-F19) | Why the security check refuses tagged columns of other types (test 16) |

---

## 3. What gets built

One small test domain, `D`. The objects mirror POV §2 and §10. All names are **proposals**.

### 3.1 Objects

| # | Object | Name (proposal) | What it holds | Owner role |
|---|--------|-----------------|---------------|-----------|
| 1 | Database | `LM_P7_DOMAIN_DB` | Everything below. Scope tag `PII_SCOPE = 'P7_DOMAIN'` on the database | `LM_P7_BASE_OWNER` |
| 2 | Base schema | `…BASE` | Three base tables the "batch" loads: `CUSTOMER`, `POLICY`, `CLAIM`. Tagged sensitive columns (text, number, date), a planted control row with known plaintext, and a `LOAD_BATCH_ID` column on every row. `CLAIM` has its own scope override `P7_OTHER` | `LM_P7_BASE_OWNER` |
| 3 | Source views | `…SRC_VIEWS` | Stand-ins for the converted views: a join of `CUSTOMER` and `POLICY`; a claims summary; **a view that reads another view**; a view that narrows a tagged number column and one that turns a tagged date into a timestamp (test 16); **a view that calls a small function** (test 10). One view has a **fault switch** that makes it raise an error when a control row says so (test 23) | `LM_P7_BASE_OWNER` |
| 4 | Live schema | `…D_LIVE` | The published tables readers see. Permanent schema; scope `P7_DOMAIN`; future `SELECT` for the view-owner role | `LM_P7_PUBLISH_ROLE` |
| 5 | Staging schema | `…D_STAGE` | Where the next batch is built. Same scope and future grants as live — except where test 11's fix (b) is tried. No reader has any right on it | `LM_P7_PUBLISH_ROLE` |
| 6 | Reader views | `…D_VIEWS` | One thin view per published table, reading `D_LIVE` by name. Readers query only these. Created after the first publish, once the tables they read exist | `LM_P7_VIEW_OWNER` |
| 7 | Control schema | `…CTRL` | The tables the procedure reads and writes (§3.2). Outside the swap; readers have no access | `LM_P7_PUBLISH_ROLE` |
| 8 | Test tag schema | `…TAGS` | `P7_PROP_TEST`, a test tag with `PROPAGATE = ON_DATA_MOVEMENT` and **no masking rule**, for tag method 3 (tests 13–14). POC01's `PII` tag is never set to propagate | `LM_P7_PROP_TAG_OWNER` |
| 9 | Publishing procedure | `…CTRL.PUBLISH_DOMAIN` | The steps in §3.3. **Owner's rights**, Snowflake Scripting | `LM_P7_PUBLISH_ROLE` |

### 3.2 Control tables

| # | Table | One row per | Stands in for | Basis |
|---|-------|-------------|---------------|-------|
| 1 | `PUBLISHED_TABLES` | Published table: its source query (one or more views), build order, required yes/no | The list of reporting objects | POV §2.1 row 3, §2.4 row 16 |
| 2 | `TAG_CONFIG` | **Sensitive column:** published table and column, `PII` value, and the **base table and column it comes from** · **Table with its own scope:** expected `PII_SCOPE` · **Tagged base column deliberately not published:** base table and column, with the reason | The tag config table — now also the record the base-against-config check compares (§3.3 step 9) | POV §2.1 row 6, §3 row 3 · Critique |
| 3 | `REQUIRED_LOADS` | Load the domain needs each batch | The required-loads list (open question, POV §9 row 13) | POV §3 row 1 |
| 4 | `BATCH_LOAD_STATUS` | Load and batch, with `SUCCEEDED` or `FAILED` | **The audit framework's status.** Where the real status comes from is fact L7, still open; the POC writes it directly | POV §8.1 L7 |
| 5 | `REBUILD_STATUS` | Published table and batch, with the time it was rebuilt; **cleared for a table that fails the security check** | Per-table status for the restart | POV §10.2 row 6 · Critique |
| 6 | `EXCEPTION_APPROVAL` | Table and batch approved for release without a rebuild, with approver and reason | How an exception is recorded (open question, POV §9 row 15) | POV §3 row 4 |
| 7 | `DOMAIN_LOCK` | Domain, with holder and expiry | One publish at a time | POV §10.2 row 3 |
| 8 | `PUBLISH_LOG` | Attempt: published or refused, why, exceptions, who | The publish log | POV §3 row 5 |
| 9 | `FAULT_SWITCH` | One row: on or off | Test only — lets the restart test make one rebuild fail | Proposal |

### 3.3 The publishing procedure, step by step

POV §10.3 written out, with the critique's additions marked.

| # | Step | What it does | Basis |
|---|------|--------------|-------|
| 1 | Lock | Refuse if this batch is already published; take the domain lock, with an expiry. On any error: release the lock, log, re-raise | POV §10.2 row 3 |
| 2 | Completeness check | Every load on `REQUIRED_LOADS` has a `SUCCEEDED` row for this batch, unless an exception covers it | POV §3 row 1 |
| 3 | Rebuild | For each published table in build order, not yet rebuilt this batch: `CREATE OR REPLACE TABLE D_STAGE.<t> AS SELECT … FROM <view or views>`; record it in `REBUILD_STATUS` | POV §2.3 step 2 |
| 4 | Carry forward | For each table with an approved exception for this batch: clone it from live into staging | POV §2.3 step 2a |
| 5 | Re-tag | Tag method 1: set `PII` and any table-level `PII_SCOPE` from `TAG_CONFIG`. Methods 2 and 3 replace steps 3 and 5 in their own tests | POV §2.3 step 3 |
| 6 | **Make staging match the list** | Drop, or refuse on, any staging table not on `PUBLISHED_TABLES` — otherwise a table dropped from the domain comes back at the swap | POV §2.4 row 8 · Critique |
| 7 | Readiness gate | Every required table was rebuilt this batch or carried forward under an approval for this batch | POV §3 row 10 |
| 8 | Security check — staging against the config | Control row reads as plaintext · no hash-shaped text · every config column carries its `PII` value · every table's scope equals its expected value · widths and types (§3.4) | Code (POC02 `_run_gate`) · POV §3 row 2 |
| 9 | **Security check — the config against the base tables** | For each published table: list the base tables its views read (`GET_OBJECT_REFERENCES`), list their `PII`-tagged columns (`TAG_REFERENCES_ALL_COLUMNS`), and refuse if a tagged base column is neither mapped in `TAG_CONFIG` nor listed as deliberately not published, if a mapped value differs from the base column's, or if the expected scope differs from the source table's scope. **If the lookup errors, refuse** — never skip the check | Critique · Docs — partly stated (see the note below) |
| 10 | On a failed check | Refuse; **clear `REBUILD_STATUS` for the failing tables**, so the restart rebuilds them; release the lock; log | Critique |
| 11 | Publish | `ALTER SCHEMA D_STAGE SWAP WITH D_LIVE`; record the batch; release the lock; log | POV §2.3 step 5 |

**Note on step 9 — what the documentation says.**

| # | Point | Basis |
|---|-------|-------|
| 1 | `GET_OBJECT_REFERENCES` returns the tables and views a view references. It needs `SELECT` on the view, and ownership of any secure view in the chain | Docs — stated |
| 2 | Whether it follows views of views down to the base tables is **only shown in an example** (a view's output lists a table it reaches through another view), not stated | Docs — partly stated. Test 10 checks it |
| 3 | "If the view references stages, UDFs, or materialized views, this function returns an error" — so a real converted view that calls a function would stop the check | Docs — stated. Test 10 checks that the procedure refuses rather than skipping |
| 4 | `TAG_REFERENCES_ALL_COLUMNS` returns every tag on every column "whether the tag is directly assigned to a column or through tag inheritance", but only for a role with access to the object — so the publishing role needs access to the base tables | Docs — stated |
| 5 | Access history can't do this during the batch: its "latency for the view may be up to 180 minutes" | Docs — stated |
| 6 | A published table built from base tables with different scopes: the check refuses unless `TAG_CONFIG` names the expected scope for it explicitly | Proposal |

### 3.4 Widths and types the security check refuses

| # | Refused | Why | Basis |
|---|---------|-----|-------|
| 1 | A tagged text column narrower than 64 characters | A masked text value is 64 characters and overflows silently | Code (rule comment) · Proven G6 |
| 2 | A tagged number column with fewer than 10 digits before the decimal point | The masked number is up to 10 digits; a narrower column fails on read | Code (rule comment) · Proven G6 |
| 3 | A tagged column of any type other than text, number or date — for example a date turned into a timestamp by a view | POC01 has rules for those three types only, so another type is returned in plaintext | Proven G3 · Critique |

### 3.5 Roles and users

New roles and users only; nothing is granted to or taken from POC01's or POC02's roles and users. Each
role holds only what its row says.

| # | Role or user (proposal) | Holds | Stands in for | Basis |
|---|-------------------------|-------|---------------|-------|
| 1 | `LM_P7_PUBLISH_ROLE` | Owns `D_LIVE`, `D_STAGE`, `CTRL` and the procedure; `SELECT` on the source views; access to the base tables for the step 9 lookup; `APPLY` on `PII` and `PII_SCOPE` **only** — nothing account-wide. No person should hold it outside setup | `<D>_PUBLISH_ROLE` | POV §10.1 · Critique |
| 2 | `LM_P7_VIEW_OWNER` | Owns `D_VIEWS`; `USAGE` and future `SELECT` on both swapped schemas | `<D>_VIEW_OWNER` (Liquibase) | POV §10.1 |
| 3 | `LM_P7_BASE_OWNER` | Owns the base tables and source views; `APPLY` on the two tags | The team that owns the base layer | Proposal |
| 4 | `LM_P7_LOAD_ROLE` | Writes the base tables and `BATCH_LOAD_STATUS` — the simulated ETL, run from the operator session | The ETL's role | Critique (separate the loading from the publish) |
| 5 | `LM_P7_CALLER_ROLE` | `USAGE` on the procedure, on the database and schema that hold it, and on the warehouse — **nothing else** | The batch user's role for publishing | POV §13.1 row 10 · Critique |
| 6 | `LM_P7_READER_ROLE` | `SELECT` on `D_VIEWS` only | Report users | POV §10.1 row 4 |
| 7 | `LM_P7_GRANT_PROBE_ROLE` | **No users.** Only the target of grants added and revoked in test 18 | — | Critique |
| 8 | `LM_P7_PROP_TAG_OWNER` | Owns the test tag; holds the **account-level `APPLY TAG`** right, for tests 13–14 only (§7 row 6). Used only by the operator session | The tag owner propagation needs | Docs — stated ("Only the tag owner with the account-level APPLY TAG privilege can implement automatic tag propagation") |
| 9 | `SVC_P7_BATCH` (user) | `LM_P7_CALLER_ROLE`; an all-access (`##ALL##`) approval row, principal type `SERVICE` | The batch service user | POV §3 row 6 |
| 10 | `SVC_P7_NOROW` (user) | `LM_P7_CALLER_ROLE`; **no** approval row — a deliberate, test-only break of "every writer holds an all-access row" | A batch user missing its approval row (test 21) | Proposal |
| 11 | `N_P7_READER` (user) | `LM_P7_READER_ROLE`; one approval row: `P7_DOMAIN`, `EMAIL` | An approved report user | Proposal, following POC02 |
| 12 | `N_P7_NOAPPROVAL` (user) | `LM_P7_READER_ROLE`; no approval row | An unapproved report user | Proposal, following POC02 |

The P7 roles are granted to `SYSADMIN`, as POC02's were (`poc02_build.sql` lines 188–190), so test 11 can
show what an administrator sees in staging. Setup steps that create roles, users and databases run as
`SECURITYADMIN` and `SYSADMIN`; future grants are made by `SECURITYADMIN`, because "all future grants require
MANAGE GRANTS" (POC02's build, verified there). **No step uses `ACCOUNTADMIN`.** Every session starts with
`USE SECONDARY ROLES NONE` (POV §7).

### 3.6 Batches in the test

Each simulated batch writes a new `LOAD_BATCH_ID` (`B1`, `B2`, …) into every base row it loads, and every
published table carries that column through its view. So "all tables new, never one of each" is a
plain check: every published table shows the same batch id. *(Proposal.)*

---

## 4. Tests

Each row: what is done, what counts as a pass, and the sessions it needs. "Sessions" names who runs
it; two sessions means two connections at once through the Python runner. "Batch user" means
`SVC_P7_BATCH` calling the procedure.

### 4.1 Group 1 — gating

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 1 | Batch B2 with one required load `FAILED`, then with one load missing a status row; then the same with an exception approved | No publish in the first two, each logged as refused; with the exception, publish goes ahead and is logged with approver and reason; the security check runs every time | Load role + batch user | T10 | — |
| 2 | A required published table not rebuilt in this batch and with no exception | The readiness gate refuses; live unchanged | Batch user | T34 | — |
| 3 | Publish B2 twice in a row; then two sessions call publish for B3 at the same moment; then a run fails after taking the lock | Second publish of a batch refused; only one of the two parallel calls runs; after the failed run the lock is released (or expires) and the next batch publishes | Batch user ×2 | T17 | — |
| 4 | After the build starts, write a row to a live table; publish. Then 20 clean publishes with nothing written | The changed-since guard refuses the first. Record how many of the 20 clean runs it wrongly refuses | Publish role + batch user | T14 | Whether `LAST_ALTERED` moves on background work (S8) |
| 5 | Remove a table from `PUBLISHED_TABLES` and drop it from live; publish. Then plant an extra table in staging; publish | The dropped table does not come back; the planted table is dropped or the publish refused (step 6) | Publish role + batch user | T19 | — |

### 4.2 Group 2 — tags, method 1 (re-apply from the config)

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 6 | Full publish. Read the published tables' tags | Every column in `TAG_CONFIG` carries its `PII` value; the re-tag step ran inside the procedure under the publishing role, which holds `APPLY` on the two tags and nothing else | Batch user | T4 | — |
| 7 | `CLAIM` carries its own scope `P7_OTHER`; publish. Then set its expected scope in `TAG_CONFIG` to `P7_DOMAIN`; publish. Then remove its scope row; publish | First publish: the published claims table resolves to `P7_OTHER`. With the wrong or missing row: **the staging-against-config check alone passes** — recorded as the gap, because the approved reader would then see real claimant e-mails — and **the config-against-base check refuses**, naming the table | Batch user + approved reader | T3 | — |
| 8 | Add a new column to a base table, tag it `PII`, include it in its view; publish without updating `TAG_CONFIG`; then update it and publish | First publish refused by the config-against-base check (a tagged base column not mapped); second publishes with the column tagged | Base owner + batch user | T16 | — |
| 9 | Tag an **existing** base column that already flows through a view; publish without updating `TAG_CONFIG`; then update it and publish | As test 8 | Base owner + batch user | T16 | — |
| 10 | Run the config-against-base check on (a) the view that reads another view, and (b) the view that calls a function | (a) The lookup reaches the base table through the inner view — or, if it doesn't, that is recorded and the check is redesigned. (b) The lookup errors, and **the procedure refuses the publish** rather than skipping the check | Batch user | new | Whether `GET_OBJECT_REFERENCES` follows views of views (shown only in an example); that it errors on a view calling a function (stated) |
| 11 | **Untagged window.** Stop after the rebuild, before the re-tag; read a sensitive column in staging as the view-owner role, as the publishing role and as `SYSADMIN`; repeat after the re-tag. Then try two fixes: (a) set the tags in the CTAS's own column list; (b) no future grant on staging — the view owner gets `SELECT` on the staging tables just before the swap | Records who can read real values before the re-tag (expected: all three — the tables are untagged, so no masking applies). Fix (a) passes if the tables are tagged the moment they exist; fix (b) passes if the view owner can't read staging before the grant. The publishing role and `SYSADMIN` stay exposed under fix (b), so it relies on no person holding them | Operator (three roles) | new | Whether tags can be set in a CTAS column list — the documentation checked does not confirm it; the test decides |

### 4.3 Group 3 — tags, methods 2 and 3

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 12 | **Method 2.** Clone live into stage, then `CREATE OR REPLACE TABLE … COPY TAGS AS SELECT … FROM <view>`; then rename one column in the view and repeat | Tags kept and masking works; the renamed column loses its tag and the security check refuses | Publish role | T1, T2 | `COPY TAGS` with a view as the source (S1) |
| 13 | **Method 3.** Set the test tag on a base column. CTAS from the base table, and CTAS from a view over it; read the new tables' tags as soon as each CTAS returns. Then two sources with different tag values feed one table | Records whether the tag arrives through a table and **through a view** (not stated in the docs), whether it is there when the CTAS returns, and that the clash shows `CONFLICT` | Prop-tag owner | T5 | Propagation on CTAS (stated); through a view (not stated); `CONFLICT` by default (stated); `APPLY_METHOD = PROPAGATED` in `TAG_REFERENCES_ALL_COLUMNS` (stated) |
| 14 | **Method 3, side effects.** An existing table loaded by `INSERT` and by `MERGE` from the tagged source | Records whether the existing table picks up the tag or a `CONFLICT` value | Prop-tag owner + load role | T6 | `INSERT`, `MERGE`, `UPDATE` and `COPY INTO` propagate (stated) |

The test tag carries no masking rule, so **masking on a propagated tag is inferred** from the proven model,
not shown; the evidence pack says so. The docs also state that "inherited tags are not propagated".

### 4.4 Group 4 — masking

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 15 | After a publish, both readers query every thin view | The approved reader sees real e-mail and masked SSN (and masked e-mail in the claims table, whose scope is `P7_OTHER`); the unapproved reader sees everything masked; the thin views find the new tables after the swap | Approved reader + unapproved reader | T7 | Masking on a table column applies when read through a view (S20) |
| 16 | Publish from the view that narrows a tagged number column below 10 digits; from a table with tagged text narrower than 64; and from the view that turns a tagged date into a timestamp | The security check refuses all three before the swap, naming the columns (§3.4). These test tables must never publish | Batch user | T9 | — |

### 4.5 Group 5 — grants

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 17 | A reader tries `D_STAGE` and `D_LIVE` directly; the view owner reads through `D_VIEWS` after three swaps | Reader refused on both; view owner keeps working | Reader + view owner | T8 | — |
| 18 | Five publishes. Between them, add and later revoke `SELECT` for the probe role on the **published tables**, the way the POV's rule says: a future grant **plus** a grant on all existing tables, in **both** swapped schemas. After each swap, list every published table's grants. Then once the wrong way: grant on live only | Right way: every table's grants are exactly as last set after each swap. Wrong way: the grant is lost or reappears at the swap — showing why the rule exists | Operator (`SECURITYADMIN` for the future grants) + publish role | T15 | — |
| 19 | Give a reader `SELECT` on one original source view (a leftover grant), then query it while batch B4 is half loaded | Shows whether mid-batch data is visible through the original view — the reason readers' grants must move to the thin views | Reader + load role | T27 | — |

### 4.6 Group 6 — running under the service account

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 20 | Inside the procedure, record `CURRENT_USER()` and the owner of each rebuilt table and each carry-forward clone | Results recorded as found — the docs don't say what to expect, so this test records rather than passes or fails | Batch user | T12 | Which user the masking rule sees inside the procedure (S10); who owns objects created there (S11, S33) |
| 21 | Call the procedure as `SVC_P7_BATCH` (all-access row), then as `SVC_P7_NOROW` (no row) | With the row, the published tables hold real values; without it, masks are stored **and the security check refuses the publish** | Batch user, then no-row user | T12 | Masking applies to what a CTAS reads unless the user is approved (S19), inside a procedure |
| 22 | The whole publish, end to end, as `SVC_P7_BATCH` holding **only** the caller role, with recorded session settings (`AUTOCOMMIT`, `LOCK_TIMEOUT`, `STATEMENT_TIMEOUT_IN_SECONDS`). Then with a statement timeout shorter than the longest rebuild; afterwards, check the lock | First run publishes with no manual step, no admin role and nothing but the caller role's `USAGE` rights (§3.5 row 5). Second run publishes nothing; record whether the timeout cut the call itself and whether the lock was released or left to expire; the restart then finishes it | Batch user | T11 | The procedure takes these settings from the caller (S29); whether a timed-out call still runs its error handler — not established |

### 4.7 Group 7 — restart and partial release

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 23 | (a) Turn the fault switch on so one rebuild fails; publish; turn it off; restart. (b) Publish as `SVC_P7_NOROW` (masks stored, refused, test 21); restart as `SVC_P7_BATCH` with the same batch id | (a) No swap; readers still see the previous batch; the restart rebuilds only the failed table and those after it, then publishes once. (b) The refused tables lost their "rebuilt" status, so the restart rebuilds them and publishes — the domain is not left stuck | Batch user + no-row user + reader | T35 | — |
| 24 | One table's sources do not refresh in B5; approve an exception for it; publish | That table shows **B4** (yesterday) — not B3, which staging held — with its tags and masking intact; its thin view still works, and the copy picked up staging's automatic grants; every other table shows B5 | Publish role + batch user + reader | T36 | — |
| 25 | In B6, the same table again has no rebuild and no new approval | The readiness gate refuses: the B5 approval does not carry over | Batch user | T37 | — |

### 4.8 Group 8 — straight after the swap

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 26 | Session 1 publishes; session 2, as soon as the swap returns, runs one statement joining **two thin reader views** and reads both batch ids. Repeat 200 times | Every run shows the same batch id in both. **Medium strength:** a pass shows a mix did not happen in these runs, not that it cannot | Batch user + reader | T20 | Whether another session sees the swap straight away under the default read setting (S15, S27). The account-level setting is **not** changed |

### 4.9 Group 9 — optional

Run only if agreed in review (§10 row 4).

| # | Test | Pass if | Sessions | POV id | Snowflake behaviour confirmed |
|---|------|---------|----------|--------|-------------------------------|
| 27 | Rebuild from the views `AT (TIMESTAMP => …)` while a base load runs in a second session | Every table reflects the same moment; tags and masking intact | Batch user + load role | T18 | Reading a view "as of" one moment with `AT`, inside a CTAS (S7) |
| 28 | A stream on one published table, through one publish | Records whether the stream goes stale | Publish role | T28 | `OR REPLACE` makes a stream stale (S26) |

### 4.10 Recorded along the way

| # | What | Why | POV id |
|---|------|-----|--------|
| 1 | Time for each rebuild, the re-tag step and both parts of the security check, as the batch user with masking on | Indicative only, on sample data. Real volumes are a team fact | L5 |
| 2 | Row counts and batch ids of every published table after every publish | The evidence behind "all new, never mixed" | — |
| 3 | Which privilege on the base tables the step 9 lookup needed | Least privilege for the publishing role | — |

---

## 5. Requirement matrix — which test meets which requirement

Requirements from POV §1.2. Status assumes this draft, run as written. Adapted from the critique's §5.

| # | Requirement | Tests | Status |
|---|-------------|-------|--------|
| R1 | Users keep seeing the last complete data while a refresh runs | 4, 23, 26 (plus proven P2-T-row6b) | Covered |
| R2 | New data visible only when all its loads have finished | 1, 2 | Covered |
| R3 | Whole domain consistent — never part old, part new | 26; 27 optional | **Partly.** Test 27 is needed if base loads can overlap the rebuild (team fact L2) |
| R4 | A batch that fails partway is not released | 1, 22, 23 | Covered |
| R5 | The business can release a partial load, by a manual step | 1, 24, 25 | Covered |
| R6 | Publishing is one controlled event | 2, 3, 5 | Covered |
| R7 | No mass rewrite of views | — | **Not covered.** Needs the team's real views (§9 row 3) |
| R8 | Each refreshed object gets its tags back | 6–10, 12–14, 24 | Covered, **if** the config-against-base check works — which tests 7–10 themselves test |
| R9 | Correct masking on sensitive data | 15, 16, 21 | Covered |
| R10 | Grants kept or re-applied after every refresh | 17, 18, 19, 24 | Covered |
| R11 | Nothing opened to users until its security is back | 11, 16, 17, 21 | Covered for report readers. **For roles that can read staging, only if a fix in test 11 works** |
| R12 | Batch accounts read real values; users see only what masking allows | 15, 21 | Covered |
| R13 | Re-applying security is automatic | 6, 22 | Covered |
| R14 | The whole refresh runs under the batch service account | 20, 21, 22 | Covered |
| R15 | Objects the service account creates aren't treated as orphans | 20 records the owners | **Partly.** The exception itself is a platform decision (POV §9 rows 1, 14) |

---

## 6. Run order

One SQL file, split into parts. Each part runs in one session under the role named; the runner stops on
the first error. Each part runs only after it is approved; parts that use `SECURITYADMIN` are flagged.
*(Proposal, following POC02's file.)*

| # | Part | What it does | Role | Changes the account? |
|---|------|--------------|------|----------------------|
| 1 | 0 — preflight | Checks POC01's tags, rules and approval table exist; fingerprints POC01's approval rows and scope values; checks no `LM_P7_` name is taken | `LM_PII_POLICY_ADMIN` | **No — read only.** The build stops here if POC01's objects are gone |
| 2 | A — roles and database | Creates the eight roles (granted to `SYSADMIN`) and `LM_P7_DOMAIN_DB` | `SECURITYADMIN`, then `SYSADMIN` | Yes — new objects only |
| 3 | B — additive steps on shared objects | Adds scope values `P7_DOMAIN` and `P7_OTHER` to `PII_SCOPE` (add only); grants `APPLY` on the two tags to the publishing and base-owner roles, plus `USAGE` on the tag schema and its database, which resolving the tag names needs (POC02 part B needed the same) | `LM_PII_TAG_ADMIN`, `SECURITYADMIN` | Yes — **additive on POC01 objects**, as POC02 did |
| 4 | B2 — the one account-level grant | `APPLY TAG` on the account to `LM_P7_PROP_TAG_OWNER`. Run just before tests 13–14 and approved on its own | `SECURITYADMIN` | Yes — **flagged** (§7 row 6). Revoked straight after tests 13–14 and again checked at teardown |
| 5 | C — base layer | Base tables with tags and control rows, the source views (including the view on a view, the function-calling view and the narrowing views), the fault switch, the test tag | `LM_P7_BASE_OWNER`, `LM_P7_PROP_TAG_OWNER` | Yes — new objects |
| 6 | D — publishing layer | `D_LIVE`, `D_STAGE`, the `D_VIEWS` schema, `CTRL`; scope on both swapped schemas; future grants; control tables; the publishing role's access to the base tables | `LM_P7_PUBLISH_ROLE`, `LM_P7_VIEW_OWNER`, `SECURITYADMIN` | Yes — new objects |
| 7 | E — users | The four users, with public keys put in from disk at run time | `SECURITYADMIN` | Yes — new users |
| 8 | F — approval rows | Rows `PIA-P7-…` for `SVC_P7_BATCH` (all-access, `SERVICE`) and `N_P7_READER` (one attribute); checks POC01's rows are untouched | `LM_PII_POLICY_ADMIN` | Yes — **additive on POC01's approval table** |
| 9 | G — procedure | `CTRL.PUBLISH_DOMAIN` (§3.3) | `LM_P7_PUBLISH_ROLE` | Yes — new object |
| 10 | H — first publish | Batch B1, published, as the starting point for the tests; then the thin reader views and readers' grants on them | `SVC_P7_BATCH`, then `LM_P7_VIEW_OWNER` | Yes |
| 11 | Tests | Groups 1–8 in order (part B2 just before group 3's tests 13–14), then group 9 if agreed | As §4 | Yes, inside `LM_P7_DOMAIN_DB` only |
| 12 | Evidence | Timestamped results, then the HTML pack | Read only | No |
| 13 | Teardown | Drops `LM_P7_` objects, POC07's approval rows and its two scope values (exactly those); confirms the account-level grant is gone; re-runs the part 0 fingerprint and compares. Dry run by default | As parts 0–F, reversed | Yes — removes only what POC07 added. Run only after the pack is saved |

---

## 7. Safety rules

| # | Rule | Why | Basis |
|---|------|-----|-------|
| 1 | Everything POC07 creates is named `LM_P7_…`, `SVC_P7_…`, `N_P7_…`, `PIA-P7-…` or `P7_…` | Separates it from POC01 and POC02, and lets teardown remove exactly what was added | Proposal, following POC02 |
| 2 | POC07's own scope values (`P7_DOMAIN`, `P7_OTHER`), never POC01's or POC02's | Approvals are keyed on user, attribute and scope, so a shared scope value would share approvals between POCs | Code (POC02 `poc02_names.py`, "why POC02 uses its own scope values") |
| 3 | The guard refuses any statement that changes a POC01 or POC02 object, except the additive steps in parts B and F. **Widened beyond POC02's:** it also checks plain `CREATE … <name>`, `GRANT OWNERSHIP ON … <name>`, and any `SET TAG` / `UNSET TAG` on an object outside `LM_P7_DOMAIN_DB`; and it refuses any `DELETE` on the approval table that does not name `PIA-P7-` ids | A mistyped name costs nothing. The widening closes the gaps POC02's patterns leave, and matters most while the account-level tag right exists | Code (POC02 `run_sql_part.py` lines 183–201) · Critique |
| 4 | **Never run POC01's `run_masking_tests.py` or `capture_evidence.py` while POC02 or POC07 rows exist** | Both delete every approval row not on their keep list (`PIA-S3-0001`, `0002`, `0003`, `0005`) — which would remove POC07's and POC02's rows (and POC01's own `PIA-S3-0004`). The batch user would then store masks, and results would be wrong | Code (POC01 S3v2 `run_masking_tests.py` lines 175–186; `capture_evidence.py` line 892) |
| 5 | POC01's approval rows and scope values are fingerprinted in part 0 and checked again at teardown | Proves POC07 left POC01 as it found it | Code (POC02 part 0) |
| 6 | No `ACCOUNTADMIN`; no account setting changed — in particular not `READ_CONSISTENCY_MODE`. **The one account-level grant** is `APPLY TAG` to `LM_P7_PROP_TAG_OWNER` for tests 13–14: approved on its own, held for as short a time as possible, revoked after them | The docs describe it as "the ability to add or drop a tag on a Snowflake object" — not limited to the test tag — so it is held by one role, used only by the operator, with the guard (row 3) blocking tag changes outside POC07's database | Docs — stated (access control privileges) · Proposal |
| 7 | POC01's `PII` tag is never set to propagate | Propagation on it would reach every pipeline that moves tagged data; only POC07's test tag is used | Docs — stated (propagation covers CTAS, `INSERT`, `MERGE`, `UPDATE`, `COPY INTO`) · Critique |
| 8 | Test-only exceptions are named: the narrow and wrong-type tables (test 16) and `SVC_P7_NOROW` (tests 21, 23) break rules on purpose and must never publish | POC02's checklist rules on widths and on writers' approval rows still hold everywhere else | Critique (POC02 checklist C7, C11) |
| 9 | `USE SECONDARY ROLES NONE` on every connection — build, tests, evidence and teardown | Secondary roles once supplied a missing privilege in POC02 and hid it | POV §7 |
| 10 | Sample data only, with `example.invalid` addresses and made-up numbers | No real personal data in a POC | Code (POC01 and POC02 test data) |
| 11 | Private keys stay in `_common/keys/`, never committed, deleted at teardown | `POC_CONVENTIONS.md` §6 | Docs (conventions) |
| 12 | Teardown runs only after the evidence pack is saved | Once the objects are gone, the pack can't be regenerated | Code (POC01 README, teardown) |

---

## 8. Evidence

| # | Output | Rule |
|---|--------|------|
| 1 | `03_evidence/poc07_test_results_<timestamp>.json` and `.md` — one pair per run, never overwritten | `POC_CONVENTIONS.md` §5 rows 1–2 |
| 2 | A self-contained HTML evidence pack: each test with its SQL, the user and role that ran it, and the verbatim result | §5 row 3 |
| 3 | A "not proven" table in the pack, listing everything in §9 below, masking on propagated tags (inferred, §4.3), and anything a run could not settle | §5 row 4 |
| 4 | Once the pack exists, its results move into the findings register §3 as `P7-…` ids, and the POV is updated from it | Register rule: a POC's claims are settled only once its pack exists |

---

## 9. Not in this POC

| # | Item | Why not | Where it is settled instead |
|---|------|---------|-----------------------------|
| 1 | Domain lists, schemas, load timing, report names, view layout, incremental loads, where batch status comes from | Facts only the team can give | POV §8.1, facts L1–L4, L6, L7 |
| 2 | Real rebuild time against the batch window | Sample data says nothing about real volume; recorded as indicative only (§4.10) | POV §8.1 L5 — a timed run at real volume |
| 3 | The effort of turning real converted views into published tables | Needs three real views and the team's judgement | POV §7 test T13 — needs the views from the team |
| 4 | Propagation on POC01's real `PII` tag | It would reach every pipeline that moves tagged data; the POC uses a test tag only | POV §4.2, §9 row 11 — governance agreement first |
| 5 | The Clone + Swap thread, including "do the ETL's reads move to staging" | The parallel thread, taken further only if CTAS + Swap fails a must-pass test | POV §11.6, §12 |
| 6 | Not being treated as orphans by the platform | A platform decision, not a Snowflake behaviour | POV §9 rows 1 and 14 |
| 7 | Whether to switch the account to `READ_CONSISTENCY_MODE = 'GLOBAL'` | Account-level, `ACCOUNTADMIN` only; the POC reports what it saw under the default (test 26) | POV §9 row 7 |
| 8 | The real scheduler's session settings | The POC uses recorded stand-in values | POV §9 row 8 |
| 9 | Sequences | Draft v1 tested one on a base table, which the swap never touches. Whether any published table needs a sequence is a fact for the team | POV §2.4 row 9 |

---

## 10. To settle before building

No owners are given.

| # | Point | Why it matters |
|---|-------|----------------|
| 1 | **Are POC01's and POC02's objects still on the account?** The critique reports a read-only check on 26 October 2026 that found them all present; part 0 confirms it at build time | If POC01's tagging model is gone, part 0 stops and it has to be rebuilt from POC01's script first |
| 2 | Agreement to add POC07's two scope values to the shared scope tag and POC07's rows to the shared approval table | The only changes to POC01 objects — additive, as POC02 did, and removed at teardown |
| 3 | Approval for the one account-level grant (part B2) | Needed only for tag method 3; broad while it exists (§7 row 6) |
| 4 | Whether to run the optional group (§4.9) | The "as of" read matters only if base loads can overlap the rebuild (fact L2); streams matter only if they exist |
| 5 | How many repeats for the "straight after the swap" test (200 proposed) | More repeats give more confidence, but never a proof |
| 6 | Where the SQL, scripts and evidence live: beside this design in `TEST_IN_SF/`, or in `2_Deliverables/POC/_common/` as the folder rules say | This design sits in `TEST_IN_SF/` at the user's request (26 October 2026), not where the folder rules put a POC design |
| 7 | Which connection runs setup | POC01 and POC02 used one operator connection that can switch to `SECURITYADMIN` and `SYSADMIN` |

---

## 11. Sources

| # | Source | Used for |
|---|--------|----------|
| 1 | [`POC07_POV.md`](<../2_Deliverables/POC07_POV.md>) v10 — §1.2, §2.3, §2.4, §3, §4.2, §7, §8.2, §9, §10, §13 | Requirements, steps, rules, tests, roles, open questions |
| 2 | [`ALREADY_PROVEN_POC_FINDINGS.md`](<../../ALREADY_PROVEN_POC_FINDINGS.md>) §2–§6 | What is proven and not re-tested; gaps G1, G3, G5, G6 |
| 3 | [CoCo's critique of draft v1](<POC07_Test_Design_CTAS_Swap_critique.md>) | Every change in v2; the requirement matrix |
| 4 | `POC01_pii_masking_policies/2_Deliverables/POC/S3v2_complete_proof/02_scripts/poc_names.py` and `README.md` | Names of the reused objects; teardown rules |
| 5 | `POC01_pii_masking_policies/2_Deliverables/POC/S3v2_complete_proof/01_sql/pii-masking-service-accounts-v2.sql` lines 312, 326 | The width limits in the rules' comments |
| 6 | `POC01_pii_masking_policies/2_Deliverables/POC/S3v2_complete_proof/02_scripts/run_masking_tests.py` lines 175–186; `capture_evidence.py` line 892 | The approval-row deletion (§7 row 4) |
| 7 | `POC02_zero_downtime_refresh/2_Deliverables/POC/_common/02_scripts/poc02_names.py` | How POC02 reused POC01's objects; own scope values and approval ids; the protected-name list |
| 8 | `POC02_zero_downtime_refresh/2_Deliverables/POC/_common/01_sql/poc02_build.sql` parts 0, A, B, F, H; lines 188–190, 503–505 | Preflight, roles granted to `SYSADMIN`, future grants by `SECURITYADMIN`, additive steps |
| 9 | `POC02_zero_downtime_refresh/2_Deliverables/POC/_common/02_scripts/run_sql_part.py` lines 176–265 | One part, one session, one role; the guard and its gaps |
| 10 | `POC02_zero_downtime_refresh/2_Deliverables/POC/_common/02_scripts/run_masking_tests.py` (`_run_gate`) | The pre-switch check |
| 11 | `POC02_zero_downtime_refresh/2_Deliverables/POC/_common/02_scripts/capture_evidence.py` (schema-swap capture) | The two-session pattern |
| 12 | [`../../POC_CONVENTIONS.md`](<../../POC_CONVENTIONS.md>) | Folder shape, evidence rules, key handling |
| 13 | Snowflake docs, checked 26 October 2026: [GET_OBJECT_REFERENCES](https://docs.snowflake.com/en/sql-reference/functions/get_object_references) · [TAG_REFERENCES_ALL_COLUMNS](https://docs.snowflake.com/en/sql-reference/functions/tag_references_all_columns) · [ACCESS_HISTORY](https://docs.snowflake.com/en/sql-reference/account-usage/access_history) · [Automatic tag propagation](https://docs.snowflake.com/en/user-guide/object-tagging/propagation) · [Access control privileges](https://docs.snowflake.com/en/user-guide/security-access-control-privileges) | §3.3 note, tests 10 and 13–14, §7 rows 6–7 |
| 14 | Snowflake docs as listed in POV §15 | Everything else |

---

*Last updated: 26 October 2026 — draft v2, for review.*
