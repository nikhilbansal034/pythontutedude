# Dev Aurora saturation — causes, actions, and the long-term fix

Companion to `connection_analysis.md` (the source-by-source record) and
`../w2-abc-framework/reference.md` (how the framework actually works).

This document answers three questions:

1. **All the ways this failure can arise** on Aurora PostgreSQL — the full scenario space, not one theory
2. **What can actually be done** to resolve it — ordered by how fast it works
3. **What to build** so this does not recur as the project scales

Instance: `grsdiai-hydration-aurora-postgress-db-development-i2` (Aurora PostgreSQL, Dev).

**Confidence marking used throughout**: **[Confirmed]** = stated in the email thread or the ABC doc ·
**[Derived]** = arithmetic or logic from those facts · **[Hypothesis]** = plausible, needs a measurement ·
**[Unknown]** = cannot be assessed from available material.

---

## 0. First, a correction to how the evidence is being read

This matters before any scenario list, because it changes which theories stay alive.

`connection_analysis.md` §1 and §3 argue: connections fell ~4,490 → ~2,750, CPU stayed flat at
99.6–99.7%, therefore **idle connections are not the cause and the CPU problem is separate**.

**That inference is not safe.** CPU utilization is a *bounded, saturating* metric. Once demand exceeds
capacity the gauge clips at 100% and stops carrying information. If offered load is 3× capacity, removing 38%
of one contributor still reads 100%. A flat pinned line does not mean "no effect" — it means **"not enough
effect to get back under the ceiling."**

What the screenshots *do* support:

| Reading | Supported? |
|---|---|
| The idle timeout removed ~1,700 connections | **Yes** |
| That removal was insufficient to relieve saturation | **Yes** |
| Idle connections contribute nothing to CPU | **No — cannot be concluded from a clipped metric** |
| There is an additional CPU cause beyond connection count | **Plausible, but not proven by this graph** |

**To actually measure this you need an unbounded metric**, which CPU% is not:

- **`LoadAverageMinute`** (Enhanced Monitoring) — unbounded. Load average of 80 on 8 vCPUs tells you demand is
  10× capacity; CPU% can only ever say "100%".
- **`DBLoad` / Average Active Sessions** (CloudWatch Database Insights) — unbounded, and broken down by wait
  event, which names *what* the CPU is doing.

Neither requires a database login. **This is the single most important immediate correction**: the team
believes it is blind because it cannot log in to the database, but the two metrics that would actually
diagnose this are available from the AWS console with no DB session at all.

---

## Part 1 — Every way this failure can arise

Three independent groups. Real incidents are usually several at once, and the ones below are not mutually
exclusive.

- **Group A — demand side**: what is opening connections
- **Group B — cost side**: what is burning CPU
- **Group C — the trap**: why it does not recover on its own

### Group A — Demand side: why there are thousands of connections

#### A1. Structural fan-out of the ABC framework **[Derived — strongest single contributor]**

This is the scenario the ABC design document makes unavoidable, and it is currently understated in the
analysis doc (§5.1 says "four ABC subtaskflows"; the real figure is roughly double that).

Walking `../w2-abc-framework/reference.md` §11 phase by phase, **one job** touches Aurora at these points:

| Phase | Aurora operations |
|---|---|
| Job preload step 1 | read `job_metadata`; read latest `job_run_stats`; insert `job_run_stats` |
| Job preload step 2 | read `etl_data_ingestion_metadata`; **one Zone1 dependency lookup per source table**; insert `etl_data_ingestion_source_window` rows |
| Job preload step 3 | read `job_rule_assignment`; insert `job_rule_execution_log` rows |
| Job load | `etl_data_ingestion_source_window` dual-written to Aurora |
| Job post load step 2 | read `job_rule_assignment`; write `job_rule_error_detail` |
| Job post load step 3 | update `job_rule_execution_log` |
| Job post load step 4 | read `balance_reconciliation_metadata`; write `balance_reconciliation_stats` |
| Job post load step 5 | finalize `job_run_stats` |

That is **~8–10 discrete Aurora-touching steps per job**, each implemented as a separate IDMC mapping task or
sub-task-flow, plus batch preload and batch post load once per batch. Note also the **per-source-table
fan-out** in job preload: a target fed by 5 source tables performs 5 separate dependency lookups.

Structure: one job per target table · many jobs per batch · one batch per (source, domain, layer) · many
domains running concurrently.

**The arithmetic:**

```
connections ≈ concurrent_jobs × Aurora_steps_per_job × connections_per_mapping_task
            ≈ 100           × 9                     × 5
            ≈ 4,500
```

which lands on the observed 4,490 without invoking a leak at all. **[Derived]**

The uncomfortable implication: **a large share of these connections may be the framework working exactly as
designed.** That is a materially different diagnosis from Praveen's "massive connection leak in our
application deployment loops" **[Confirmed — email, 16 Sep]**, and it leads to different corrective actions.
`connections_per_mapping_task` is the one unmeasured term and the highest-value number to obtain.

#### A2. No shared pooling — per-domain component copies **[Confirmed — ABC doc §3]**

ABC doc §3 states that shared ABC components live in a common `DI Common` / `DA_Common > ABC` folder, and each
new domain **copies** (not references) them into its own domain folder, changing only the connection name.

Copies do not share a connection pool. This is a direct architectural answer to open item 7 in the analysis
doc ("whether LM taskflows' Aurora calls go through an Informatica connection pool") — per-domain copies argue
strongly *against* meaningful cross-domain reuse, and mean connection demand scales linearly with domain count
with no amortisation.

#### A3. Pool sizing and eviction misconfiguration **[Hypothesis]**

