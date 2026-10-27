# POC08 — Column tags driven by a control table

**Status:** design and test plan. Nothing executed yet.
**Scope:** deliberately small. Three days, four scenarios, eighteen test cases.

---

## 1. The question this POC answers

> Does a published table carry **exactly** the protection its control row declares —
> on the first build, on every build after it, and after governance changes its mind?

Nothing else. Everything that is not that question is out of scope (§7).

---

## 2. The design

### 2.1 Objects

| Object | Role |
|---|---|
| `Z3_VIEW` | The existing consumption logic. Build-time source only |
| `STG` schema | Where each batch is built |
| `LIVE` schema | What reports read |
| `CTRL.OBJECT_TAGS` | **The control table. Source of truth for column tags** |
| `GOV` schema | Tags and the masking policies attached to them |
| `VIEWS.V_*` | Thin reader views over `LIVE`. Stable names, outside the swap |

### 2.2 The control table

```sql
CREATE TABLE CTRL.OBJECT_TAGS (
    object_name  STRING,          -- CUSTOMER_360
    column_tags  VARIANT,         -- see below
    updated_by   STRING,
    updated_at   TIMESTAMP_LTZ,
    reason       STRING
);
```

One row per published object. `column_tags` holds the column-to-tag map:

```json
{
  "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL" },
  "SSN":   { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "SSN"   }
}
```

**Keys are UPPERCASE.** Snowflake uppercases unquoted identifiers but VARIANT keys are
case-sensitive, so a key of `email` silently matches no column and that column publishes
untagged.

**The tag is schema-qualified, not database-qualified.** The governance database is held
once, as a single configuration value, and prefixed at run time. A database name repeated
in every row would have to be rewritten on every promotion between environments, and a
half-finished rewrite leaves columns unprotected.

### 2.3 The pipeline, per batch

```
1. Read the control row for this object.            no row  ->  REFUSE
2. CREATE OR REPLACE TABLE STG.X COPY GRANTS
     AS SELECT * FROM Z3_VIEW;                      no COPY TAGS, no column list
3. For each column -> tag in the VARIANT:
     ALTER TABLE STG.X MODIFY COLUMN <col>
       SET TAG <gov_db>.GOV.<tag> = '<value>';
4. GATE
     dependency : every required object COMPLETED for this batch
     security   : every column in the control row IS tagged on STG.X
                  AND an unentitled role reads masked values from STG.X
5. ALTER SCHEMA STG SWAP WITH LIVE;
```

### 2.4 Why step 2 carries no tags forward

This is the whole design.

Because the rebuild inherits nothing, **every build starts from a tagless table** and step
3 applies exactly what the control row says. That makes all three governance operations
work without any special handling:

| Governance does | Result on the next batch |
|---|---|
| **Adds** a column tag | The column is tagged |
| **Changes** a tag value | The new value is applied |
| **Removes** a tag | The column is untagged |

Removal propagating for free is the point. A design that inherits yesterday's tags can add
and change, but can never remove — it keeps re-applying what it was given.

### 2.5 The storage model, and why Day 2 is its own scenario

`LIVE` and `STG` **exchange physical storage at every swap**. There are two storages — call
them **A** and **B** — and they take turns being `LIVE`.

```
Day 0   LIVE = A            STG = B
Day 1   build into B  -> swap ->   LIVE = B    STG = A
Day 2   build into A  -> swap ->   LIVE = A    STG = B
Day 3   build into B  -> swap ->   LIVE = B    STG = A
```

So **each storage is rebuilt every other batch**, and a behaviour proven on Day 1 has not
been proven for Day 2 — Day 2 lands on different physical storage. Day 2 is a separate
scenario for that reason alone.

---

## 3. Scenario S0 — Day 0, deployment

What must exist before the first batch. **No published table is deployed** — that is the
claim being tested.

| # | Test case | Expected |
|---|---|---|
| **TC-0.1** | `LIVE` and `STG` both exist, and **neither contains the published table** | Two empty schemas. No placeholder, no pre-applied tags |
| **TC-0.2** | The control row exists for the object, with the expected VARIANT | One row. Keys uppercase |
| **TC-0.3** | Every tag named in the control row resolves in `GOV` | All resolve. A name that does not is a Day 0 failure, not a Day 1 one |
| **TC-0.4** | Masking is live: an unentitled role reads masked values from a tagged base column | `***MASKED***`. If this fails, nothing later means anything |

