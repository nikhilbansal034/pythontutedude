# POC07 evidence — batch-consistent publishing via CTAS + Swap

**33 of 50 test cases passed** · 2 failed · 0 errored · 12 need a human reading.

Generated 2026-10-27 07:11 UTC · account pn56976-deloittena · warehouse LM_PII_POC_WH.

| # | Case | What it proves | Verdict | Design test |
|---|------|----------------|---------|-------------|
| 1 | `TC-01.1` | First build into an untagged staging schema | **PASS** | T1, T28 |
| 2 | `TC-01.2` | The security check must refuse it | **PASS** | T1, T3 |
| 3 | `TC-01.3` | The fix — tag the table in BOTH schemas, then rebuild | **PASS** | T37 |
| 4 | `TC-01.4` | Security check now passes — publish | **PASS** | T1 |
| 5 | `TC-01.5` | Batch B2 builds into the OTHER storage | **PASS** | T37, T20 |
| 6 | `TC-01.6` | Every published table shows B2 | **PASS** | T20 |
| 7 | `TC-02.1` | Publish batch B1 | **PASS** | T38 |
| 8 | `TC-02.2` | Publish batch B2 | **PASS** | T38 |
| 9 | `TC-02.3` | Publish batch B3 | **PASS** | T38 |
| 10 | `TC-02.4` | Publish batch B4 | **PASS** | T38 |
| 11 | `TC-02.5` | Compare the four snapshots | **REVIEW** | T38 |
| 12 | `TC-03.1` | Seed one schema only, then run four batches | **REVIEW** | T37 |
| 13 | `TC-03.2` | Does COPY TAGS carry a TABLE-level tag? | **PASS** | T1, T3 |
| 14 | `TC-03.3` | A renamed column loses its tag | **REVIEW** | T2 |
| 15 | `TC-03.4` | A newly tagged base column arrives UNTAGGED | **PASS** | T16 |
| 16 | `TC-04.1` | Re-validate: does the swap carry grants? | **PASS** | T15 |
| 17 | `TC-04.2` | Does a plain CTAS drop the grants? | **PASS** | T41 |
| 18 | `TC-04.3` | Does COPY GRANTS keep them? | **FAIL** | T41 |
| 19 | `TC-04.4` | Stable across a further batch and the other storage | **REVIEW** | T41, T15 |
| 20 | `TC-04.5` | The grant bootstrap | **FAIL** | T41 |
| 21 | `TC-04.6` | Who owns the rebuilt table? | **INFO** | T12 |
| 22 | `TC-04.7` | Can the view owner read staging? | **INFO** | T28 |
| 23 | `TC-05.1` | All dependencies COMPLETED — publishes | **PASS** | T10, T24 |
| 24 | `TC-05.2` | A required dependency FAILED — refused | **PASS** | T10 |
| 25 | `TC-05.3` | A dependency with NO status row at all — refused | **PASS** | T10 |
| 26 | `TC-05.3b` | The missing row cannot be exception-approved  (ADDED 27 Oct) | **PASS** | T10 |
| 27 | `TC-05.3c` | The fix — approvals in their own table  (ADDED 27 Oct) | **REVIEW** | T10, T26 |
| 28 | `TC-05.4` | A NON-required dependency FAILED — publishes | **PASS** | T10 |
| 29 | `TC-06.1` | Baseline — a clean publish | **PASS** | T10 |
| 30 | `TC-06.2` | A required dependency fails — refused | **PASS** | T10 |
| 31 | `TC-06.3` | The business approves an exception for THIS batch | **REVIEW** | T26 |
| 32 | `TC-06.4` | THE RESET TEST — the next batch must not inherit it | **REVIEW** | T27 |
| 33 | `TC-06.5` | Normal publishing resumes | **PASS** | T27 |
| 34 | `TC-07.1` | Baseline — a clean publish | **PASS** | T25 |
| 35 | `TC-07.2` | One rebuild fails — nothing is published | **REVIEW** | T25 |
| 36 | `TC-07.3` | Restart with the SAME batch id | **REVIEW** | T25, T31 |
| 37 | `TC-07.4` | Restart after a SECURITY failure | **PASS** | T30, T40 |
| 38 | `TC-07.5` | A retry with a NEW batch id does not resume | **PASS** | T42 |
| 39 | `TC-08.1` | The entitled reader sees real values | **PASS** | T7 |
| 40 | `TC-08.2` | The unentitled reader sees masked values | **PASS** | T7 |
| 41 | `TC-08.3` | Readers cannot reach the tables directly | **PASS** | T8 |
| 42 | `TC-08.4` | An unentitled batch identity writes MASKS to disk | **PASS** | T12 |
| 43 | `TC-08.5` | The entitled batch identity writes real values | **PASS** | T12 |
| 44 | `TC-09.1` | A reader holding a query open across the swap | **INFO** | T20 |
| 45 | `TC-09.2` | Repeat it | **REVIEW** | T20 |
| 46 | `TC-09.3` | A NEW statement immediately after the swap returns | **REVIEW** | T20, D7 |
| 47 | `TC-10.1` | Publish B1 | **PASS** | T39 |
| 48 | `TC-10.2` | Publish B2 | **PASS** | T39 |
| 49 | `TC-10.3` | A problem is found — roll back | **PASS** | T39 |
| 50 | `TC-10.4` | The next batch publishes normally | **REVIEW** | T39 |

