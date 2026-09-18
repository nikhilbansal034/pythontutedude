# Dev Aurora DB connection issue — analysis

| # | Field | Value |
|---|-------|-------|
| 1 | Database | `grsdiai-hydration-aurora-postgress-db-development-i2` (Aurora PostgreSQL, Dev) |
| 2 | Sources | Ref **A** — email thread "URGENT: Alignment Required – Dev Aurora DB Connection Issue". Ref **B** — Informatica ↔ Aurora discussion summary. See `01_Sources/SOURCE_TRACKING.md` |
| 3 | Analysis date | 2026-09-17 (A), updated 2026-09-17 (B) |
| 4 | Impact (per thread) | Blocks TD and MVP team unit testing; delays SIT; Helix deliverables impacted |
| 5 | Status | Open — waiting on the connection breakdown (6.1) and the Informatica pool settings review (2.2, fix 7.8) |

---

## 1. The short version

| # | Point |
|---|-------|
| 1 | The 10-minute idle timeouts cut connections from about 4,490 to about 2,750. **CPU did not move — it stayed at 99.6–99.7% for the whole 3 hours shown.** The timeout fixed leftover idle connections, not the CPU problem. |
| 2 | The connections that come back after a reboot are not "zombies". A reboot ends every session, so everything after it is a **new** connection that something is actively opening. |
| 3 | The fix is to find **who** opens the connections and **what** is burning CPU. Both can be answered today with one SQL query and the free tier of CloudWatch Database Insights — no need to wait for Datadog. |
| 4 | Informatica should not kill database process IDs. Let database-side timeouts do that job. The team agreed (source B). |
| 5 | All IDMC taskflows use **one shared Aurora user** (source B). So the user name cannot tell taskflows apart — tracing needs the client machine, the port, or a process ID logged by the taskflow itself (6.2). |
| 6 | An Aurora-side idle timeout ends a reusable idle connection just as an Informatica-side kill would. Its real advantage is safety — it cannot end the wrong session. **Check Informatica's pool settings before relying on it**, or taskflows may pick up connections Aurora has already closed (7.4). |

---

## 2. What the sources say

### 2.1 Email thread (source A)

Timestamps are printed in mixed time zones in the PDF. The order below follows the thread, not the clock.

| # | From | Message |
|---|------|---------|
| 1 | Gayatri Pendem | Scheduled an urgent call (9/16, 8:30–9:00 PM IST) — Dev Aurora connectivity is blocking build, unit testing and delivery timelines |
| 2 | Nidwika Vedanaparthi | The call did not happen. Asked Praveen for a time and Shilpa to reprioritise if needed. Blocker for TD and MVP unit testing; SIT and Helix impacted |
| 3 | Praveen Jami Kumar | Technical assessment — see table below |
| 4 | Nidwika Vedanaparthi | Thanked Praveen; asked two follow-up questions — see section 6 |

Praveen's assessment, as written:

| # | Type | Item |
|---|------|------|
| 1 | Finding | CPU pinned at 100% by a very large number of active connections; new connections blocked |
| 2 | Finding | No `idle_session_timeout` or `idle_in_transaction_session_timeout` was set |
| 3 | Finding | Datadog database monitoring not enabled for Dev / Non-Prod |
| 4 | Finding | After a reboot, 1,500–4,000 connections re-established within minutes |
| 5 | Action taken | Set both timeouts to 10 minutes (600000 ms) |
| 6 | Action taken | Rebooted the database after applying the timeouts |
| 7 | Ask of dev teams | Audit that frameworks close connections after commit / rollback |
| 8 | Ask of dev teams | Trace what opens 1,000–3,000 sessions within minutes of startup |
| 9 | Ask of dev teams | Identify which parallel batch jobs cause the surge |
| 10 | Next step | RDS Proxy (connection pooling) in front of the database, if required |
| 11 | Next step | Enable Datadog database monitoring for Dev and Non-Prod |

### 2.2 Informatica ↔ Aurora discussion (source B)

The summary does not state the discussion date.

