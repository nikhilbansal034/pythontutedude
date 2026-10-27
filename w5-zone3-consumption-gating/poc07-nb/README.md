# POC07 (NB) — CTAS + Swap test scripts

The **NB_ copy** of the pack, for running in parallel with a colleague on the same account.
Identical in substance to [`../poc07/`](../poc07/) — same ten scenarios, same 48 test cases, same
[tracker](../POC07_CTAS_Swap_Test_Tracker.xlsx). Only the names and the home differ.

**Nothing here has been executed.** The P7_ pack's `00_setup.sql` has been run; this one has not.

## How it avoids colliding with the other run

| | `../poc07/` (P7_) | this pack (NB_) |
|---|---|---|
| Database | `P7_POC`, created by the script | `LM_POC_DB`, **already exists and is shared** |
| Warehouse | `COMPUTE_WH` | `POC_WH` |
| Schemas | `GOV`, `BASE`, `D_LIVE`… | `NB_GOV`, `NB_BASE`, `NB_D_LIVE`… |
| Roles | `P7_BASE_OWNER`… | `NB_BASE_OWNER`… |

Nothing is shared but the warehouse, so the two runs cannot see or overwrite each other's objects.

**The tracker is deliberately not forked.** `POC07_CTAS_Swap_Test_Tracker.xlsx` names schemas
logically — `D_LIVE`, `D_STAGE`, `D_VIEWS`, `CTRL` — so one copy serves both runs and the two sets
of evidence stay directly comparable. Read `D_LIVE` as `NB_D_LIVE` and so on when you fill in your
tabs.

**`LM_POC_DB` is shared.** It holds your colleague's `GOLD_POC`, `GOLD_STG_POC`, `GOLD_BUILD_POC`,
`GOVERNANCE_POC`, `SILVER_POC` and `POC_SCHEMA`. This pack never creates or drops the database,
never creates or drops the warehouse, and never touches a schema that does not start `NB_`.
`99_teardown.sql` drops our **seven schemas by name**, not the database — do not "simplify" it to
`DROP DATABASE`.

Because `LM_POC_DB` and `POC_WH` are not ours, every grant on them is issued by `SECURITYADMIN`
(which holds `MANAGE GRANTS` and can grant on objects it does not own) rather than `SYSADMIN`, which
almost certainly does not own them.

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

1. **Check the warehouse.** Line 1 of `00_setup.sql`: `SET wh = 'POC_WH';` — change it only if you
   use a different one.
2. **Roles.** You must be able to `USE ROLE` both `SECURITYADMIN` and `SYSADMIN`. If your account
   restricts those, run `00_setup.sql` as `ACCOUNTADMIN` — nothing else changes.

   `SECURITYADMIN` is not optional. Two things in setup cannot be done by a schema owner, however
   much it owns: a `GRANT … ON FUTURE` (needs `MANAGE GRANTS`), and any grant on a schema whose
   ownership was just transferred (the transfer uses `REVOKE CURRENT GRANTS`, so the grants have to
   come afterwards, from a role that still can).

   If Snowsight offers a **"Resolve access error"** button on either, **do not click it** — it grants
   `MANAGE GRANTS` to the NB_ role, which is account-wide and undoes the least-privilege split the
   POC exists to test.
3. **Check the setup assertions at the end of `00_setup.sql` before running any scenario.** If
   assertion 6c returns real values for the unentitled role, the masking policy is not attached to
   the tag and every later result is meaningless.

## What is in the sandbox

All seven schemas live in `LM_POC_DB`.

| Schema | Holds | Owner | Swapped? |
|---|---|---|---|
| `NB_GOV` | tags, masking policy, entitlement table | `SYSADMIN` | no |
| `NB_BASE` | `CUSTOMER`, `POLICY` — what the ETL loads | `NB_BASE_OWNER` | no |
| `NB_SRC_VIEWS` | `V_CUSTOMER_360`, `V_POLICY_SUMMARY` | `NB_BASE_OWNER` | no |
| `NB_D_LIVE` | the published tables | `NB_PUBLISH_ROLE` | **yes** |
| `NB_D_STAGE` | where the next batch is built | `NB_PUBLISH_ROLE` | **yes** |
| `NB_D_VIEWS` | `V_CUSTOMER_360`, `V_POLICY_SUMMARY` — thin reader views | `NB_VIEW_OWNER` | no |
| `NB_CTRL` | the four control tables | `NB_PUBLISH_ROLE` | no |

Naming: **`V_CUSTOMER_360` builds `CUSTOMER_360`**, and the thin reader view keeps the `V_` name, so
reports change schema only.

| Role | What it is |
|---|---|
| `NB_BASE_OWNER` | owns the base tables and the source views |
| `NB_PUBLISH_ROLE` | builds and swaps. **Entitled** — it must be, or the CTAS writes masks |
| `NB_VIEW_OWNER` | owns the thin views. Deliberately **not** entitled |
| `NB_READER_OK` | an approved report user |
| `NB_READER_NO` | an unapproved report user |
| `NB_PROBE_ROLE` | grant target for S04 |
| `NB_BATCH_NOENT` | a batch identity with no entitlement — proves a writer stores masks |

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
| `s08` TC-08.3 | reader selecting from `NB_D_LIVE` / `NB_D_STAGE` | proves readers reach only `NB_D_VIEWS` |
| `s04` TC-04.5 | first build with `COPY GRANTS` on a dropped table | the grant bootstrap |

## Recording results

Each check is followed by an `/* EXPECT … */` or `/* RECORD … */` comment.

- **EXPECT** — compare and mark pass or fail.
- **RECORD** — write down what happened even if it surprises you. These exist to find out what
  Snowflake does, not to confirm what we expect.

`S01` and `S04` are marked **MUST REPORT** in the tracker: they produce deployment rules rather than
pass/fail lines, so their results go in the testing summary whatever the outcome.