If each mapping task runs in its own process with its own pool, and each pool holds a minimum-idle set, then
total connections = processes × min-idle, held open regardless of activity. A large `maxActive`, or an idle
eviction time longer than Aurora's timeout, produces exactly the observed steady plateau. Analysis doc fix 7.8
already targets this; it remains unverified.

#### A4. Genuine connection leak **[Hypothesis — plausible, partially evidenced]**

Before 16 Sep there were **no idle timeouts of any kind** **[Confirmed — email]**. That means any connection
leaked by any failure path accumulated **without bound** since the last restart. Over days, that alone can
reach thousands.

ABC has explicit preload-failure and postload-failure components **[Confirmed — ABC doc §11]**, but those
handle *logical* failures. The framework itself documents abrupt interruptions it cannot handle: `job_error_stats`
fires retroactively when a previous run "was interrupted abruptly (e.g. a network drop) and got stuck at
`status = Started` without ever being marked `Failed`" **[Confirmed — ABC doc §4.2]**, and the doc concedes a
true infrastructure failure "cannot be captured here — there's no code path to log an error nobody's code ever
executed."

**Every one of those abrupt interruptions is a candidate leaked connection.** The framework's own error model
proves they occur.

#### A5. Reconnect storm / thundering herd **[Confirmed as observed behaviour]**

"After a reboot, 1,500–4,000 connections re-establish within minutes" **[Confirmed]** is the textbook
signature. On restart every client reconnects simultaneously; thousands of `fork()` calls hit the postmaster
at once. Documented behaviour is that a database can take longer to recover from the reconnection storm than
from the original restart.

Praveen's own suspicion — "identify if your team's application is aggressively trying to reconnect in a loop"
**[Confirmed — email, 17 Sep]** — is this scenario. Note that a retry loop is *caused* by the outage as much
as it causes it, which is why it appears in Group C as well.

#### A6. Unit-testing concurrency with no governor **[Confirmed context]**

The stated business context is that TD and MVP teams are doing unit testing **[Confirmed — Nidwika, 16 Sep]**.
UT means many developers triggering taskflows ad hoc, concurrently, with no coordination — on top of whatever
StoneBranch is running. Nothing in the ABC design caps total concurrent batches or jobs; the scheduler-level
prerequisite (ABC §10 Layer 2) gates *one batch against its own previous run*, not global concurrency.

#### A7. Non-ABC consumers **[Unknown — must be ruled out, not assumed]**

Praveen's escalation asks "which services, batch pipelines that need DB access were deployed or restarted
recently?" — an open question, not a settled one. Candidates: AWS Glue / Spark jobs (where Spark's
`numPartitions` is simultaneously the max concurrent JDBC connections per job), CI/CD test suites, BI or
reporting tools, monitoring agents, and developer GUI sessions (pgAdmin and DBeaver each open several
connections per window). **No evidence yet either way** — the analysis doc §9 item 2 correctly lists this
as unverified.

#### A8. Orphaned TCP sessions **[Hypothesis]**

When a Secure Agent process is killed or a host reboots without clean shutdown, the server side of the TCP
connection can persist until keepalive detects it. With default PostgreSQL `tcp_keepalives_idle` (2 hours),
the database keeps thousands of backends alive for sessions whose clients no longer exist. The 10-minute idle
timeout now mitigates this — which may be exactly what the 4,490 → 2,750 drop represents.

#### A9. Shared database — no blast-radius isolation **[Confirmed — ABC doc §2]**

All ABC control tables sit in **one shared "default" database**; a dedicated ABC-only Aurora database "was
still pending/under discussion, not yet stood up." So ABC control chatter, Zone1 traffic and business data
access all contend for the same connection slots and the same CPU. Any one of them can starve the others —
including starving the DBA out of the ability to log in and diagnose.

#### A10. Restart and rerun amplification **[Derived — ABC doc §12]**

ABC's Restart path re-triggers a whole batch task flow; Zone2 Rerun re-executes **even previously-successful
jobs** ("Unlike Restart, previously-successful jobs/tables ARE re-executed"). A batch that keeps failing and
being restarted re-runs its full job set each time, multiplying connection demand precisely when the database
is least able to serve it.

### Group B — Cost side: why CPU is pinned at 99.7%

Group A explains connection *count*. It does not by itself explain CPU. These do.

#### B1. Connection churn — the cost of creating connections **[Hypothesis — best explains the paradox]**

PostgreSQL forks a **new OS process** per connection. Establishment costs roughly **3–20 ms of CPU** (and
5–10 MB of memory) versus ~0.1–0.3 ms for a simple indexed SELECT. Connection setup is therefore **10–100×
more expensive than the query it exists to run.**

This is the scenario that best resolves the central puzzle. Praveen states these are **"Net new connections
which are continuously hitting the DB"** **[Confirmed — 17 Sep]**. That is a statement about **rate**, not
count. A steady count of 2,750 is entirely compatible with a churn rate of hundreds of connections per second
— connections opening and closing as fast as they are created.

**The 10-minute idle timeout reduced the standing count but did nothing to the churn rate. So CPU did not
move.** That single mechanism explains both graphs without needing a separate mystery CPU cause.

**The critical missing measurement is connections opened per second.** Nobody has it. `log_connections` /
`log_disconnections` produce it directly.

#### B2. Snapshot / ProcArray scanning — idle connections *do* cost CPU **[Hypothesis — version-dependent, high impact]**

This directly contradicts a claim in the analysis doc, and the contradiction matters.

Analysis doc §3 cites the PostgreSQL docs saying an idle session "imposes no large costs." **That guidance
does not hold at four-figure connection counts on pre-PostgreSQL-14 engines.** Before PG14, every transaction
called `GetSnapshotData()`, which scans the *entire* process array — including idle sessions. Published
benchmarks: pgbench on PostgreSQL 12 ran 33,457 TPS with one connection and no idle sessions, and **14,496 TPS
with 10,000 idle connections — a 57% loss, with CPU profiling showing roughly half of all time inside
`GetSnapshotData()`.**