| # | Type | Item |
|---|------|------|
| 1 | Fact | Multiple IDMC taskflows connect to Aurora with the **same database user** (Nidwika) |
| 2 | Fact | The Secure Agent can identify the user, but not which taskflow opened a given Aurora connection |
| 3 | Fact | Informatica workflows have internal identifiers, but mapping them to Aurora connections is not straightforward (Prateek) |
| 4 | Concern | An idle connection left by Task Flow A may be reused by Task Flow B or C. Killing it from Informatica would lose that reuse and could mean more connections |
| 5 | Recommendation | Do not build connection-killing logic in Informatica initially |
| 6 | Recommendation | Configure Aurora to end idle sessions after a set inactivity period |
| 7 | Recommendation | Review Informatica's connection "polling" / reuse settings before making changes. "Polling" is probably a transcription of "pooling" — to confirm |
| 8 | Action — Prateek | Connect with Praveen Jami to investigate options |
| 9 | Action — Prateek | Research Aurora session handling and Informatica behaviour |
| 10 | Action — team | Validate Informatica connection pooling / reuse behaviour |
| 11 | Action — team | Gather logging to find out whether Aurora connections can be traced back to taskflows |
| 12 | Action — team | Treat an Aurora-side idle-session timeout as the preferred fix, pending further analysis |

How this changes the analysis: 6.1, 6.2, 7.3, 7.4, 7.8, and section 8 rows 6–9.

---

## 3. What the screenshots show

Both are CloudWatch, 3-hour window, 5-minute average, 9/16 20:00–22:55 local time. Values read off the graph, so approximate.

![CPU utilization](../01_Sources/_extracted/A_screenshot_1_CPUUtilization_2026-09-16.png)

![Database connections](../01_Sources/_extracted/A_screenshot_2_DatabaseConnections_2026-09-16.png)

| # | Metric | What it shows | What it means |
|---|--------|---------------|---------------|
| 1 | DatabaseConnections | About 4,490 at 20:00 → about 2,520 low at 21:20 → steady around 2,750 until 22:55 | Consistent with the idle timeout clearing idle connections. The thread does not say exactly when it was applied |
| 2 | CPUUtilization | Flat at 99.6–99.7% for the full 3 hours | Removing about 1,700 connections made **no** difference to CPU |
| 3 | The ~2,750 that stayed | Survived a 10-minute idle timeout | They are either running work, or being opened again as fast as they are closed |

**Why this matters.** The PostgreSQL docs say an idle session outside a transaction "imposes no large costs" on the server. AWS says idle connections still use *some* memory and CPU. Either way, the flat CPU line shows idle connections are not the main cause.

---

## 4. Why a reboot does not fix it

```
 Jobs / tools ──(1) open connections──▶ Aurora PG Dev
      ▲                                     │
      └──(3) reconnect within minutes ◀──(2) reboot / timeout ends sessions
```

| # | Arrow | What happens |
|---|-------|--------------|
| 1 | Open | Jobs, schedulers or connection pools open connections |
| 2 | End | A reboot or timeout closes them on the database side |
| 3 | Reconnect | The same callers open them again — retry loops, scheduled runs, or pools refilling to their minimum size |

Related limit: the default `max_connections` for Aurora PostgreSQL is `LEAST({DBInstanceClassMemory/9531392}, 5000)`. The 4,490 peak is close to that 5,000 ceiling, which would explain "new connections blocked". **The instance size has not been checked**, so the real cap for this instance is not known.

---

## 5. Likely causes and how to confirm each

| # | Likely cause | How to confirm |
|---|--------------|----------------|
| 1 | Too many jobs running at the same time, each opening many connections | Query 6.1 — group by client machine |
| 2 | Heavy queries using the CPU, not the connection count | Top SQL in CloudWatch Database Insights (fix 7.1) |
| 3 | Parallel reads / writes. In Spark (and so AWS Glue), the `numPartitions` setting is also the maximum number of connections per job | **Not confirmed** that any Glue / Spark job writes to this database. Check job settings |
| 4 | Informatica tasks not closing connections, or retrying in a loop | Map pids to taskflows (6.2) |
| 5 | Informatica connection pools set very large, or not actually reusing connections | Pool settings review (fix 7.8). Reuse at modest pool sizes would not produce 4,490 connections |

