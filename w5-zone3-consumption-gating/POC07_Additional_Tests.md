# POC07 — additional tests for the CTAS + Swap build

**Tests raised from the design walkthrough that are not covered by
[`POC07_Test_Design_CTAS_Swap 1.md`](<POC07_Test_Design_CTAS_Swap 1.md>) draft v2.**

| # | Field | Value |
|---|-------|-------|
| 1 | Status | **Draft, for review. Nothing built or run.** |
| 2 | Date | 26 October 2026 |
| 3 | Scope | CTAS + Swap, with `COPY TAGS` as the tag method and **no `TAG_CONFIG` table**. Section 1 covers tags, Section 2 grants |
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

## 2 — Reporting requirement

> **The results of Sections 1 and 2 must appear in the testing summary whatever the outcome** —
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

## 3 — Out of POC scope, but needed for the real build

| # | Item | Status |
|---|------|--------|
| 1 | **How tags (and possibly grants) get deployed to both schemas** — Liquibase or another route | **Out of POC scope**, confirmed 26 October 2026. The POC applies them directly with the setup role. What the POC does establish is that *something* must apply them, in **both** schemas, before an object's first build — and again for every reporting object added later. That needs an owner |

---

## 4 — Sources

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
