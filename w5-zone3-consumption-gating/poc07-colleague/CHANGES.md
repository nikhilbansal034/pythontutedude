# `Nikhil - 2` — what changed, and why

**A corrected copy of the parallel test suite in `../NIkhil/`. The original is untouched.
Nothing in either folder has been run.**

| # | Field | Value |
|---|-------|-------|
| 1 | Source | `2_Deliverables/NIkhil/tests/*.sql` + `evidence/POC07_CTAS_Swap_Test_Tracker.xlsx`, copied 27 October 2026 |
| 2 | Author of the original | A colleague, working independently from the same brief |
| 3 | Status of the original | 12 files, ~235 KB, 48 test cases, **all 48 marked "Not run"** in the tracker |
| 4 | What this copy is | The same suite with 12 defects fixed, so it can be executed and will show what it claims |
| 5 | What this copy is **not** | A merge with `POC07_DESIGN.md`. It keeps the original's object model (`P7_POC`), id scheme (`TC-NN.N`), own governance copy and no-stored-procedure stance |
| 6 | Design document | [`../POC07_DESIGN.md`](../POC07_DESIGN.md) v14. The case-by-case map between `TC-NN.N` and `T<n>` is in [`../POC07_TEST_DESIGN.md`](../POC07_TEST_DESIGN.md) §10 |
| 7 | Still open | **One id scheme must be chosen** before either suite produces evidence (test design §9.6). This copy does not decide that |

---

## 1. The finding that came out of reviewing it

Checking what `s07` `TC-07.4` *should* have done exposed a correctness fault in our own
design document, not just a defect in this suite:

> **A rebuild cannot repair a tag failure.** `COPY TAGS` copies a table's tags *from the table it
> replaces*. So rebuilding a staging table whose tags are missing produces another table whose tags
> are missing — the security check refuses it again, and repeating the restart never fixes it. Only
> `ALTER TABLE … SET TAG` on the table already in staging fixes it, and then no rebuild is wanted.

Our design said a refused table loses its "rebuilt" mark and the restart fixes it. That is right for
a **data** refusal and wrong for a **tag** refusal. Fixed in design v14 (§2.3 steps 3 and 6, §2.4
rows 15 and 22, new test `T40`, new decision `D25`).

The original suite got close by accident: its remedy *was* an in-place `SET TAG`. But it had no CTAS
between the failure and the fix, so it never showed that the rebuild route fails — and so never
showed why the in-place fix is the only one that works. `TC-07.4` here proves both halves.

---

## 2. Must-fix — the suite could not run, or could not show its finding

| # | Where | Defect in the original | Change |
|---|-------|------------------------|--------|
| 1 | `s03` `TC-03.3` | **Errored instead of demonstrating.** The view renames `email` to `email_address`; the probe still selected `email`, so the statement failed with "invalid identifier" and the finding — an untagged renamed column readable in the clear — was never shown | Probe now selects `email_address` |
| 2 | `s09` `TC-09.2` | **Not executable.** A bare `SWAP` plus a prose instruction to "repeat at least 50 times". No loop, no counter, nothing captured | Two runnable anonymous blocks, one per session: the reader loops 50 times recording each reading, the publisher loops 25 swaps. Plus a verdict query and a results table. **No stored procedure is created**, so the suite's deliberate stance is unchanged |
| 3 | `s09` `TC-09.3` | **Not executable.** The reader's query was left commented out, so nothing ran and nothing was captured | Both sides runnable and both recording. The account's `READ_CONSISTENCY_MODE` is now read at run time and the expectation explains how to read a SESSION-mode lag (which is not a fault) against a genuine mixture (which is) |
| 4 | `s01`, `s05`, `s06`, `s07`, `s10` — 8 places | **Contradictory `EXPECT` comments.** A generic boilerplate line (`distinct_batches = 1, batch_seen = B<n>`) left immediately above a correct scenario-specific one. In 5 of the 8 the two disagreed outright, so a runner reading the first line would record the wrong result | The generic line removed in all 8; the scenario-specific line kept |

New supporting object: `CTRL.ATOMICITY_RESULTS`, created by `s09` (`CREATE TABLE IF NOT EXISTS`).

---

## 3. Should-fix — the case did not prove what it claimed