### 5.1 Context from sibling LM design folders

These come from our own notes, not from this thread. **Not confirmed** that they refer to this Dev instance — the instance name (`grsdiai-hydration-…`) makes it plausible.

| # | Note | Where | Why it may matter |
|---|------|-------|-------------------|
| 1 | Every IDMC taskflow has **four ABC subtaskflows** (before load, pre-load failure, success, failure) that write to **Aurora ABC control tables** | `IDMC Acclerator/MD/01_problem_brief.md` | Many parallel taskflows × several Aurora calls each could add up quickly |
| 2 | Taskflow input fields (batch IDs, execution run IDs) are looked up from Aurora | same file | Another Aurora read per taskflow |
| 3 | History Load's `input_config` table (one row per chunk) is held in **Aurora** in the latest version, and D-migrator instances run in parallel | `History Load/notes/HISTORY-LOAD-DESIGN-NOTES.md` | Parallel chunks each reading config could add load |

---

## 6. Answers to Nidwika's questions

### 6.1 Whose connections are they, and are they new?

**New or existing:** after a reboot, all of them are new — a reboot ends every session.

**Who owns them:** all IDMC taskflows share one user (source B), so grouping by user alone gives one big bucket. Group by client machine first.

```sql
SELECT client_addr, application_name, usename, state,
       count(*)                  AS conns,
       min(backend_start)        AS oldest,
       max(now() - state_change) AS longest_in_state
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3, 4
ORDER BY conns DESC;
```

| # | Column | Tells you |
|---|--------|-----------|
| 1 | `client_addr` | Which machine (e.g. a Secure Agent host) |
| 2 | `application_name` | Which tool, if it sets one |
| 3 | `usename` | Which database user — expect the shared IDMC user to dominate |
| 4 | `state` | `active` (running), `idle`, or `idle in transaction` |
| 5 | `oldest` | When the oldest connection in the group was opened — compare with the reboot time |

### 6.2 Which taskflow owns which pid?

| # | Method | Notes |
|---|--------|-------|
| 1 | **Match by client port.** On the database: `SELECT pid, client_addr, client_port, state, left(query, 100) FROM pg_stat_activity WHERE client_addr = '<secure-agent-ip>';` Then on the Secure Agent machine, find the OS process using that port: `ss -tnp` (Linux) or `netstat -ano` (Windows) | Works today, no config change. Finds the OS process — if that process pools connections for many taskflows, it will not narrow it to one taskflow |
| 2 | **Log the pid from inside the taskflow.** In the ABC "before load" step, write the run ID together with `pg_backend_pid()` and `now()` to a small log table. `pg_backend_pid()` returns the process ID of the database session the query runs on | Gives a direct pid → run ID link. With pooled connections one pid serves many taskflows over time, so read it as "last taskflow on this connection". Needs a log table and an ABC change |
| 3 | **Name each connection.** The PostgreSQL JDBC driver has an `ApplicationName` property that shows up in `pg_stat_activity.application_name` | **Not verified** that Informatica's PostgreSQL connector lets you set it — their docs page returned 403 |
| 4 | **Set the name per taskflow:** `SET application_name = '<run id>';` at taskflow start (printable ASCII, under 64 characters) | With pooled connections the name stays on the connection after the taskflow ends. Under RDS Proxy, a `SET` pins the connection |
| 5 | **Turn on `log_connections` and `log_disconnections`** in the parameter group | Logs every connect and disconnect with its source, and the session length — shows how fast connections are being opened and closed. **Not checked** whether Aurora needs a reboot for these |
| 6 | **One database user per team or pipeline**, so `usename` identifies the source | **Not in place today** — all taskflows share one user (source B). A change request. Would also enable per-user limits (fix 7.3) |
| 7 | **Informatica should not kill pids** — agreed in source B | Risk of ending another taskflow's session. Let database-side controls do it |

---

## 7. Possible fixes