PostgreSQL 14 largely fixed this (dense XID arrays, cached snapshots), roughly doubling throughput at high
idle counts — but overhead remains real.

**So: on a pre-14 engine, thousands of idle connections are a first-order CPU cause, not a footnote.** This
makes the engine version one of the most important unknowns in the entire investigation, and it is not
recorded anywhere in the current material.

#### B3. Process-scheduling thrash **[Derived]**

Working backwards from the `max_connections` formula `LEAST({DBInstanceClassMemory/9531392}, 5000)`: sustaining
4,490 connections requires roughly 43 GB of instance memory, implying something around an r6g.2xlarge
(8 vCPU / 64 GB) or larger — **unless `max_connections` was manually raised**, which would change the picture.
For calibration, an r6g.large defaults to 1,716.

If that sizing is right, 4,490 connections on 8 vCPUs is about **560 connections per vCPU**. Practitioner
guidance treats even 500:1 as pathological; healthy is closer to 5–10× vCPU count. At that ratio the OS
spends a large share of its time context-switching between runnable backends rather than executing queries —
CPU is consumed by scheduling overhead, not work.

**Caveat**: instance class is listed as unverified in the analysis doc §9 item 1 and remains so. The 560:1
figure is an inference from the connection ceiling, not a measured fact.

#### B4. Lock-manager and LWLock contention **[Hypothesis — strong architectural fit]**

ABC's write pattern is close to a worst case for this. **Every job writes to the same small set of control
tables** — `job_run_stats`, `batch_run_stats`, `job_rule_execution_log`, `balance_reconciliation_stats`.
Hundreds of concurrent jobs inserting into the same few small tables produces:

- **Relation extension locks** — concurrent inserts serialise on 8 KB page extension
- **`LWLock:buffer_content`** — the same hot pages contended by many backends
- **`LWLock:lock_manager`** — the lock manager is partitioned 16 ways; high concurrency exhausts fast-path
  locking and forces shared-memory locking, which contends even for read-only work

The important property: **LWLock contention presents as CPU burn (processes spinning), not as blocked
sessions.** A `pg_stat_activity` snapshot would show many `active` sessions and no obvious blocking — which is
consistent with what has been reported. Database Insights' wait-event breakdown names this immediately.

#### B5. Missing indexes on control tables **[Hypothesis — cheap to check, high payoff]**

ABC's access patterns are lookup-heavy in ways that punish missing indexes:

- `batch_id` resolved by a **four-column combination** (`source_name + domain_name + application_layer_name +
  target_zone`) **[Confirmed — ABC doc §4.1]**
- "fetch the batch's / job's **latest** run" — a `ORDER BY ... DESC LIMIT 1` pattern executed constantly
- `job_metadata` looked up by `job_name + batch_id`
- `etl_data_ingestion_metadata` looked up per source table

If these lack supporting indexes — common in a Dev environment populated by manual DML, which ABC doc §4.1
confirms is the case today — each becomes a sequential scan. Individually trivial on a small table;
catastrophic when thousands of concurrent backends each run several, against a `job_run_stats` table that
grows with every job of every run.

#### B6. Bloat and autovacuum starvation **[Hypothesis]**

ABC generates dead tuples deliberately and continuously:

- `job_rule_execution_log` rows are **deleted and reinserted fresh** on every Restart **[Confirmed — §4.2]**
- `etl_data_ingestion_source_window` partial rows are **deleted and reloaded** **[Confirmed — §4.2]**
- Snowflake temp tables are cleared per `job_id` each run; Aurora-side equivalents follow similar churn

High-churn small tables need aggressive vacuuming. At 99.7% CPU, **autovacuum is starved of the CPU it needs
to run**, so dead tuples accumulate, tables and indexes bloat, scans read more pages, CPU rises further, and
vacuum falls further behind. This is a self-reinforcing loop that outlives whatever started it — and it means
the database may not recover to a healthy baseline even after the connection storm stops.

#### B7. Heavy business queries **[Unknown]**

The conventional explanation, and still unexcluded: an unindexed join, a cartesian product, a mapping pushing
a large scan. Database Insights' top-SQL view answers this in minutes. Worth stating plainly: **nobody has yet
looked at what the database is actually executing.** Every theory here, including the framework-centric ones,
is inference in the absence of that one observation.

#### B8. Long-running and idle-in-transaction sessions **[Hypothesis]**

A session left `idle in transaction` holds its snapshot, which blocks vacuum from cleaning *any* rows newer
than it — feeding B6 directly. The 10-minute `idle_in_transaction_session_timeout` now caps this, but ten
minutes of blocked vacuum under this write volume is still substantial.

#### B9. Undersized Dev instance **[Unknown]**

Dev environments are routinely sized well below production while being asked to absorb production-shaped
parallelism during UT. If this instance is small, everything above arrives sooner and harder. Unverified.

#### B10. Failed connection attempts **[Hypothesis]**

Once `max_connections` is reached, rejected attempts still consume CPU — TCP accept, fork attempt,
authentication, SSL negotiation, then `FATAL: sorry, too many clients already`. A retry storm against a full
database burns real CPU **producing nothing but error messages**. This is the mechanism that keeps the
database pinned even after the useful work has stopped.

#### B11. Stale statistics after a version upgrade **[Unknown]**

AWS documents this as a common cause of post-upgrade CPU spikes: without a fresh `ANALYZE`, the planner
chooses bad plans across the board. Only relevant if an engine upgrade happened recently — worth one question
to rule in or out.

### Group C — Why it does not recover on its own

The reason this is an outage rather than a slowdown is that the failure modes feed each other:

```
     CPU saturated
          │
          ▼
  postmaster forks new backends slowly
          │
          ▼
  client connection attempts time out
          │
          ▼
  clients retry (A5) ──────────────┐
          │                        │
          ▼                        │
  more fork() attempts (B1, B10)   │
          │                        │
          ▼                        │
     more CPU burned ──────────────┘
          │
          ▼
  max_connections reached → admins locked out → cannot diagnose → cannot fix
```

Two consequences worth stating explicitly:

1. **A reboot cannot work.** It removes the connections but not their cause, and the reconnect storm
   re-saturates the instance within minutes — which is precisely what was observed **[Confirmed]**.
2. **The admin lockout is a symptom, not bad luck.** It is the predictable end state of any connection
   exhaustion, and it is why the emergency-access path in Part 2 is the first action rather than a footnote.

---

## Part 2 — What can be done

Ordered by how quickly it takes effect. Tier 0 is about regaining control and visibility; Tier 1 stops the
bleeding; Tier 2 is structural repair.

### Tier 0 — Regain access and visibility (today, no DB session required)

#### 0.1 — Diagnose without logging in

The premise of the 17 Sep escalation — "we are completely unable to log in to the database or run
administrative diagnostics to validate which specific queries or connections are causing the bottleneck"
**[Confirmed]** — is **only partly true**, and the part that is false is the useful part.

| Tool | Needs a DB login? | Gives you |
|---|---|---|
| **CloudWatch Database Insights** (Standard mode) | **No** | Top SQL, top waits, top hosts, top users; **`DBLoad` unbounded** |
| **Enhanced Monitoring** | **No** | OS process list, **`LoadAverageMinute` unbounded**, CPU breakdown |
| **CloudWatch metrics** | **No** | `DatabaseConnections`, CPU, IOPS, freeable memory |
| **RDS events / parameter groups** | **No** | Exact time the timeout was applied; current parameter values |

Database Insights Standard mode is the default and carries 7 days of data at no cost. It replaced Performance
Insights (end of life 31 Jul 2026). **This answers "what is burning the CPU" without a single database
session, and it is available right now.** It also removes the dependency on Datadog enablement that the
current plan treats as a prerequisite.

**This is the highest-value action in this entire document, and it can be done in the next ten minutes.**

#### 0.2 — Get an admin session through the reserved slots

Aurora reserves connection slots specifically for this situation:

- `superuser_reserved_connections` — default **3**
- `rds.rds_superuser_reserved_connections` — default **2**

Non-superuser connections are capped at `max_connections` minus both. **The master user holds `rds_superuser`
and can therefore connect when ordinary users cannot.** If the master user is also being refused, raising
`rds.rds_superuser_reserved_connections` in the parameter group creates more admin headroom.

Practical note: connect with a **short `connect_timeout`, one attempt at a time**. An admin retry loop makes
the problem it is trying to diagnose worse.

#### 0.3 — Stop the inflow

The fastest route to a usable database, and what Praveen has already asked for. In order of preference:

1. **Pause StoneBranch schedules** for Zone2 batches — removes scheduled demand
2. **Stop or suspend IDMC taskflows**, or stop the Secure Agent — removes ad-hoc and in-flight demand
3. **Temporarily restrict the security group** to block the Secure Agent subnet — blunt, but it lets the
   database drain and autovacuum catch up when nothing else works

Option 3 is a genuine emergency lever and is worth naming explicitly, because when a database is refusing all
logins, network-level isolation is sometimes the only remaining control.

#### 0.4 — Triage queries, once a session is available

```sql
-- Who is connected, from where, in what state
SELECT client_addr, application_name, usename, state,
       count(*)                  AS conns,
       min(backend_start)        AS oldest,
       max(now() - state_change) AS longest_in_state
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1,2,3,4
ORDER BY conns DESC;

-- What the active sessions are WAITING on — distinguishes B1/B3 from B4 from B7
SELECT wait_event_type, wait_event, state, count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1,2,3
ORDER BY count(*) DESC;

-- What has consumed the most CPU (requires pg_stat_statements)
SELECT calls, total_exec_time, mean_exec_time, rows, left(query,150)
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 25;
```

The second query is the one that discriminates between the Group B scenarios, and it is the one nobody has
run yet:

| Dominant wait event | Points to |
|---|---|
| `CPU` with short-lived sessions | B1 — connection churn |
| `LWLock:lock_manager`, `LWLock:buffer_content` | B4 — lock contention |
| `IO:DataFileRead` on small tables | B5 — missing indexes / seq scans |
| `Lock:extend` | B4 — concurrent inserts to the same table |
| A single query dominating `pg_stat_statements` | B7 — heavy query |

### Tier 1 — Stop the bleeding (this week)

#### 1.1 — Cap the ETL role's connections

```sql
ALTER ROLE <idmc_user> CONNECTION LIMIT 300;   -- pick n well below max_connections
```

**This directly contradicts the existing analysis doc**, which marks this fix "**Not useful today** — all IDMC
taskflows share one user, so a cap would throttle every taskflow together" (§7 fix 3). During an incident,
throttling every taskflow together is **exactly the desired behaviour**. The value of this control is that it
guarantees the database stays reachable no matter what the ETL layer does.

**The honest trade-off**: taskflows exceeding the cap fail immediately with a connection error rather than
queueing. It converts a **database-wide outage** into **individual job failures** — a strictly better failure
mode, but it will generate failures and the teams must expect them. It is an emergency brake, not a fix, and
it should be paired with 1.2 so the failures are bounded.

The change is dynamic — no restart needed — and it is reversible in one statement.

#### 1.2 — Put a ceiling on concurrency

Nothing in the current design limits total concurrent jobs. Two places to enforce it:

- **StoneBranch** — cap concurrent Zone2 batch task flows
- **IDMC taskflow concurrency settings** — a configurable ceiling exists at the platform level