| # | Where | Defect in the original | Change |
|---|-------|------------------------|--------|
| 5 | `s07` `TC-07.4` | **Proved nothing.** It unset the tags, flipped the status to `FAILED`, then re-set the tags and flipped back to `COMPLETED` **with no CTAS in between**. That shows a status column can be updated | Split into **Part A — the wrong remedy** (clear the mark, run the restart's CTAS, show the tags are *still* missing and the refusal repeats) and **Part B — the right remedy** (in-place `SET TAG`, no rebuild, publish proceeds). Part A is the finding; do not skip it |
| 6 | `s05` `TC-05.3` | **A block that can never be cleared.** The gate reads `exception_flag` from the dependency's own `BATCH_STATUS` row. With no row there is nothing to flag, so a missing dependency can never be exception-approved — the domain is stuck until someone writes a status the ETL never reported, which puts a fiction in the control table. `TC-05.3` proved the block; nothing tested approving it | Two cases added. **`TC-05.3b`** proves the dead end, including that the `UPDATE` is a *silent no-op* — the worst outcome, because the approver believes they cleared it. **`TC-05.3c`** shows the fix: approvals in their own table, keyed on `(batch_id, object_name)` with an approver and a reason, and a gate with one extra `LEFT JOIN`. Includes the reset test, so the approval cannot leak into the next batch |
| 7 | `s08` line 170 | **Open privilege window.** `GRANT ALL ON SCHEMA D_STAGE` to an unentitled role, revoked ~115 lines later — in a scenario that deliberately contains statements expected to behave oddly. On an abort the grant is left in place | Narrowed to `USAGE, CREATE TABLE` (what the build actually needs). A warning at the grant gives the exact revoke to run by hand on abort. The revoke is now **verified** by a `SHOW GRANTS` check rather than assumed |
| 8 | `s08` `TC-08.4` | The ownership repair (`GRANT OWNERSHIP … COPY CURRENT GRANTS`) read as a tidy-up | Labelled as the prerequisite it is — without it the publishing role cannot replace the table next batch and the run fails on privileges, not on data — and the repair is now verified before being relied on |
| 9 | `s10` `TC-10.3` | **Rollback logged as `REFUSED`.** B2 *was* published: readers saw it for however long it took to spot the problem. Logging that as `REFUSED` says it never went out, which is the opposite of the truth and the one fact an incident review needs | `PUBLISH_LOG.outcome` gains `ROLLED_BACK` (`00_setup.sql`); `TC-10.3` uses it; `TC-10.4` adds an audit query that derives, per batch, whether it reached readers and whether it was withdrawn — a query that **cannot be written** while a rollback is logged as a refusal |
| 10 | `s03`, `s04`, `s07` headers | Batch ranges wrong, so a reader planning a run would reserve the wrong ids | `s03` B1–B4 → **B1–B7** · `s04` B1–B4 → **B1–B3** · `s07` B1–B4 → **B1–B5**. Verified against the batch ids each file actually uses |

New supporting object: `CTRL.EXCEPTION_APPROVAL`, created by `00_setup.sql`.

---

## 3b. Run-enablement fixes — found when preparing to execute

The setup file could not complete as written. Confirmed from the account, not inferred: **`00_setup.sql`
had already been attempted on 26 October and stopped partway.** `SNOWFLAKE.ACCOUNT_USAGE` shows all
seven `P7_*` roles (21:43:55–21:44:01), database `P7_POC` (21:44:53) and all seven schemas
(21:44:55–21:45:01) — and **zero tables**. Schema creation ends at line 89; the next statement was the
first warehouse grant. It died exactly there.

| # | Where | Problem | Change |
|---|-------|---------|--------|
| 13 | `00_setup.sql` line 36 | **`SET wh = 'COMPUTE_WH'` — that warehouse does not exist on this account.** `SHOW TERSE WAREHOUSES LIKE '%COMPUTE_WH%'` returns no rows, so all seven `GRANT USAGE ON WAREHOUSE IDENTIFIER($wh)` statements were bound to fail | `SET wh = 'LM_PII_POC_WH';` — the shared POC warehouse, referenced 36 times across POC01 and POC02 SQL and the `WAREHOUSE` constant in their `poc02_names.py`. X-Small, auto-resume, monitor `RM_LM_PII_POC_WH` at 100 credits monthly with 0.00 used |
| 14 | `00_setup.sql` lines 91–97 | **The seven warehouse grants run under `SYSADMIN`** (set at line 79), but `LM_PII_POC_WH` is owned by `ACCOUNTADMIN` and `SYSADMIN` holds no grant on it. `SHOW GRANTS ON WAREHOUSE LM_PII_POC_WH` returns `OWNERSHIP` to `ACCOUNTADMIN` plus twelve `USAGE` grants, **every one `granted_by ACCOUNTADMIN`**, none carrying `grant_option`. This is what killed the 26 October run | Wrapped in `USE ROLE ACCOUNTADMIN;` … `USE ROLE SYSADMIN;`, which is how POC01 and POC02 granted this same warehouse. Added a verification `SELECT` expecting `p7_usage_grants = 7`, so a silent shortfall cannot slip through |
| 15 | `00_setup.sql` header, point 3 | **An untrue scope claim.** It said *"Nothing here touches POC01 or POC02 objects."* After fix 14 that is false: the seven grants add `USAGE` on the shared warehouse | Rewritten to state exactly what is touched — seven grants on `LM_PII_POC_WH`, which disappear with the roles at teardown — and what is not: no POC01 or POC02 tag, policy, table or entitlement row. Also records that this is the suite's **only** `ACCOUNTADMIN` use, and that it is setup plumbing, not a test |
| 16 | `s07_restart.sql` line 344 | A wrapped prose line in the `TC-07.4` rewrite began `   TC-07.3 does. This is…`, which is indistinguishable from a TC banner to anything parsing the files. It inflated the case count by one | Reflowed so the id is not at the start of a line |

### The case inventory, settled

Needed before any count in the evidence deck can mean anything. Counting banner lines followed by the
`---` divider:

| File | Cases | File | Cases |
|------|-------|------|-------|
| `s01_day1_first_publish` | 6 | `s06_exception_approval` | 5 |
| `s02_steady_state` | 5 | `s07_restart` | 5 |
| `s03_tags` | 4 | `s08_masking` | 5 |
| `s04_grants` | 7 | `s09_atomicity` | 3 |
| `s05_dependency_gating` | 6 | `s10_rollback` | 4 |

**50 cases total** — the original 48 plus `TC-05.3b` and `TC-05.3c` from row 6 above. No duplicate ids.

---

## 3c. Defects found by actually running it

Rows 13–16 were found while *preparing* to run. These were found by **running**, which is the only
way they could have been found: each one is a role or privilege problem that no amount of reading
reliably catches. The pattern is consistent and worth stating plainly:

> **Nine of the eleven run-blocking defects are the same mistake — a statement left running under
> the wrong role.** Snowflake drops the database context when you switch to a role with no `USAGE`
> on it, and a reader role deliberately cannot see the published tables. So a check that follows a
> reader check, or follows a `USE ROLE SECURITYADMIN`, fails on privileges rather than on anything
> being tested. None of it is visible in the SQL unless you track the in-force role line by line.

| # | Where | Defect | Change |
|---|-------|--------|--------|
| 17 | `00_setup.sql`, two future grants | **Future grants need `MANAGE GRANTS`, not schema ownership.** Run as `P7_BASE_OWNER` they failed: *"Insufficient privileges to operate on SCHEMA 'BASE'. Your primary role P7_BASE_OWNER must have MANAGE GRANTS granted on ACCOUNT DELOITTENA."* | Moved under `SECURITYADMIN`. It matters because scenarios rebuild the source views, and `CREATE OR REPLACE` drops an object's grants — without the future grant the publisher loses `SELECT` on the view it must read |
| 18 | `00_setup.sql`, `MASK_PII` | **`CREATE OR REPLACE MASKING POLICY` makes the file impossible to re-run.** Once `ALTER TAG ... SET MASKING POLICY` attaches it: *"Policy MASK_PII cannot be dropped/replaced as it is associated with one or more entities."* A setup that stopped part-way could only be recovered by a full teardown | `CREATE MASKING POLICY IF NOT EXISTS`. The `ALTER TAG ... SET` beside it is idempotent — verified by running it twice. **Trade-off stated in the file:** an edit to the policy body is then not applied on a re-run |
| 19 | All 10 scenarios, 58 grants | **Unqualified grants after `USE ROLE SECURITYADMIN`.** `SECURITYADMIN` holds no `USAGE` on `P7_POC`, so switching to it **drops the session's current database** and `IN SCHEMA D_LIVE` fails: *"Cannot perform GRANT. This session does not have a current database."* These grants are what give `P7_VIEW_OWNER` `SELECT` on the published tables, so the reader views could not be created and **every reader check in every scenario failed** | Fully qualified to `IN SCHEMA P7_POC.D_LIVE`. Adding `USE DATABASE` would not work — `SECURITYADMIN` cannot use a database it has no `USAGE` on, which is why Snowflake's own error suggests qualifying the name |
| 20 | All 10 scenarios, 44 tag checks | **No check filtered to the `PII` attribute tag.** The reset sets a schema-level tag (`ALTER SCHEMA D_LIVE SET TAG PII_SCOPE`), and Snowflake **inherits a schema tag onto every column**. `TAG_REFERENCES_ALL_COLUMNS` reports inherited tags, so a 6-column table returned 8 rows where 2 were expected, and 6 where 0 were expected. Every one of the 44 checks failed while the behaviour under test was correct | Added `WHERE TAG_NAME = 'PII'`. **POC02 hit this exact trap** and left a comment about it in `run_masking_tests.py`; the comment did not travel to this suite |
| 21 | `s01` `TC-01.2` | **An arithmetically impossible expectation.** It expected `distinct_batches = 1` over an empty `D_LIVE`. `COUNT(DISTINCT batch_id)` over an empty set is 0, so the check could only ever fail | Corrected to 0. The point it makes — nothing was published — is right, and 0 is what proves it |
| 22 | `s02`, 4 places | **The drift fingerprint ran as the reader.** After each publish, `s02` switches to `P7_READER_OK` to confirm what a report sees, then reads `D_LIVE` directly for the tag and grant snapshot — which readers deliberately cannot see. Both statements failed, and the `RESULT_SCAN` cascaded off the failed `SHOW`. **Twelve errors, and the four-batch drift comparison that is the entire point of the scenario never happened** | `USE ROLE P7_PUBLISH_ROLE` before each fingerprint. `TC-02.5`'s own comparison already did this, which is how the four snapshots were clearly meant to run |
| 23 | `s10` `TC-10.3` | Same defect as row 22, in the rollback fingerprint | Same fix |
| 24 | `s04`, 2 places | **`SHOW GRANTS` + `RESULT_SCAN` under `SECURITYADMIN`.** `SHOW` is metadata and needs no warehouse, so it succeeded; the `RESULT_SCAN` select is a query and failed with *"No active warehouse selected in the current session."* The check reported nothing while appearing to have run | `USE ROLE P7_PUBLISH_ROLE` before the pair — it owns the tables and has warehouse usage |
| 25 | `99_teardown.sql` | Same defect as row 24, in teardown's own "confirm nothing is left" queries. **A verification step that cannot run is worse than none, because it looks like it passed** | `USE ROLE ACCOUNTADMIN; USE WAREHOUSE ...` before the confirmations |
| 26 | `00_setup.sql`, `P7_BATCH_NOENT` | **The unentitled writer lost its `SELECT` mid-suite.** It had `GRANT SELECT ON ALL VIEWS` but no future grant, and `s03` does `CREATE OR REPLACE VIEW` on the source views, which drops their grants. So by the time `s08` `TC-08.4` ran — the case that proves an unentitled writer stores masks — it could no longer read the view it was meant to rebuild from, and failed on privileges instead of demonstrating anything | Future grants on `BASE` and `SRC_VIEWS` for `P7_BATCH_NOENT` as well as `P7_PUBLISH_ROLE`. `ALL` + `FUTURE` together is what makes a grant survive the suite's own rebuilds |

### Two that were not defects

Worth recording, because the harness got them wrong before the SQL did:

| # | Case | What happened |
|---|------|---------------|
| 27 | `s07` `TC-07.2` | Graded `ERROR`, but the failure is **deliberate**: the file renames the source view to break the rebuild, and says so — *"THIS STATEMENT IS EXPECTED TO FAIL — object does not exist. Run it, copy the error into the evidence tab, then continue."* The harness only read `EXPECT` notes that FOLLOW a statement, and this convention puts the note before it. **Harness fixed, not the SQL** |
| 28 | `s08` `TC-08.3` | Same cause: *"BOTH of these are EXPECTED TO FAIL"* precedes two probes. Both now grade as passes — a reader being refused `D_LIVE` and `D_STAGE` is exactly what the case proves |

### `s08` `TC-08.4` — three defects in one case

The case that proves an unentitled writer stores masks could not run at all. Each fix exposed the next:

| # | Defect | Change |
|---|--------|--------|
| 29 | **`CREATE OR REPLACE` on an existing table needs OWNERSHIP of it**, not `CREATE TABLE` on the schema. `P7_BATCH_NOENT` was given schema privileges and told to rebuild a table owned by `P7_PUBLISH_ROLE`: *"Table 'CUSTOMER_360' already exists, but current role has no privileges on it."* **Verified that the original `GRANT ALL ON SCHEMA` fails identically** — schema privileges never confer ownership of pre-existing objects — so this is not a consequence of narrowing that grant in row 7 | Transfer ownership of the staging table to `P7_BATCH_NOENT` before the build. It also makes the case coherent: the repair at the end hands ownership *back*, which only means something if the writer held it |
| 30 | **An ownership transfer `WITH COPY CURRENT GRANTS` needs `MANAGE GRANTS`**, which the losing owner does not have: *"Insufficient privileges to operate on grant ownership 'with copy current grants'. Your primary role P7_PUBLISH_ROLE must have MANAGE GRANTS..."* This applies to the suite's own repair statement too, which ran as `P7_BATCH_NOENT` | Both transfers moved under `SECURITYADMIN` |
| 31 | **The publishing role then could not read its own staging table.** Its access came from OWNERSHIP, not a `SELECT` grant, so the moment ownership moved it lost the table entirely — *"Object 'P7_POC.D_STAGE.CUSTOMER_360' does not exist or not authorized"* — and the case's own inspection checks failed. `COPY CURRENT GRANTS` did not help: there was no `SELECT` grant to copy | Explicit `GRANT SELECT` back to `P7_PUBLISH_ROLE`, with a note that **this is part of the finding, not a workaround**: it is the ownership churn of the design's section 2.4 row 23 doing exactly what the design says — blocking the publishing role from its own domain |

---

## 4. The run, and what it found

**Executed end to end on 27 October 2026** against `pn56976-deloittena`, warehouse
`LM_PII_POC_WH`. Evidence in `../POC/_common/03_evidence/`.

| # | Measure | Result |
|---|---------|--------|
| 1 | Test cases | **50** |
| 2 | Passed | **33** |
| 3 | Failed | **2** — both genuine findings, below |
| 4 | Errored | **0** |
| 5 | Need a human reading | 12 — expectations that compare across captures, or need the second session |
| 6 | Not graded | 3 — cases that set up state a later case verifies |
| 7 | Statements executed | 1,674 captured across 11 files |

`00_setup.sql` ran clean, and its own pre-flight checks passed — including the one that matters most:
an unentitled role reads `***MASKED***` while an entitled one reads real values. Without that, nothing
after it would mean anything.

### The two failures are real results, not defects

| # | Case | What it found |
|---|------|---------------|
| 1 | `TC-04.3` *Does `COPY GRANTS` keep them?* — expected 2 tag rows, got **0** | **This is the design's central correctness finding, reproduced from a different direction.** `TC-04.2` does a *plain* `CREATE OR REPLACE`, which strips the tags. `TC-04.3` then rebuilds with `COPY TAGS` — and copies from the untagged table the previous case left, so the tags do not come back. The grants half of the case passes; the tags half cannot. This is exactly [`POC07_DESIGN.md`](../POC07_DESIGN.md) section 2.4 row 22 and test `T40`: **`COPY TAGS` takes its tags from the table it replaces, so once they are gone a rebuild cannot restore them.** The suite's own expectation assumed otherwise |
| 2 | `TC-04.5` *The grant bootstrap* — expected no `P7_` grants, got `P7_PUBLISH_ROLE` (ownership) and `P7_VIEW_OWNER` (`SELECT`) | **The premise is contradicted by the evidence.** The case asserts that on a first build there is nothing for `COPY GRANTS` to copy, so "grants must be deployed too". But the `SELECT` is there — supplied by the **future grant** in the reset block. So future grants *do* cover the day-1 bootstrap that `COPY GRANTS` alone cannot. That is direct evidence for the design's `D24` and `T41`, and it supports the design's section 10.1 row 3 choice of future grants over the `COPY GRANTS` route this suite relies on. Also, ownership is itself a grant, so "no `P7_` grants" can never be literally true |

---

## 4. Noted, not changed — these need a decision, not an edit

| # | Where | Point | Why it was left |
|---|-------|-------|-----------------|
| 11 | `s03` `TC-03.1` | Publishes unprotected PII four times with **no security check at all**, logging each as `PUBLISHED` | Intentional as a failure demonstration, and it is the clearest proof of the both-schemas tag rule. But the scenario never shows the gate *catching* the alternating-tag problem — arguably the thing worth proving. Adding that check changes what the case is for, which is the author's call |
| 12 | All scenarios | **Running any scenario destroys the previous one's control-table evidence** (`TRUNCATE` in every reset), and there is no results table | A real process hazard. Fixing it properly means a results table every scenario writes to — a structural change across all 10 files. `s09` now has one for its own readings; the rest do not. **Until then, capture every scenario's output immediately, before running the next.** This is the single biggest risk to the evidence |

---

## 5. What the suite still does not cover

From the design's 42 tests, 20 have no counterpart here (test design §10.11). Two of those are the
**must-pass** findings of the v12 validation, and neither is testable in this suite as it stands:

| # | Test | Why it matters | Why it is absent |
|---|------|----------------|------------------|
| 1 | `T32` — tags follow the **name**, not the data | Describes a way to publish unmasked sensitive data with every check green: change what a view's output column *contains* without changing its name, and the tag stays on the name while the value moves to an untagged column | `TC-03.3` renames a column, which is a different case. A name-preserving data move is not tested |
| 2 | `T31` — the restart clone guard | A restart re-cloning over already-rebuilt tables publishes day-old data as today's, with nothing failing | Cannot arise here: this suite has **no clone at all**. That is itself evidence for dropping the clone (`D11`) — the fault only exists because the clone does |

Also absent: no stored procedure, so no gate is actually *enforced* — nothing stops an operator
reading "2 rows returned" and swapping anyway, and the owner's-rights questions (`T11`, `T12`) cannot
be answered. Masking is one `STRING`-only policy keyed on `CURRENT_ROLE()`, not the proven three
typed policies keyed on `CURRENT_USER()`. There is no tag config table and so no mapping check.

---

## 6. Verification done on these files

| # | Check | Result |
|---|-------|--------|
| 1 | Comment blocks balanced (`/*` vs `*/`) in all 12 files | Pass |
| 2 | UTF-8 integrity — no double-encoding, no BOM introduced, em-dashes intact | Pass, all 12 files |
| 3 | Header batch ranges match the batch ids each file uses | Pass, after the fixes in row 10 |
| 4 | `FOR … IN 1 TO n DO`, `CALL SYSTEM$WAIT(n)` and `:i` binds inside an anonymous block | **Executed against the account** — all work |
| 5 | `COUNT_IF` and the verdict query shape | **Executed against the account** — correct |
| 6 | `SHOW PARAMETERS LIKE 'READ_CONSISTENCY_MODE' IN ACCOUNT` output columns (`key`, `value`, `default`) | **Verified.** Account is on `SESSION`, the default, set at no level |
| 7 | `SHOW GRANTS TO ROLE` output columns (`privilege`, `granted_on`, `name`, `grantee_name`) | **Verified** against a real role |
| 8 | Full compilation of the suite | **Not possible** — every statement references `P7_POC`, which does not exist yet. The SQL is reviewed, not compiled |

**`00_setup.sql` has not been run, so no POC07 object exists on the account.** Before running
anything, note that this suite creates a database `P7_POC` and seven `P7_*` roles.
