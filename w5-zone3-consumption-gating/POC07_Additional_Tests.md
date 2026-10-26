# POC07 — additional tests for the CTAS + Swap build

**Tests raised from the design walkthrough that are not covered by
[`POC07_Test_Design_CTAS_Swap 1.md`](<POC07_Test_Design_CTAS_Swap 1.md>) draft v2.**

| # | Field | Value |
|---|-------|-------|
| 1 | Status | **Draft, for review. Nothing built or run.** |
| 2 | Date | 26 October 2026 |
| 3 | Scope | CTAS + Swap, with `COPY TAGS` as the tag method and **no `TAG_CONFIG` table**. Section 1 tags · Section 2 grants · Section 3 the POC control tables · Section 4 exceptions and restart |
| 4 | Relationship to the main design | **Additive.** These tests slot into the existing groups; they do not replace or re-test anything in draft v2 |
| 5 | Why it exists | Draft v2 assumes a tag method that re-applies tags from a config table each batch. With `COPY TAGS` and no config table, tags enter the published tables by a different route — and there is a case where they do not enter at all. Section 2 re-validates the grant behaviour the design depends on, at the team's request |

---

## Section 1 — The tag bootstrap under `COPY TAGS`

### 1.1 The behaviour being tested

`COPY TAGS` copies tags **from the table it replaces** — not from the source view, and not from the
base tables. Snowflake's wording: *"tags from the replaced table and its columns are retained on the
new table."* It is a carry-forward mechanism, so it needs a predecessor at the same name.

Two consequences follow, neither of which draft v2 covers.

**a) The first build has nothing to copy from.**

```sql
CREATE OR REPLACE TABLE D_STAGE.CUSTOMER_360 COPY TAGS AS SELECT … FROM V_CUSTOMER_360;
```

On a freshly deployed staging schema there is no `D_STAGE.CUSTOMER_360` to replace. The statement
creates the table, copies nothing, and the sensitive columns carry **no tags** — therefore no
masking. No error is raised.

**b) It happens twice, because the two schemas alternate.**

`D_LIVE` and `D_STAGE` exchange identities at every swap, so each physical storage carries its own
independent tag lineage, refreshed every *other* batch:

```
deploy      LIVE→P   STAGE→Q      both empty
batch 1     build into Q   Q.X does not exist  →  UNTAGGED
  swap      LIVE→Q   STAGE→P
batch 2     build into P   P.X does not exist  →  UNTAGGED
  swap      LIVE→P   STAGE→Q
batch 3     build into Q   Q.X exists (batch 1) →  copies batch-1 tags
batch 4     build into P   P.X exists (batch 2) →  copies batch-2 tags
```

So the **first two batches** publish untagged tables, and from batch 3 the tags travel down two
separate chains.

**The proposed fix**, which these tests also validate: create the table in **both** schemas, with its
tags, before the first batch. Every subsequent `COPY TAGS` then has a tagged predecessor whichever
storage it lands on.

In the POC the tags are applied directly by the setup role. **How this is deployed in production —
Liquibase or otherwise — is out of POC scope** (§3); what the POC establishes is only *that it must
happen, in both schemas, before the first build.*

### 1.2 Why it matters beyond the first run

The same gap reopens **every time a reporting object is added** to the domain. A new published table
deployed to one schema only, or to neither, repeats the behaviour for its first batches — months
after go-live, when nobody is watching for it.

### 1.3 Tests

Roles and object names follow draft v2 §3.1 and §3.5. "Record" means the result is written to the
evidence pack whether or not it matches the expectation.