| # | Fix | When | Suggested owner | Caveat |
|---|-----|------|-----------------|--------|
| 1 | Use **CloudWatch Database Insights, Standard mode** — the default, 7 days free, shows top contributors to DB load (SQL, users, hosts, waits) | Now | DBA / platform | Replaced Performance Insights (end of life 31 Jul 2026). **Not checked** whether it is on for this cluster |
| 2 | Limit how many jobs run at the same time in the scheduler while unit testing runs | Now | Ingestion / Informatica teams | Needs agreement across teams |
| 3 | Cap connections per user: `ALTER ROLE <etl_user> CONNECTION LIMIT n;` | After 6.2 row 6 | DBA | **Not useful today** — all IDMC taskflows share one user (source B), so a cap would throttle every taskflow together. Needs separate users first. The limit is approximate and never applies to superusers |
| 4 | Apply the idle timeout per user (`ALTER ROLE <user> SET idle_session_timeout = '10min';`) instead of for the whole database | Short term, after fix 8 | DBA | The PostgreSQL docs warn that connection pools "may not react well" to the database closing connections. Source B says Informatica reuses idle connections, so this applies directly: **the pool should drop idle connections before the database does**, or taskflows may pick up a connection Aurora already closed. Pool guidance (HikariCP) says a pool's limit should be several seconds shorter than any database-imposed limit. With one shared user, "per user" still separates IDMC from admin and monitoring users |
| 5 | RDS Proxy (AWS's managed connection pooler) in front of the database | Long term | DBA / platform | For PostgreSQL, `SET`, `PREPARE`/`EXECUTE`, temp tables, cursors and `nextval` "pin" a connection, which removes the pooling benefit. Watch `DatabaseConnectionsCurrentlySessionPinned`. **Does not reduce CPU if the queries themselves are heavy** |
| 6 | Datadog database monitoring | Long term | Platform | Needs `shared_preload_libraries = pg_stat_statements`, `track_activity_query_size = 4096` and a restart. The agent must connect straight to the instance, not through a proxy |
| 7 | Move to a bigger instance class — only if top SQL shows real load rather than waste | After fix 1 | Platform | Do this last, or you pay more for the same problem |
| 8 | **Review Informatica's connection pool settings** — maximum active, maximum idle, and idle eviction time — and compare with the 10-minute Aurora timeout | Now — before relying on fix 4 | Informatica team | Informatica Application Integration has a "Datasource Service" pool with these settings (seen in a docs search preview; the page itself returned 403). **Not verified** that LM taskflows' Aurora calls go through it |

---

## 8. Points to raise on the current plan

| # | Current plan | Point to raise |
|---|--------------|----------------|
| 1 | Idle timeouts as the fix (A) | The screenshots show connections fell but CPU did not. The CPU cause is still open |
| 2 | Reboot to clear connections (A) | The callers reconnect within minutes. Reboots only buy minutes |
| 3 | RDS Proxy as the next step (A) | Helps with connection count, not with heavy queries. Pinning may cancel the benefit |
| 4 | Wait for Datadog to get query-level detail (A) | Database Insights Standard mode gives top SQL, users and hosts now, at no cost for 7 days of data |
| 5 | Informatica to close connections by pid (A) | Agreed it should not (B). Map pids to taskflows for diagnosis only (6.2) |
| 6 | "Aurora-side timeout protects connection reuse" (B) | It ends idle pooled connections just as an Informatica-side kill would. Its real advantage is safety — it cannot end the wrong taskflow's session |
| 7 | "Reuse keeps the connection count down" (B) | Does not fit 4,490 connections at peak. Either reuse is not happening, or the pools are very large |
| 8 | Review pool settings, then decide (B) | Do it **before** relying on the 10-minute timeout, which is already live. A pool handing out connections Aurora already closed makes taskflows fail |
| 9 | Discussion scope (B) | CPU was not covered. The screenshots show CPU unchanged after connections fell — the idle-connection fix alone will not unblock testing |

---

## 9. Not verified yet

| # | Item | How to close it |
|---|------|-----------------|
| 1 | Instance class, and so the real `max_connections` | Check the RDS console or `SHOW max_connections;` |
| 2 | Whether any Glue / Spark jobs write to this database | Ask the ingestion team |
| 3 | Whether Informatica's PostgreSQL connector can set `ApplicationName` | Informatica docs / support |
| 4 | Exact time the timeout was applied, compared with the graph | Ask Praveen, or check RDS events |
| 5 | Whether Database Insights is enabled on this cluster | RDS console → Monitoring |
| 6 | Whether the Aurora in sibling design notes (5.1) is this instance | Ask the data integration team |
| 7 | Whether LM taskflows' Aurora calls (e.g. the ABC steps) go through an Informatica connection pool, and what its settings are | Informatica team / Secure Agent configuration |
| 8 | Whether each IDMC mapping task runs in its own process that ends when the task ends. If so, finished tasks cannot leave connections behind, and lingering idle ones must be held by a long-running pool | Informatica docs (page returned 403) / support |
| 9 | Whether "polling" in source B meant "pooling" | Confirm with Nidwika |
| 10 | Date of the source B discussion | Confirm |
| 11 | Whether turning on `log_connections` / `log_disconnections` needs a reboot on Aurora | AWS parameter group — check if the parameter is dynamic |

---

## 10. Sources

### External (checked 2026-09-17)

| # | Source | Used for |
|---|--------|----------|
| 1 | [PostgreSQL — client connection defaults](https://www.postgresql.org/docs/current/runtime-config-client.html) | `idle_session_timeout`, `idle_in_transaction_session_timeout`, pooler warning, idle cost |
| 2 | [PostgreSQL — pg_stat_activity](https://www.postgresql.org/docs/current/monitoring-stats.html) | Column meanings, `state` values |
| 3 | [PostgreSQL — CREATE ROLE](https://www.postgresql.org/docs/current/sql-createrole.html) | `CONNECTION LIMIT` behaviour |
| 4 | [PostgreSQL JDBC — connection properties](https://jdbc.postgresql.org/documentation/use/) | `ApplicationName` |
| 5 | [AWS — Aurora PostgreSQL performance and scaling](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.Managing.html) | `max_connections` default, idle connections use resources |
| 6 | [AWS — Avoiding pinning an RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy-pinning.html) | PostgreSQL pinning conditions |
| 7 | [AWS — CloudWatch Database Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Database-Insights.html) | Standard vs Advanced mode, Performance Insights end of life |
| 8 | [Apache Spark — JDBC data source](https://spark.apache.org/docs/latest/sql-data-sources-jdbc.html) | `numPartitions` = max concurrent JDBC connections |
| 9 | [Datadog — DBM setup for Aurora PostgreSQL](https://docs.datadoghq.com/database_monitoring/setup_postgres/aurora/) | Prerequisites |
| 10 | [PostgreSQL — system information functions](https://www.postgresql.org/docs/current/functions-info.html) | `pg_backend_pid()` |
| 11 | [PostgreSQL — error reporting and logging](https://www.postgresql.org/docs/current/runtime-config-logging.html) | `application_name`, `log_connections`, `log_disconnections` |
| 12 | [HikariCP](https://github.com/brettwooldridge/HikariCP) | Pool limit should be shorter than any database-imposed limit |
| 13 | [Informatica CAI — Datasource Service](https://docs.informatica.com/integration-cloud/cloud-application-integration/current-version/monitor/process-server-configuration/system-services/datasource-service.html) | Pool settings — **search preview only, page returned 403** |

### Internal

| # | Source | Used for |
|---|--------|----------|
| 1 | `01_Sources/A_Re_ URGENT_ Alignment Required – Dev Aurora DB Connection Issue.pdf` | The thread and both screenshots |
| 2 | `01_Sources/B_Informatica-Aurora_discussion_summary.md` | Shared user, reuse concern, discussion outcome and actions |
| 3 | `IDMC Acclerator/MD/01_problem_brief.md` | ABC subtaskflows and Aurora control tables (5.1) |
| 4 | `History Load/notes/HISTORY-LOAD-DESIGN-NOTES.md` | `input_config` in Aurora, parallel D-migrator (5.1) |