This is the control that makes 1.1 unnecessary in steady state. Needs agreement across teams, which is why it
is listed as an action rather than a unilateral change.

#### 1.3 — Measure the churn rate

```
log_connections = on
log_disconnections = on
```

This yields the missing number: **connections opened per second**, and session durations. It is the
measurement that confirms or eliminates B1, which is currently the leading explanation for the flat CPU line.
Check whether these are dynamic parameters on your engine version before assuming no restart is needed
(analysis doc §9 item 11 flags this as unverified).

Log volume will be high under this load — enable it, capture a window, turn it back off.

#### 1.4 — Check the engine version, and treat it as a decision point

If the cluster is on **PostgreSQL 13 or earlier**, B2 is likely a major contributor and **an engine upgrade
is a genuine performance fix**, not just hygiene. If it is on 14+, B2 drops down the list and attention should
shift to B1 and B4. Either way this single fact re-ranks the whole investigation, and it costs one console
lookup.

#### 1.5 — Align the Informatica pool timeout with Aurora's

The 10-minute Aurora timeout is **already live**. If Informatica's pool holds connections idle longer than
that, it will hand taskflows connections Aurora has already closed, and jobs will fail with confusing errors.
Standard pool guidance (HikariCP and others) is that the pool's own idle limit must be **several seconds
shorter** than any database-imposed limit.

**Verify this now, not after the next failure.** This is the analysis doc's fix 7.8 and it is the one item on
this list where delay creates a *new* category of failure rather than merely prolonging the current one.

#### 1.6 — Index the control tables

Review and add indexes for the access patterns in B5 — particularly the four-column `batch_metadata` lookup,
`job_metadata` by `job_name + batch_id`, and the "latest run" patterns on `batch_run_stats` / `job_run_stats`.
Cheap, low-risk, and if B5 is a contributor the effect is immediate.

#### 1.7 — Stamp connections with their identity