| # | Test | Pass / record | Sessions | Basis |
|---|------|---------------|----------|-------|
| **A1** | On a freshly deployed `D_STAGE` with no table at that name, run `CREATE OR REPLACE TABLE D_STAGE.X COPY TAGS AS SELECT … FROM <view>`. Read the new table's column tags with `TAG_REFERENCES_ALL_COLUMNS` | **Expected: zero tags.** Records that `COPY TAGS` carries nothing when there is no predecessor. If tags *do* appear, `COPY TAGS` reads from the source and the rest of this section is unnecessary — record that as the finding | Publish role | Docs — stated ("the replaced table") · Reasoning |
| **A2** | Continue to batch 2 — swap, then build into the **other** storage, which also has no table at that name. Read the tags again | **Expected: zero tags again.** Confirms the gap is not a one-off first-run event but recurs once more because the schemas alternate | Publish role | Reasoning |
| **A3** | Does the security check stop it? With the untagged table in staging from A1, run the pre-swap security check | **The check refuses the publish**, naming the unmasked column, and `D_LIVE` is unchanged. If it does not refuse, an untagged table can reach reports — raise immediately | Publish role + unapproved reader | Proven P2-T26 (the pre-switch check) |
| **A4** | **The fix.** Create the table in **both** `D_LIVE` and `D_STAGE` at deployment with its `PII` tags set, then run four batches | Every batch publishes with the tags intact, on both storages. The approved reader sees real values and the unapproved reader sees masked ones after every swap | Publish role + both readers | Proposal |
| **A5** | **The fix applied to one schema only.** Deploy a second table tagged in `D_LIVE` but **not** in `D_STAGE`. Run four batches | Records which batches publish it tagged and which do not. Expected: alternating — tagged on the batches that build into the live-seeded storage, untagged on the others. This is the failure mode to watch for when a new object is added after go-live | Publish role + unapproved reader | Reasoning |
| **A6** | Does `COPY TAGS` carry the **table-level** tag as well as column tags? Set `PII_SCOPE` on a staging table as an override, rebuild it with `COPY TAGS`, read the table's tags | Records whether the table-level scope survives the rebuild. It drives which approval rows apply, so losing it silently changes who sees real values | Publish role + approved reader | Docs — stated ("the replaced table **and its columns**"), to confirm on the account |

### 1.4 What each outcome means

| If | Then |
|----|------|
| A1 and A2 show untagged tables | Confirms the gap. The deployment step in A4 becomes **mandatory**, in both schemas, for every published table |
| A3 shows the check refuses | The safety net holds — an untagged table cannot reach reports, it just blocks the batch. Good, but the batch still cannot publish until the tags are deployed |
| A3 shows the check passes | **Escalate.** Sensitive data would publish unmasked with no error anywhere |
| A4 passes | The design is sound provided deployment sets tags in both schemas. This becomes a standing rule for adding any reporting object |
| A5 shows alternating tags | Confirms that tagging only `D_LIVE` is not enough, and gives the concrete evidence for the deployment rule |
| A6 shows the scope tag is lost | Any table-level scope override must also be re-applied, and the no-config design needs a step for it |

---

## Section 2 — Do grants really survive the swap, and the rebuild?

### 2.1 Why this is being re-validated

The design relies on *"a swap switches all access control privileges granted on the schemas and the
objects they contain"*, so the reader's access does not have to be re-granted after every publish.
That is documented and was proven on the account in POC02 — **it is re-validated here at the team's
request**, because it is load-bearing: if it does not hold, every publish silently removes the
reporting estate's access.

There is also a second mechanism in play that the swap does not cover. **`CREATE OR REPLACE TABLE`
replaces the object, so grants on the old table go with it.** The CTAS therefore destroys the table's
grants every batch, before the swap ever runs. Draft v2 handles this with *future grants on both
swapped schemas plus a grant on all existing tables* (test 18).

What draft v2 does **not** test is the obvious companion to the tag method already chosen:

```sql
CREATE OR REPLACE TABLE D_STAGE.X COPY GRANTS COPY TAGS AS SELECT … FROM <view>;
                                  └────┬────┘
                     carries the replaced table's privileges forward,
                     by the same mechanism COPY TAGS uses for tags
```

If `COPY GRANTS` works here, the future-grant machinery on both schemas becomes unnecessary and the
grant story collapses into the same one clause as tags. If it does not, the future-grant rule stands
and must be followed exactly. Either way it is worth one test, because the two options differ a lot
in how easy they are to get wrong.

**Note:** `COPY GRANTS` does **not** copy `OWNERSHIP`, and it has the **same bootstrap gap as
`COPY TAGS`** — no predecessor, nothing copied. B4 below is the grant equivalent of A1.

### 2.2 Tests

These do not duplicate draft v2 test 18, which already covers the future-grant rule over five
publishes and the wrong-way case. They cover what sits around it.