## Failures and errors

### TC-04.3 — Does COPY GRANTS keep them? (FAIL)
- **sec-1 tags on D_STAGE.CUSTOMER_360** — 0 rows, expected 2

```sql
SELECT 'sec-1 tags on D_STAGE.CUSTOMER_360' AS check_name,
       column_name, tag_name, tag_value
FROM TABLE(P7_POC.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('P7_POC.D_STAGE.CUSTOMER_360','table'))
WHERE TAG_NAME = 'PII'   
ORDER BY column_name
```

### TC-04.5 — The grant bootstrap (FAIL)
- **TC-04.5 grants on a first build with COPY GRANTS** — 2 P7_ grants present: ['P7_PUBLISH_ROLE', 'P7_VIEW_OWNER']

```sql
SELECT 'TC-04.5 grants on a first build with COPY GRANTS' AS check_name,
       "privilege", "grantee_name", "granted_on"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "grantee_name" LIKE 'P7_%' ORDER BY "grantee_name","privilege"
```


## Cases needing a human reading

- `TC-02.5` Compare the four snapshots — compare against TC-02.1; cross-capture check
- `TC-03.1` Seed one schema only, then run four batches — no rule for this expectation: tags present on the batches that build into the storage seeded in RESET, and ABSENT on the others
- `TC-03.3` A renamed column loses its tag — compare row count against the preceding capture; no rule for this expectation: the renamed column (email_address) carries NO tag
- `TC-04.4` Stable across a further batch and the other storage — compare against the preceding capture; cross-capture check
- `TC-05.3c` The fix — approvals in their own table  (ADDED 27 Oct) — single row plus free text; read the grid
- `TC-06.3` The business approves an exception for THIS batch — multi-column pattern; read the grid; multi-row sequence; read the grid
- `TC-06.4` THE RESET TEST — the next batch must not inherit it — multi-row sequence; read the grid
- `TC-07.2` One rebuild fails — nothing is published — per-table status pattern; read the grid
- `TC-07.3` Restart with the SAME batch id — compare status_at against TC-07.2; single named row; read the grid
- `TC-09.2` Repeat it — needs the second session's reader loop
- `TC-09.3` A NEW statement immediately after the swap returns — needs the second session's reading
- `TC-10.4` The next batch publishes normally — multi-row sequence; read the grid

Full SQL and result grids are in the HTML deck.
