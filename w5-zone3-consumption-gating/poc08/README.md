# POC08 — control-table-driven column tags

A separate, self-contained POC. It shares no object, no script and no result
with any earlier POC in this repository, and it reads and writes nothing that
an earlier POC created.

## The question

Can a control table be the single source of truth for which columns of a
published table carry which tag — so that when governance **adds**, **changes**
or **removes** a tag, the change propagates to the published table on the next
batch, with no hand-tagging and no pipeline change?

## Why it is worth asking

A build that copies tags forward from the table it replaces can add a tag and
change a tag, but it can never **remove** one: it keeps re-applying what it was
handed. It also comes out unprotected the first time it lands on a storage that
nobody has tagged yet — and because the two swap schemas exchange physical
storages at every swap, there are two such storages, each rebuilt every other
batch.

This design has neither property, for one reason: **the build inherits
nothing.** There is no `COPY TAGS`. Every build starts untagged and is tagged
from the control row, so a removal propagates for free.

## Files, in run order

| File | What it does |
|---|---|
| `00_setup.sql` | Creates 4 `P8_` roles and 6 `P8_` schemas, the tag, the masking policy, the control table and the Zone 3 source. Ends with three setup checks. Re-runnable. |
| `s0_day0_deployment.sql` | Day 0. Verifies the pipeline may start from a state where **no published table exists** and nothing was pre-tagged. TC-0.1 – TC-0.4. |
| `s1_day1_first_publish.sql` | Day 1. A first build with no predecessor of any kind ends up correctly protected. TC-1.1 – TC-1.5. |
| `s2_day2_governance_change.sql` | Day 2. One edit to the control row propagates an ADD, a CHANGE and a REMOVE — on the other storage, which nobody ever tagged. TC-2.1 – TC-2.5. |
| `s3_fail_closed.sql` | Five cases where **refusing is the pass condition**. TC-3.1 – TC-3.5. |
| `99_teardown.sql` | Drops the six `P8_` schemas by name and the four `P8_` roles. |
| `POC08_tag_control_table.md` | The design. |
| `POC08_Control_Table_Tags_Tracker.xlsx` | Scenarios, test cases, flow and the control row day by day. Fill in Status and Evidence as you run. |

Run each file top to bottom in one Snowsight worksheet, in the order above.

## What it uses, and what it cleans up

**Shared, and never created or dropped by this pack:**

- database `LM_POC_DB`
- warehouse `POC_WH`

**Created, all prefixed `P8_`:**

- roles `P8_BATCH`, `P8_GOV_ROLE`, `P8_READER_OK`, `P8_READER_NO`
- schemas `P8_GOV`, `P8_CTRL`, `P8_SRC`, `P8_STG`, `P8_LIVE`, `P8_VIEWS`

`99_teardown.sql` removes exactly that set. Because POC08 touches no object
from any earlier POC, **no other cleanup is needed** — nothing of yours is
borrowed, so nothing of yours is left in a changed state.

## Prerequisites

You need to be able to `USE ROLE` both **SECURITYADMIN** and **SYSADMIN**.

Every grant on `LM_POC_DB` and `POC_WH` is issued by SECURITYADMIN, which holds
`MANAGE GRANTS` and can therefore grant on objects it does not own. SYSADMIN
almost certainly does not own either, so issuing those grants as SYSADMIN would
fail on privileges.

**One account-level grant is needed**, and it is the only thing in the pack not
scoped to `LM_POC_DB`:

```sql
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE P8_GOV_ROLE;
```

Attaching a masking policy to a **tag** requires `APPLY MASKING POLICY` on the
account. **Owning the tag and owning the policy is not enough** — without this
grant, `ALTER TAG P8_PII SET MASKING POLICY P8_MASK FORCE` fails with
*"Your primary role P8_GOV_ROLE must have APPLY MASKING POLICY granted on
ACCOUNT"*.

SECURITYADMIN can normally issue it on the strength of `MANAGE GRANTS`. If your
account refuses it, run that one line as **ACCOUNTADMIN** and carry on —
nothing else in the pack needs that role.

This is worth carrying into the write-up rather than treating as plumbing:
whoever attaches policies to tags holds an **account-wide** privilege, so that
role is powerful and the grant is a decision. The pipeline does **not** need it
— `P8_BATCH` only *sets* tags, which needs `APPLY` on the tag alone.

## The control row

One row per published object. A person edits `column_tags`; nothing else
changes.

```json
{
  "EMAIL": { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "EMAIL" },
  "SSN":   { "tag": "LM_POC_DB.P8_GOV.P8_PII", "value": "SSN"   }
}
```

Two things about this shape are load-bearing:

- **The keys must be UPPERCASE.** Snowflake uppercases unquoted identifiers, and
  VARIANT keys are case-sensitive. A lowercase key matches no column, and that
  column publishes untagged — silently.
- **The tag is stored fully qualified**, `DB.schema.tag`. The generated
  `ALTER TABLE` uses the stored string as-is. The trade-off: promoting this row
  between environments whose database names differ means rewriting it. Storing
  `schema.tag` and prepending the database at run time would be portable, but
  it puts a piece of the tag's identity in the pipeline instead of in the
  declaration, which is the thing this design is trying to avoid.

## The pipeline must not be able to edit its own rulebook

`P8_BATCH` holds **`SELECT`, and only `SELECT`**, on the control table. This is
not tidiness. The gate validates the built table *against the control table*,
so write access to that table is the power to unprotect a column: empty the row
and the next batch publishes everything in the clear, with the gate passing
because the gate checks the same row. TC-3.5 tests that the pipeline cannot do
this.

## Known limits of this pack

- **One table, one tag, one policy.** Consistency groups spanning several tables
  are not covered.
- **Concurrency is out of scope.** Whether a reader can observe a partially
  swapped state is a publication-gating question, not a tagging one.
- **`P8_READER_NO` doubles as the gate's unentitled probe identity**, to keep
  the POC to four roles. That gives a report role standing read access to
  unpublished staging data. In production, use a dedicated probe identity.
- **Grants are not in the control table.** Only tags are. `COPY GRANTS` carries
  grants forward and has the same bootstrap gap tags would have had, which this
  POC does not address.