| # | Test | Pass / record | Sessions | Basis |
|---|------|---------------|----------|-------|
| **B1** | **Re-validate the swap itself.** Grant `SELECT` on a published table to the probe role. Record the grants. Swap. Record them again | The grant is still on the table under its new schema name, unchanged. Confirms the documented behaviour on the current account | Publish role + `SECURITYADMIN` | Docs — stated · Proven P2 (re-validated at the team's request) |
| **B2** | **Does the CTAS drop grants?** Grant `SELECT` to the probe role on `D_STAGE.X`, then rebuild `X` with a plain `CREATE OR REPLACE … AS SELECT` (no `COPY GRANTS`, future grants removed for this test). List the grants after | **Expected: the grant is gone.** Establishes directly that the rebuild, not the swap, is what loses grants — the reason the future-grant rule exists at all | Publish role + `SECURITYADMIN` | Docs — stated · Reasoning |
| **B3** | **`COPY GRANTS` as the alternative.** With no future grants in place, grant `SELECT` to the probe role, then rebuild with `CREATE OR REPLACE TABLE … COPY GRANTS COPY TAGS AS SELECT …`. Repeat over four batches and both storages | The grant survives every rebuild and every swap, with no future grants anywhere. If it does, the design can drop the two-schema future-grant rule | Publish role + `SECURITYADMIN` | Docs — stated, to confirm on the account |
| **B4** | **The grant bootstrap.** First build into an empty staging schema using `COPY GRANTS` | **Expected: no grants** — same gap as A1, for the same reason. Records whether the first build needs grants deployed as well as tags | Publish role | Reasoning |
| **B5** | **Ownership.** After a `COPY GRANTS` rebuild, record the table's owner | `COPY GRANTS` does not carry `OWNERSHIP`; records who owns the rebuilt table and whether the publishing role can still swap the schemas | Publish role | Docs — stated |
| **B6** | **Can the view owner read staging?** The view owner holds future `SELECT` on **both** swapped schemas, so it can read staging. Read a sensitive column in `D_STAGE` as the view owner, after the rebuild and before the swap | Records whether the view owner can read staging data. This is the same exposure as draft v2 test 11 approached from the grants side — and it is the direct cost of the future-grant rule, which `COPY GRANTS` (B3) would remove | View owner | Reasoning · relates to draft v2 test 11 |

### 2.3 What each outcome means

| If | Then |
|----|------|
| B1 holds | The swap's grant behaviour is confirmed on the current account. Nothing changes |
| B1 fails | **Stop.** Every publish silently removes reporting access, and the design needs a re-grant step after every swap |
| B2 shows grants dropped | Confirms the rebuild is the thing that loses them — the future-grant rule is doing real work and must be followed exactly, in both schemas |
| B3 passes | The design can use one clause for both tags and grants and drop the two-schema future-grant rule. **This would also close B6**, because staging would no longer need future grants for the view owner |
| B3 fails | The future-grant rule stands as draft v2 writes it, and B6's exposure is a cost of the design, not an oversight |
| B4 shows no grants | Grants must be deployed up front in both schemas, exactly like tags. The deployment rule from Section 1 widens to cover grants |

---

---

## Section 3 — Control tables for the POC

Draft v2 proposes nine control tables. That is a production control plane; this is what the POC
actually needs. Agreed with the team, 26 October 2026.

### 3.1 Conventions

| # | Convention | Note |
|---|------------|------|
| 1 | **A published table is built from the view of the same name prefixed `V_`** — `V_CUSTOMER_360` builds `CUSTOMER_360` | So the build source is derived, not stored. It holds only while one published table comes from exactly one view; the moment one needs two, `build_source` has to come back as a column |
| 2 | **Zone 2 objects are not tracked.** Dependencies are recorded against Zone 3 objects only | A Zone 3 object reporting `COMPLETED` already implies its Zone 2 sources landed. Revisit only if a view reads Zone 2 directly, skipping the Zone 3 layer |
| 3 | **No lock table.** The POC is run by hand, so two concurrent publishes cannot occur | A production build needs one |

### 3.2 Structure

```sql
-- DEFINITION — static, deployed once, one row per object
CREATE TABLE CTRL.OBJECT_REGISTRY (
    object_name     STRING,        -- CUSTOMER_360  (built from V_CUSTOMER_360)
    object_type     STRING,        -- SOURCE | PUBLISHED
    is_required     STRING DEFAULT 'Y',   -- does its failure block the publish?
    live_schema     STRING,        -- D_LIVE
    stage_schema    STRING         -- D_STAGE
);

-- DEFINITION — the dependency edge list
CREATE TABLE CTRL.OBJECT_DEPENDENCY (
    object_name       STRING,
    depends_on_object STRING       -- Zone 3 objects only
);

-- STATE — one row per object per batch. Covers BOTH source loads and rebuilds
CREATE TABLE CTRL.BATCH_STATUS (
    batch_id        STRING,
    object_name     STRING,
    status          STRING,        -- COMPLETED | FAILED | PENDING
    status_at       TIMESTAMP_NTZ,
    exception_flag  STRING DEFAULT 'N',
    approved_by     STRING,
    approved_at     TIMESTAMP_NTZ,
    reason          STRING
);

-- EVIDENCE — one row per publish attempt
CREATE TABLE CTRL.PUBLISH_LOG (
    batch_id        STRING,
    attempted_at    TIMESTAMP_NTZ,
    outcome         STRING,        -- PUBLISHED | REFUSED
    refused_reason  STRING,
    exceptions_used STRING,
    run_by          STRING
);
```

`BATCH_STATUS` carries rows of both types: `SOURCE` rows say whether a Zone 3 load finished, and
`PUBLISHED` rows say whether a CTAS rebuild finished. The second kind is what makes restart possible
(Section 4).

### 3.3 The dependency gate, in one query

```sql
-- Can batch :B publish?  Any row returned = no.
SELECT r.object_name       AS published_table,
       d.depends_on_object AS blocked_by,
       s.status
FROM      CTRL.OBJECT_REGISTRY   r
JOIN      CTRL.OBJECT_DEPENDENCY d ON d.object_name = r.object_name
LEFT JOIN CTRL.BATCH_STATUS      s ON s.object_name = d.depends_on_object
                                  AND s.batch_id    = :B
WHERE r.object_type = 'PUBLISHED'
  AND r.is_required = 'Y'
  AND ( s.status IS NULL OR s.status <> 'COMPLETED' )
  AND NVL(s.exception_flag,'N') <> 'Y';
```

`s.status IS NULL` is deliberate: it catches a load that never reported at all, which is otherwise the
failure mode that passes silently.

### 3.4 One column worth adding to the data, not the control tables

Stamp `BATCH_ID` on every Zone 3 row and carry it through the views into every published table. Then
*"did the whole domain publish together?"* is one query against the reader views rather than an
inference from timestamps:

```sql
SELECT COUNT(DISTINCT batch_id) FROM (
    SELECT batch_id FROM D_VIEWS.V_CUSTOMER_360
    UNION ALL SELECT batch_id FROM D_VIEWS.V_PREMIUM_SUMMARY
);   -- must be 1
```

It is the cheapest piece of evidence in the pack.

---

## Section 4 — Exception lifecycle and restart

### 4.1 How the exception is reset — a choice to make explicitly

The team's requirement: once an exception has let a batch through, the next batch must not inherit
it. There are two ways to get there, and they fail differently.

| | **A — batch-scoped (recommended)** | **B — persistent flag, explicit reset** |
|---|---|---|
| Shape | `exception_flag` sits on a row keyed by `(object_name, batch_id)` | One row per object; the flag is reset to `'N'` after the publish |
| Reset | **Automatic.** Batch B6 inserts fresh rows defaulting to `'N'`; B5's `'Y'` stays as the audit record | A step at the end of the run sets it back |
| Failure mode | None — a new batch cannot see an old batch's flag | **If the run dies between the swap and the reset, the flag survives into the next batch** and silently excuses a genuine failure |
| Audit | The `'Y'`, approver and reason are preserved per batch | Overwritten each time it is reset |

The structure in §3.2 implements **A**, so no reset step is needed. The test below is still worth
running either way — under A it proves the keying works, under B it proves the reset step ran.

### 4.2 Fault injection for the restart tests

No `FAULT_SWITCH` table. To make one rebuild fail, rename its source view immediately before the run
and rename it back for the restart:

```sql
ALTER VIEW Z3_CONSUME.V_PREMIUM_SUMMARY RENAME TO V_PREMIUM_SUMMARY_BROKEN;  -- CTAS now fails
-- … run the publish, which refuses …
ALTER VIEW Z3_CONSUME.V_PREMIUM_SUMMARY_BROKEN RENAME TO V_PREMIUM_SUMMARY;  -- restart
```

No extra objects, and it produces a real failure rather than a simulated one.

### 4.3 Tests

| # | Test | Pass / record | Sessions | Basis |
|---|------|---------------|----------|-------|
| **C1** | A required dependency reports `FAILED` for batch B2. Publish | **Refused.** `PUBLISH_LOG` records the refusal and names the blocking object. Live still shows B1 | Publish role | Design |
| **C2** | Set `exception_flag = 'Y'` for that object in B2, with approver and reason. Publish again | **Publishes.** `PUBLISH_LOG` records which exceptions were used, who approved and why | Approver + publish role | Design |
| **C3** | **The reset.** Run batch B3 with the same object `FAILED` again and **no new exception** | **Refused.** Confirms B2's exception did not carry into B3. *This is the test the team asked for* — under the batch-scoped design it should pass by construction | Publish role | Team request, 26 October 2026 |
| **C4** | **Restart, part 1.** Rename one source view so its CTAS fails. Run batch B4 | That table's `BATCH_STATUS` row is `FAILED`; the others are `COMPLETED`; **no swap**; live unchanged on B3; the refusal is logged | Publish role + reader | Design |
| **C5** | **Restart, part 2.** Rename the view back. Re-run batch B4 with the **same batch id** | Only the failed table is rebuilt — the already-`COMPLETED` tables are skipped, verified by their unchanged `status_at` — then the swap runs **once** and every published table shows `BATCH_ID = B4` | Publish role + reader | Design |
| **C6** | **Restart after a security failure.** Make one table fail the security check. Run, then restart with the same batch id | The failing table's status is cleared or set `FAILED` so the restart rebuilds it; the others are not rebuilt; the second run publishes | Publish role | Draft v2 §3.3 step 10 |
| **C7** | **A new batch id does not resume.** After the refused run in C4, re-run with batch id **B5** instead of B4 | Records what happens: everything rebuilds from scratch, and B4 is left permanently incomplete in `BATCH_STATUS`. Confirms the batch id is the restart key, and that the scheduler must reuse it on a retry | Publish role | Reasoning |

### 4.4 What each outcome means

| If | Then |
|----|------|
| C3 passes | The exception cannot leak between batches. No reset step is needed, and none should be added |
| C3 fails | The flag is not batch-scoped in practice. **Fix before anything else** — a stuck `'Y'` means a failed load publishes silently, forever |
| C5 shows all tables rebuilt | Restart is not selective; `BATCH_STATUS` is not being read, or not keyed as expected. Costly rather than wrong, but it defeats the point of restart |
| C7 shows a clean rebuild | Expected. It confirms the scheduler must pass the **same** batch id on a retry — which is an operational requirement, not a code one, and needs writing down |

---

## Section 5 — Reporting requirement

> **The results of Sections 1, 2 and 4 must appear in the testing summary whatever the outcome** —
> including if everything passes. It is not a pass/fail line item; it determines a **deployment rule** that has to
> be carried into the real build and into whatever process adds a reporting object later.
>
> The summary should state, in plain words: *whether a published table built with `COPY TAGS`
> carries its tags on the first build, what has to be deployed for it to do so, and in which schemas.*

The reason for naming this explicitly: the finding is easy to lose. If A4 passes, it is tempting to
record "tags work" and move on — which drops the precondition that made them work. Six months later a
new reporting object is added to one schema, publishes unmasked on alternate batches, and nothing in
the evidence pack explains why.

---

---

---

## Section 6 — Out of POC scope, but needed for the real build

| # | Item | Status |
|---|------|--------|
| 1 | **How tags (and possibly grants) get deployed to both schemas** — Liquibase or another route | **Out of POC scope**, confirmed 26 October 2026. The POC applies them directly with the setup role. What the POC does establish is that *something* must apply them, in **both** schemas, before an object's first build — and again for every reporting object added later. That needs an owner |

---

## Section 7 — Sources

| # | Source | Used for |
|---|--------|----------|
| 1 | [`POC07_Test_Design_CTAS_Swap 1.md`](<POC07_Test_Design_CTAS_Swap 1.md>) draft v2 — §3.1, §3.3, §3.5, §4.3 | Object names, roles, where these tests slot in |
| 2 | [`POC07 - Batch-Consistent Consumption Layer - Overview.html`](<POC07 - Batch-Consistent Consumption Layer - Overview.html>) — slide 7 | The three tag methods and what each does not cover |
| 3 | Snowflake, [`CREATE TABLE`](https://docs.snowflake.com/en/sql-reference/sql/create-table) — `COPY TAGS` usage notes | *"tags from the replaced table and its columns are retained on the new table"*; a renamed column loses its tag |
| 4 | Snowflake, [`CREATE TABLE … COPY TAGS` GA release note](https://docs.snowflake.com/en/release-notes/2026/other/2026-04-02-create-table-copy-tags-ga), 2 April 2026 | GA date; the documented example uses `AS SELECT` |
| 5 | Snowflake, [`TAG_REFERENCES_ALL_COLUMNS`](https://docs.snowflake.com/en/sql-reference/functions/tag_references_all_columns) | How the tests read back the tags |
| 5b | Snowflake, [`CREATE TABLE`](https://docs.snowflake.com/en/sql-reference/sql/create-table) — `COPY GRANTS` usage notes · [`ALTER SCHEMA … SWAP WITH`](https://docs.snowflake.com/en/sql-reference/sql/alter-schema) | Section 2: what `COPY GRANTS` carries and what it does not (`OWNERSHIP`); what the swap moves |
| 6 | Design walkthrough, 26 October 2026 | The alternation behaviour and the deployment fix |

---

*Last updated: 26 October 2026 — draft, for review.*