---

## 4. Scenario S1 — Day 1, the first publish

Build lands on **storage B**. There is no predecessor of any kind.

| # | Test case | Expected |
|---|---|---|
| **TC-1.1** | Run the CTAS. Read the tags on `STG.X` **before** step 3 | **Zero tags.** Confirms nothing is inherited |
| **TC-1.2** | Apply tags from the control row. Read them back | **Exactly** the columns the control row names, with the declared values. No more, no fewer |
| **TC-1.3** | Security gate — every column in the control row is tagged on `STG.X` | Pass |
| **TC-1.4** | Security gate — unentitled role reads `STG.X` | `***MASKED***` |
| **TC-1.5** | Swap. Read through the thin view as an entitled and an unentitled reader | One batch id. Entitled sees real values, unentitled sees masks |

**The result that matters:** a first build, with no placeholder and no predecessor, is
correctly protected.

---

## 5. Scenario S2 — Day 2, the other storage, after a governance change

Build lands on **storage A**, which has never been tagged by anybody.

Between Day 1 and Day 2, governance makes all three kinds of change in one edit to the
control row:

- **adds** `PHONE`
- **changes** the value on `EMAIL`
- **removes** `SSN`

| # | Test case | Expected |
|---|---|---|
| **TC-2.1** | Update the control row — add, change and remove in one statement | One row updated, with `updated_by` and `reason` populated |
| **TC-2.2** | Run the CTAS. Read the tags on `STG.X` **before** step 3 | **Zero tags**, on this storage too |
| **TC-2.3** | Apply tags. Read them back | `PHONE` **tagged** · `EMAIL` carries the **new** value · `SSN` **not tagged** |
| **TC-2.4** | Security gate | Pass. The gate asserts against the *current* control row, not Day 1's |
| **TC-2.5** | Swap. Read through the thin view as an unentitled reader | `PHONE` **masked** · `SSN` **now readable in the clear** |

**The two results that matter:** the second storage is correctly tagged although nobody
ever pre-tagged it, and **a removed tag actually disappears**.

---

## 6. Scenario S3 — the gate must fail closed

Each case must **refuse**. A refusal is the pass condition.

| # | Test case | Expected |
|---|---|---|
| **TC-3.1** | No control row for the object | Refuse **before** building. Never publish an undeclared object |
| **TC-3.2** | Control row names a tag that does not exist (`GOV.PIII`) | Refuse with a message naming the tag. Not a cryptic mid-build error |
| **TC-3.3** | Control row names a column the view does not return | Refuse. The declaration and the data have diverged |
| **TC-3.4** | The batch role's `APPLY` on the tag is revoked, then a batch is run | The tagging step fails, the gate catches it, nothing is published |
| **TC-3.5** | The batch role attempts `UPDATE` on `CTRL.OBJECT_TAGS` | **Denied.** See §8 |

---

## 7. Out of scope

Listed so the POC stays small, not because they do not matter.

- Concurrency, and what a reader sees during the swap itself
- More than one consistency group
- Row access policies
- Grants — `COPY GRANTS` is assumed to work and is not retested here
- Enforcing the gate in a stored procedure; the steps are run in order by hand
- Deployment tooling for the control table
- Volume, and realistic view complexity

---

## 8. The security surface this design creates

Worth stating plainly, because it is new.

**Write access to `CTRL.OBJECT_TAGS` is the power to unprotect a column.** Delete a row and
the next batch publishes that column in the clear — with no error, and with the gate
passing, because the gate checks *against that table*.

| Role | Access |
|---|---|
| Batch role | `SELECT` only. Plus `APPLY` on the tags it must set |
| Governance role | `INSERT`, `UPDATE`, `DELETE` |

`updated_by`, `updated_at` and `reason` are not decoration. This table now needs the same
change control as any other governance object.

---

## 9. What "complete" looks like

The POC is done when all eighteen cases have a recorded result and these four hold:

1. A **first build** is correctly tagged with no placeholder and no predecessor — TC-1.2
2. The **second storage** is correctly tagged although nobody pre-tagged it — TC-2.3
3. A **removed** tag disappears on the next batch — TC-2.3, TC-2.5
4. Every case in **S3 refuses** — nothing publishes undeclared or half-tagged