ABC **already threads `execution_run_id` and `job_run_id` through every runtime table** (§5 — "the single
unifying key"). Setting `application_name` to that value at session start makes `pg_stat_activity` answer
"which taskflow owns this connection" directly:

```sql
SET application_name = '<execution_run_id>:<job_run_id>';
```

This closes the attribution problem the entire email thread is stuck on **[Confirmed — Nidwika and Praveen
both raise it]**, using identifiers the framework already computes. Two caveats: with pooled connections the
name persists after the taskflow ends (read it as "last taskflow on this connection"), and under RDS Proxy a
`SET` pins the connection — see 2.2.

#### 1.8 — Consider a temporary scale-up

Explicitly **not a fix** — but a larger instance buys enough headroom to get in, diagnose, and act. Worth
doing only if it unblocks investigation, and worth reversing once the real cause is addressed. Scaling up
before understanding the cause means paying more for the same problem.

### Tier 2 — Structural repair (weeks)

#### 2.1 — One database role per domain or pipeline

Currently all IDMC taskflows share one Aurora user **[Confirmed — source B]**. This single fact defeats
attribution, per-user limits, and per-team accountability simultaneously.

Separate roles deliver three things at once: `usename` identifies the source, `CONNECTION LIMIT` becomes a
**per-domain budget** so one domain cannot starve others, and per-user idle timeouts become possible. It
requires a change request, and it is the prerequisite for several other controls listed here.

#### 2.2 — A pooling layer, with the PostgreSQL caveats understood

**RDS Proxy or PgBouncer in transaction mode.** ABC's Aurora traffic is close to an ideal transaction-pooling
workload: short, discrete control-table reads and writes, no temp tables, no session state. The pinning
concerns in the analysis doc (§7 fix 5 — `SET`, `PREPARE`, temp tables, cursors, `nextval`) largely apply to
the **Snowflake-side PDO work, not the Aurora control writes**, so the fit is better than that entry suggests.

Two real risks to test before committing:

- **`DISCARD ALL` pins connections.** PostgreSQL client libraries that reset connection state between borrows
  by issuing `DISCARD` interfere with RDS Proxy's session-state management and **pin the connection on
  release**, destroying multiplexing. Many JDBC pools do exactly this. **If Informatica's PostgreSQL connector
  issues `DISCARD ALL`, RDS Proxy will deliver close to zero benefit.** This must be tested, not assumed.
- **RDS Proxy does not support session pinning filters for PostgreSQL**, so there is no configuration escape
  hatch if pinning occurs.
- Setting `application_name` via `SET` (1.7) also pins — pass it in the **startup message** instead, or use
  the proxy's initialization query.

Monitor `DatabaseConnectionsCurrentlySessionPinned`. If pinning is high, **PgBouncer gives more control** and
should be the fallback.

#### 2.3 — Separate the ABC control plane from everything else

ABC doc §2 records that a dedicated ABC-only Aurora database was "pending/under discussion, not yet stood up."
**Prioritise it.** Today ABC control chatter shares an instance with business data access, so either can
starve the other — and, as seen this week, starve the DBA out of diagnosing it. The two workloads also have
genuinely different profiles: the control plane is very many tiny transactions needing connection headroom;
the data plane is fewer, larger operations. They should be sized and tuned independently.

#### 2.4 — Enable Database Insights and Datadog properly

Database Insights first, because it is available immediately and free for 7 days of retention. Datadog as the
longer-term standard — noting its prerequisites: `shared_preload_libraries = pg_stat_statements`,
`track_activity_query_size = 4096`, a restart, and a direct instance connection rather than one through a
proxy.

---

## Part 3 — The long-term fix

### The actual scaling defect

Everything in Parts 1 and 2 treats symptoms. The structural problem is one sentence:

> **ABC's Aurora connection demand is O(concurrent jobs × Aurora steps per job), and the architecture bounds
> neither factor.**

- *Jobs* grow with every new table, domain and wave — and the framework's stated design goal is that "any job,
  in any wave/domain, should be able to plug into the framework" **[Confirmed — ABC doc §1]**
- *Steps per job* is fixed at ~8–10 by the phase design
- *Connections per step* is amplified by per-domain component copies that share no pool **[Confirmed — §3]**

So connection demand grows **linearly with project scope, with no amortisation**. Every control in Part 2
raises the ceiling. None changes the slope. **This will recur at a larger number.** The items below change the
slope.

They are ordered by leverage. L1 and L2 are the ones that matter most.

### L1 — Put a control-plane service between taskflows and Aurora

**The single highest-leverage change.**

Today every mapping task connects to Aurora directly, so connection count is a function of job count. Instead,
expose ABC's control-plane operations as an API. Taskflows call the service; the service owns a **small,
bounded connection pool**.

```
  Today:   5,000 taskflow steps ──────────────────────▶ 5,000 Aurora connections

  Target:  5,000 taskflow steps ──▶ ABC service ──────▶ 20–50 Aurora connections
                                    (bounded pool)
```

This **permanently decouples job count from connection count**. Aurora connection demand becomes a function of
the service's pool size — a number you choose — rather than an emergent property of how many teams happen to
be testing. It also gives you a single place to implement retry policy, backoff, circuit breaking, metrics and
audit, instead of relying on every copied component behaving correctly.

IDMC can consume REST services, so this is compatible with the existing taskflow model. The cost is real: a
new deployable component, its own availability requirement, and a migration path for existing domains. It is
justified only because the alternative is re-solving this problem at every scale increment.

### L2 — Collapse per-step chatter into stored procedures

**The biggest win achievable inside ABC with no new infrastructure**, and the one to do first if L1 is judged
too large.

Today job preload is three separate mapping tasks issuing ~6 statements, and job post load is five steps
issuing more. Replace each phase with **one Aurora function taking the whole payload and doing all its writes
in a single call and a single transaction**:

```
  Today:   job preload  = 3 mapping tasks,  ~6 round trips,  3+ connections
           job post load = 5 mapping tasks, ~8 round trips,  5+ connections

  Target:  job preload  = 1 call to abc_job_preload(...)     → 1 connection
           job post load = 1 call to abc_job_postload(...)   → 1 connection
```

**These are Aurora (PostgreSQL) procedures, not Snowflake ones.** The control tables are Aurora's; the
Snowflake-side ABC tables are transient copies used during job load and are not the connection problem.
Building this in Snowflake would leave Aurora connection pressure unchanged.

**The procedure is not itself the saving — collapsing several IDMC tasks into one is.** Each mapping task is
its own execution that acquires a connection, runs its statements and releases it. The procedure is what
makes the collapse practical; without a server-side home for the logic, the alternative is one very large
Informatica mapping, which may still take a connection per read/write transformation.

Two effects, the second larger:

1. **Fewer acquisitions** — three task invocations become one.
2. **Shorter hold time** — `concurrent connections = arrival rate × hold time`. Every statement is a round
   trip, and today the tasks are additionally separated by IDMC orchestration overhead, stretching the
   sequence across seconds. One `CALL` compresses it to milliseconds.

**Corrected figures** (an earlier draft said "5–8× fewer connections", which conflated two quantities):

| Measure | Today | With procedures | Reduction |
|---|---|---|---|
| Connection **acquisitions** per job | ~8 | ~3 | **~2.5–3×** |
| **Round trips** per job | ~15 | ~3 | **~5×** |

The ~5× applies to round trips and hence hold time; acquisitions fall by about 3×. (~3 rather than ~1 because
the `etl_data_ingestion_source_window` write happens mid-load.)

**This caps nothing.** 500 concurrent jobs still means 500 concurrent connections, just briefer and fewer.
L2 reduces the coefficient; only L1 imposes a ceiling.

**Concurrency is not a problem here.** PostgreSQL does not lock or serialise concurrent executions of the same
procedure — each call runs in its own backend with its own snapshot. Under MVCC, readers never block writers
and concurrent inserts of *different* rows do not conflict, which is overwhelmingly ABC's preload pattern.
Contention falls rather than rises, because locks are held for milliseconds instead of across a
multi-second task sequence. The real trade-off is a *wider* lock set held simultaneously within one
transaction, so **touch tables in a consistent order** to avoid deadlocks. Genuine contention points —
relation extension (`Lock:extend`, already B4 above) and same-row updates — exist today and are unaffected.

It also fixes a correctness problem that is currently latent: today a failure midway through job preload
leaves **partially written control state** across `job_run_stats`, `etl_data_ingestion_source_window` and
`job_rule_execution_log`, which is precisely why ABC needs the elaborate preload-failure and postload-failure
components described in §11. A single transaction per phase makes these writes atomic — the cleanup component
becomes largely unnecessary, and the "stuck at `status = Started`" case (§4.2) stops being reachable through
normal failure paths.

**And it gives us a place to close a race that exists today.** Batch preload reads the latest
`batch_run_stats` row, decides New vs Restart, and inserts. Two concurrent triggers for the same batch can
both read "Completed", both decide "New", and both insert — two parallel runs of one batch. Today only the
scheduler-level prerequisite prevents this, and §10 states that check is **skipped for Restart, Rerun,
Zone1-Rerun, History, Catchup and FTI**. Inside a procedure, `PERFORM pg_advisory_xact_lock(p_batch_id)`
serialises exactly the batches that must be serialised and nothing else. **Worth raising with the ABC team
independently of whether L2 is adopted.**

**Sizing caveat**: how much L2 wins depends on whether the Secure Agent already pools across task executions —
the measurement in open question 5. If it pools well, the acquisition saving shrinks, though the hold-time
saving survives. Measure before building.

### L3 — Make pooling a standard, not an incident response

Whatever the outcome of 2.2, the architectural principle should be that **no ABC component connects to Aurora
directly**. Either L1's service or a pooler is always in the path. This should be part of the domain
onboarding checklist, so newly copied components inherit it by default rather than by review.

### L4 — Treat connections as a budgeted resource

Publish a per-domain connection budget derived from the instance's real `max_connections`. Every new domain
onboarding consumes from it, enforced by `CONNECTION LIMIT` on that domain's role (2.1). When the budget is
exhausted, that triggers a capacity review — *before* an outage rather than during one.

Today connection consumption is an emergent property that nobody owns, which is the root reason nobody could
answer Praveen's "where are we hitting these connections from?"

### L5 — Build observability into the framework

ABC already computes the identifiers needed to trace every connection to its owner (§5). Make stamping them
onto the connection a **framework guarantee**, not a per-domain configuration choice:

- `application_name` carries `execution_run_id:job_run_id` (1.7)
- The ABC "before load" step logs `pg_backend_pid()` alongside the run ID
- Connection open/close counts become a framework-emitted metric

The email thread has burned days on "which taskflow owns this connection?" That question should be answerable
by a single query, permanently, and the framework is already three-quarters of the way there.

### L6 — Backoff and circuit breaking

Framework-level retry with **exponential backoff and jitter**, plus a circuit breaker that stops attempting
connections to a database that is refusing them. This is what prevents a transient failure from becoming the
self-sustaining storm in Group C, and it directly addresses Praveen's "aggressively trying to reconnect in a
loop." With L1 this lives in one place; without it, every copied component needs it.

### L7 — A retention and partitioning strategy for control tables

`job_run_stats`, `job_rule_execution_log` and `job_rule_error_detail` grow without bound — and
`job_rule_error_detail` is explicitly **permanent and append-only in both Aurora and Snowflake**
**[Confirmed — §4.2]**, at **one row per failing column per failing record**. A single bad source file can add
millions of rows.

As these tables grow, the "latest run" lookups in B5 degrade, and today's connection problem becomes
tomorrow's query problem. Partition by date, archive history to S3 or Snowflake, and set an explicit retention
policy. This is not urgent this week; it is certain within a year.

### L8 — Make Dev's capacity and its concurrency agree

Right now Dev absorbs production-shaped parallelism on Dev-shaped hardware, with every team sharing one
instance, during the period when unit testing makes load least predictable. Either size Dev for the
concurrency it must absorb, or cap concurrency to what Dev can serve — currently neither is true.

Worth evaluating: **per-team schemas or ephemeral databases**, so one team's unit testing cannot block
another's. That directly addresses the business impact in the thread — TD and MVP unit testing blocked, SIT
and Helix deliverables slipping **[Confirmed]**.

### L9 — Question whether every ABC write must be synchronous

Aurora should remain the system of record. But not every write needs to be on the critical path of a running
job. Notification dispatch, bulk `job_rule_error_detail` loading, and similar could move to an asynchronous or
queued path, cutting the connection-holding time of each job. Lower priority than L1/L2, and it should follow
them rather than precede them.

---

## Summary — what I would do, in order

| # | Action | When | Effort | Why it is here |
|---|---|---|---|---|
| 1 | Open **CloudWatch Database Insights** and Enhanced Monitoring; read top SQL, top waits, `LoadAverageMinute` | Now | Minutes | Ends the "we are blind" premise; needs no DB login |
| 2 | Connect as **master user** via reserved slots | Now | Minutes | Restores admin access |
| 3 | **Pause StoneBranch / IDMC** taskflows | Now | Minutes | Fastest route to a usable database |
| 4 | Run the **wait-event query** (0.4) | Now | Minutes | Discriminates between B1 / B4 / B5 / B7 |
| 5 | Check the **engine version** and **instance class** | Now | Minutes | Re-ranks the whole investigation |
| 6 | `ALTER ROLE … CONNECTION LIMIT` | Today | Low | Guarantees the DB stays reachable |
| 7 | Verify **Informatica pool idle timeout < 10 min** | Today | Low | Prevents a *new* failure mode from the live timeout |
| 8 | Enable `log_connections` / `log_disconnections` | Today | Low | Produces the missing churn-rate number |
| 9 | Cap **concurrency** in StoneBranch / IDMC | This week | Medium | Addresses A6 at source |
| 10 | Add **indexes** on ABC control tables | This week | Low | Cheap; immediate if B5 applies |
| 11 | `application_name` = `execution_run_id:job_run_id` | This week | Low | Permanently solves attribution |
| 12 | **Separate DB roles** per domain | Weeks | Medium | Enables budgets and attribution |
| 13 | **Pooler** (RDS Proxy / PgBouncer), `DISCARD ALL` tested first | Weeks | Medium | Raises the ceiling substantially |
| 14 | **Dedicated ABC Aurora** instance | Weeks | Medium | Blast-radius isolation |
| 15 | **Aurora stored procedures per phase** (L2) | Quarter | Medium | ~3× fewer connection acquisitions, ~5× fewer round trips per job |
| 16 | **ABC control-plane service** (L1) | Quarter+ | High | Changes the slope, not the ceiling |

Items 1–5 cost almost nothing and are the only ones that produce **evidence**. Everything after them is better
decided once that evidence exists.

---

## Open questions

Answers to these would materially change the recommendations above.

| # | Question | Why it matters |
|---|---|---|
| 1 | **Aurora PostgreSQL engine version?** | Pre-14 makes B2 a primary cause and an upgrade a real fix |
| 2 | **Instance class**, and is `max_connections` default or manually raised? | Sets the true ceiling and the connections-per-vCPU ratio (B3) |
| 3 | **Connections opened per second** (not count) | Confirms or eliminates B1, the leading explanation for the flat CPU line |
| 4 | **Top wait events** from Database Insights | Discriminates between every Group B scenario in one screen |
| 5 | **Connections per IDMC mapping task** | The one unmeasured term in the A1 arithmetic. Settle it empirically: run **one** job on a quiet instance with `log_connections` on and count. ~8 confirms per-task connections and the A1 fan-out; ~1–2 means the Secure Agent pools well and the volume originates elsewhere. Also sizes L2 |
| 6 | **Does Informatica's PostgreSQL connector issue `DISCARD ALL`?** | Decides whether RDS Proxy is viable at all (2.2) |
| 7 | **Informatica pool idle-eviction setting** | If > 10 min, a new failure mode is already live |
| 8 | **Are there non-ABC consumers** of this instance? | A7 is entirely unassessed |
| 9 | **Was there a recent engine upgrade?** | Would make B11 relevant |
| 10 | **Is `grsdiai-hydration-…-i2` the instance ABC's control tables live on?** | Circumstantial evidence is strong (shared GRS naming) but unconfirmed; if not, the ABC-centric scenarios need re-weighting |

---

## Sources

### Internal

| # | Source | Used for |
|---|---|---|
| 1 | `Re URGENT Alignment Required  Dev Aurora DB Connection Issue.msg` | The six-message thread, both CloudWatch screenshots |
| 2 | `connection_analysis.md` | Prior analysis; §0 and 1.1 depart from it deliberately |
| 3 | `../w2-abc-framework/reference.md` | Framework mechanics, phase steps, table catalog, component copying |

### External (checked 17 Sep 2026)

| # | Source | Used for |
|---|---|---|
| 1 | [AWS — Resolve high CPU use for RDS / Aurora PostgreSQL](https://repost.aws/knowledge-center/rds-aurora-postgresql-high-cpu) | Diagnostic order; Enhanced Monitoring load average; stale statistics after upgrade |
| 2 | [AWS — Initial troubleshooting for Aurora PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/PostgreSQL.InitialTroubleshooting.html) | Triage approach |
| 3 | [Citus — Improving Postgres connection scalability: snapshots](https://www.citusdata.com/blog/2020/10/25/improving-postgres-connection-scalability-snapshots/) | `GetSnapshotData()` cost; the 33,457 → 14,496 TPS benchmark; PG14 fix (B2) |
| 4 | [PostgreSQL — Improving connection scalability: GetSnapshotData()](https://www.postgresql.org/message-id/20200301083601.ews6hz5dduc3w2se@alap3.anarazel.de) | Primary source for the same |
| 5 | [AWS — Performance and scaling for Aurora PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.Managing.html) | `max_connections` formula; r6g.large = 1,716 (B3) |
| 6 | [AWS re:Post — "remaining connection slots are reserved"](https://repost.aws/knowledge-center/rds-postgresql-error-connection-slots) | `superuser_reserved_connections`, `rds.rds_superuser_reserved_connections` (0.2) |
| 7 | [AWS — Avoiding pinning an RDS Proxy](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy-pinning.html) | Pinning conditions; no PostgreSQL pinning filters (2.2) |
| 8 | [AWS — RDS Proxy application and workload considerations](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy-best-practices.workload-considerations.html) | `DISCARD ALL` pinning; startup-message parameters (2.2) |
| 9 | [AWS — Avoid LWLock:buffer_content locks in Aurora](https://aws.amazon.com/blogs/database/avoid-postgresql-lwlockbuffer_content-locks-in-amazon-aurora-tips-and-best-practices/) | Buffer-content contention (B4) |
| 10 | [pganalyze — LWLock lock_manager contention](https://pganalyze.com/blog/5mins-postgres-LWLock-lock-manager-contention) | Lock manager partitioning; fast-path exhaustion (B4) |
| 11 | [Percona — PostgreSQL locking, part 3: lightweight locks](https://www.percona.com/blog/postgresql-locking-part-3-lightweight-locks/) | LWLock behaviour under concurrency (B4) |
| 12 | [Why PostgreSQL connections are expensive](https://pgh-web.com/blog/postgresql-connections-pgbouncer) | Fork cost, 3–20 ms setup vs 0.1–0.3 ms query, thundering herd (B1, A5) |
| 13 | [AWS — CloudWatch Database Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Database-Insights.html) | Standard mode, free tier, Performance Insights EOL (0.1) |
| 14 | [Informatica — Taskflow concurrency in IDMC CDI](https://knowledge.informatica.com/s/article/000190765?language=en_US) | Taskflow concurrency is a configurable ceiling (1.2) |
| 15 | [PostgreSQL — client connection defaults](https://www.postgresql.org/docs/current/runtime-config-client.html) | `idle_session_timeout`; pooler warning (1.5) |
| 16 | [PostgreSQL — monitoring stats / pg_stat_activity](https://www.postgresql.org/docs/current/monitoring-stats.html) | Wait events, `state`, column meanings (0.4) |
| 17 | [PostgreSQL — Concurrency Control (MVCC)](https://www.postgresql.org/docs/current/mvcc.html) | Readers never block writers; concurrent procedure execution is not serialised (L2) |
| 18 | [PostgreSQL — Explicit Locking](https://www.postgresql.org/docs/current/explicit-locking.html) | Advisory locks; lock modes and conflicts (L2) |
| 19 | [PostgreSQL Concurrency: Isolation and Locking — Dimitri Fontaine](https://tapoueh.org/blog/2018/07/postgresql-concurrency-isolation-and-locking/) | Isolation levels; when explicit locking is required (L2) |
| 20 | [PostgreSQL Concurrency with MVCC — Heroku](https://devcenter.heroku.com/articles/postgresql-concurrency) | MVCC write-new-versions model (L2) |
