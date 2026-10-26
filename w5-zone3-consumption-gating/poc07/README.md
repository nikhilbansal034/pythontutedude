# POC07 — CTAS + Swap test scripts

Runnable Snowflake SQL for the ten scenarios in
[`../POC07_CTAS_Swap_Test_Tracker.xlsx`](../POC07_CTAS_Swap_Test_Tracker.xlsx).

**Nothing here has been executed** — there is no Snowflake account in the session these were written
in. They are reviewed, not run.

## Order

```
00_setup.sql                 run ONCE. Database, schemas, roles, RBAC, tags,
                             masking, base tables, source views, control tables

s01_day1_first_publish.sql   ─┐
s02_steady_state.sql          │  run in any order. Each one resets the swap
s03_tags.sql                  │  pair, the reader views and the control tables
s04_grants.sql                │  back to day 1, so it can be run on its own
s05_dependency_gating.sql     │  and re-run as often as you like
s06_exception_approval.sql    │
s07_restart.sql               │
s08_masking.sql               │
s09_atomicity.sql             │  ← needs TWO sessions
s10_rollback.sql             ─┘

99_teardown.sql              run LAST, and only once the evidence is captured
```

## Before the first run

1. **Set the warehouse.** Line 1 of `00_setup.sql`: `SET wh = 'COMPUTE_WH';`
2. **Roles.** Created with `SECURITYADMIN`, objects with `SYSADMIN`. If your account restricts those,
   run `00_setup.sql` as `ACCOUNTADMIN` — nothing else changes.
3. **Check the setup assertions at the end of `00_setup.sql` before running any scenario.** If
   assertion 6c returns real values for the unentitled role, the masking policy is not attached to
   the tag and every later result is meaningless.

## What is in the sandbox

| Schema | Holds | Owner | Swapped? |
|---|---|---|---|
| `GOV` | tags, masking policy, entitlement table | `SYSADMIN` | no |
| `BASE` | `CUSTOMER`, `POLICY` — what the ETL loads | `P7_BASE_OWNER` | no |
| `SRC_VIEWS` | `V_CUSTOMER_360`, `V_POLICY_SUMMARY` | `P7_BASE_OWNER` | no |
| `D_LIVE` | the published tables | `P7_PUBLISH_ROLE` | **yes** |
| `D_STAGE` | where the next batch is built | `P7_PUBLISH_ROLE` | **yes** |
| `D_VIEWS` | `V_CUSTOMER_360`, `V_POLICY_SUMMARY` — thin reader views | `P7_VIEW_OWNER` | no |
| `CTRL` | the four control tables | `P7_PUBLISH_ROLE` | no |

Naming: **`V_CUSTOMER_360` builds `CUSTOMER_360`**, and the thin reader view keeps the `V_` name, so
reports change schema only.

| Role | What it is |
|---|---|
| `P7_BASE_OWNER` | owns the base tables and the source views |
| `P7_PUBLISH_ROLE` | builds and swaps. **Entitled** — it must be, or the CTAS writes masks |
| `P7_VIEW_OWNER` | owns the thin views. Deliberately **not** entitled |
| `P7_READER_OK` | an approved report user |
| `P7_READER_NO` | an unapproved report user |
| `P7_PROBE_ROLE` | grant target for S04 |
| `P7_BATCH_NOENT` | a batch identity with no entitlement — proves a writer stores masks |

## Two deliberate simplifications

Recorded so nobody reads more into the results than is there.

1. **Masking is decided by `CURRENT_ROLE()`**, not per user and not per attribute. That proves the
   mechanism — a tagged column masks for an unentitled role — without creating users and key pairs.
   Production keys on user, attribute and scope.
2. **The publish steps are plain SQL, not a stored procedure**, so every step and its result is
   visible as you go. Production wraps them in one owner's-rights procedure.

## Statements that are meant to fail

Three test cases deliberately run a statement that errors. **Run it, copy the error into the evidence
tab, and carry on** — the error is the result.

| Where | Statement | Why |
|---|---|---|
| `s07` TC-07.2 | CTAS from a renamed-away view | fault injection for the restart test |
| `s08` TC-08.3 | reader selecting from `D_LIVE` / `D_STAGE` | proves readers reach only `D_VIEWS` |
| `s04` TC-04.5 | first build with `COPY GRANTS` on a dropped table | the grant bootstrap |

## Recording results

Each check is followed by an `/* EXPECT … */` or `/* RECORD … */` comment.

- **EXPECT** — compare and mark pass or fail.
- **RECORD** — write down what happened even if it surprises you. These exist to find out what
  Snowflake does, not to confirm what we expect.

`S01` and `S04` are marked **MUST REPORT** in the tracker: they produce deployment rules rather than
pass/fail lines, so their results go in the testing summary whatever the outcome.
