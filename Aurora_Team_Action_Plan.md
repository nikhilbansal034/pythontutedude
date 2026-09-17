# Dev Aurora issue — team action plan

**Purpose**: what to check, what to do right now to unblock testing, and what to build in parallel so this
does not happen again.

**Audience**: the whole thread — DBA/AWS, Informatica, and application/ingestion teams. Part 1 is a
plain-English explanation of the moving parts; skip it if you already know Aurora and IDMC well.

**Related documents in this repo**
- `Aurora_DB_Connection_Analysis.md` — the source-by-source record of the email thread
- `Aurora_RootCause_Actions_LongTerm.md` — the full technical analysis behind this plan
- `abc_framework_success_scenario.md` — how the ABC framework works

---

## Part 1 — What is actually going on, in plain English

### 1.1 The three systems and what each one does here

| System | Role in this problem |
|---|---|
| **Aurora PostgreSQL** | The small **control-room database**. It does *not* hold business data. It holds ABC's bookkeeping — which batch is running, which job, how many rows moved, which quality rules passed. Small tables, but **written to constantly by every job**. This is the system that fell over. |
| **Snowflake** | Where the actual **business data** lives and where the heavy data processing happens. Not the problem here. |
| **IDMC / Informatica** | The tool that **runs the ETL taskflows**. It is the thing **opening the connections** to Aurora. The **Secure Agent** is the Informatica software running on a server that physically makes those connections. |

The short version: **Informatica is opening thousands of connections to the little control-room database, and
that database has stopped being able to serve anyone — including our own DBA.**

### 1.2 What a "database connection" actually is

This is the part that is usually misunderstood, and it explains nearly everything else.

A connection to PostgreSQL is **not** like loading a web page. When something connects, the database:

1. Starts a **brand-new operating-system process** dedicated to that one connection
2. Reserves roughly **5–10 MB of memory** for it
3. Keeps that process alive until the connection is explicitly closed

> **Analogy**: it is not "walking up to a counter and asking a question." It is **hiring a dedicated employee,
> giving them a desk, a chair and a computer, and keeping them on payroll** until you formally let them go.

So **4,490 connections means 4,490 processes and roughly 22–45 GB of memory just for the desks** — on a machine
that probably has around 8 CPU cores.

**And hiring is expensive relative to the work:**

| Operation | Rough CPU cost |
|---|---|
| Opening a new connection | **3–20 milliseconds** |
| Running a normal small query | **0.1–0.3 milliseconds** |

**Opening a connection costs 10–100× more than the query it exists to run.** If something is opening and
closing connections rapidly, the database can spend nearly all its CPU on hiring and firing, and almost none on
actual work. Praveen's own observation — *"these are Net new connections which are continuously hitting the
DB"* — describes exactly this pattern.

### 1.3 Why thousands of connections hurt even when they are idle

Two reasons:

1. **The CPU must keep switching between them.** With ~8 cores and thousands of processes, a large share of CPU
   time goes to scheduling rather than to work. A healthy ratio is roughly 5–10 connections per CPU core. We
   appear to be at **500+ per core**.
2. **On older PostgreSQL versions, idle connections directly slow down active ones.** Before PostgreSQL 14,
   every single query had to scan the complete list of all connections before it could run. Published
   benchmarks: the same workload dropped **57%** when 10,000 idle connections were present, with about half of
   all CPU spent doing nothing but scanning that list.

**This is why we must find out which PostgreSQL version we are on** (Check 3 below). If it is 13 or older,
idle connections are a direct cause and upgrading is a genuine fix. If it is 14 or newer, we look elsewhere.

### 1.4 What a "connection pool" is, and the risk that is live right now

A **connection pool** is the fix for the hiring problem: instead of hiring and firing an employee for every
task, you **keep a small permanent team — say 20 people — and hand them tasks as they come in.**

Both Informatica and AWS have this:
- **Informatica** has pool settings on its connection definitions (max active, max idle, idle eviction time)
- **AWS** has **RDS Proxy**, a pool that sits in front of the database

**Here is the risk that is live today.** Praveen has configured Aurora to **close any connection idle for
10 minutes**. If Informatica's pool holds connections idle for *longer* than 10 minutes, then:

> The pool believes it has 20 staff. Aurora has already sent 15 of them home. The pool hands a taskflow an
> employee who is not there. **The job fails with a confusing connection error.**

This has not been checked yet. **It is the single most urgent Informatica-side check** (Check 7), because the
10-minute timeout is *already applied in production Dev* — so this new failure mode may already be live.

### 1.5 Why the reboot did not fix it

Rebooting fires everyone. But **whatever was hiring them is still running**, so they get re-hired within
minutes. This is exactly what was observed: **1,500–4,000 connections back within minutes**.

It is actually worse than neutral, because everyone tries to get re-hired at the same instant — a
"**thundering herd**." A database can take longer to recover from the reconnection stampede than from the
original restart.

**Rebooting buys minutes, not a fix.** We should stop doing it until we have stopped the source.

### 1.6 Why "CPU is at 100%" tells us less than it seems

> **Analogy**: a speedometer that stops at 100 km/h. Whether you are doing 100 or 300, it reads 100. Slow down
> by a third — from 300 to 200 — and it *still* reads 100.

That is our CPU graph. It sat at 99.6–99.7% before and after the timeout removed ~1,700 connections.

The current analysis reads that as *"removing connections made no difference, so connections are not the CPU
problem."* **That conclusion is not safe.** All we can honestly say is that **it was not enough to get back
under the ceiling.**

To know the real number we need a metric that is **not capped**:
- **`LoadAverageMinute`** (Enhanced Monitoring) — if this reads 80 on 8 cores, demand is 10× capacity
- **`DBLoad`** (CloudWatch Database Insights) — also uncapped, and it breaks down **what** the CPU is doing

**Neither of these requires logging in to the database.** See 1.8.

### 1.7 Where the connections are most likely coming from

Reading the ABC framework design, the volume may largely be **the framework working as designed**, not a bug.

- One **job** = one target table
- Each job talks to Aurora at roughly **8–10 separate points** (job preload has 3 steps, job post load has 5,
  plus more) — and **each step is a separate Informatica task, so potentially its own connection**
- Each domain has its **own copy** of the ABC components, so **domains do not share a pool**
- Many jobs per batch, many batches running at once, plus developers triggering taskflows for unit testing

**The arithmetic:**

```
   100 concurrent jobs  ×  9 Aurora steps each  ×  5 connections per step  ≈  4,500 connections
```

That reaches the observed 4,490 **without any connection leak at all.**

**Why this matters for how we talk to the team**: the current framing in the thread is "find the leak / find
the team that is misbehaving." If the volume is structural, **no team is misbehaving** and asking them to hunt
for a leak will produce nothing. We need the measurements in Part 2 before we assign blame.

That said — a real leak may *also* exist. Before 16 September there were **no idle timeouts at all**, so any
connection ever leaked by a crashed or interrupted job accumulated forever. Both things can be true.

### 1.8 We are not as blind as we think

The 17 September escalation says we *"are completely unable to log in to the database or run administrative
diagnostics."* The login part is true. **The diagnostics part is not.**

| Tool | Needs a database login? | Tells us |
|---|---|---|
| **CloudWatch Database Insights** | **No** | Which queries, users and hosts are consuming the database; uncapped load metric |
| **Enhanced Monitoring** | **No** | OS process list, uncapped load average |
| **CloudWatch metrics** | **No** | Connections, CPU, memory, IOPS |
| **RDS Events / config** | **No** | Engine version, instance size, when the timeout was applied |

**All of this is available from the AWS Console right now, with no database session.** This is the fastest way
out of the current standstill, and it also removes our dependency on getting Datadog enabled first.

---

## Part 2 — What to check (start today)

These produce **evidence**. Almost everything in Part 3 and Part 4 is better decided once we have it.

Each check states **who**, **where**, **why it matters**, and **what to report back**.

### AWS / Database side — owner: Praveen (with DBA/platform support)

#### Check 1 — Open CloudWatch Database Insights ⭐ *highest priority*

- **Where**: AWS Console → RDS → Databases → `grsdiai-hydration-aurora-postgress-db-development-i2` →
  **Monitoring** tab → **Database Insights**
- **Capture**: Top SQL by DB load · Top waits · Top hosts · Top users · the `DBLoad` chart with the
  "Max vCPU" line shown
- **Why**: this answers *"what is the CPU actually doing"* — the question the whole thread is stuck on. Needs
  **no database login**. Standard mode is on by default and retains 7 days at no cost.
- **Report back**: screenshots of Top SQL and Top waits covering the saturation window

#### Check 2 — Enhanced Monitoring load average

- **Where**: RDS → the cluster → **Monitoring** → Enhanced Monitoring / OS Process List
- **Capture**: `LoadAverageMinute`, and the number of vCPUs
- **Why**: uncapped, so it tells us **how far past capacity we are** — which CPU% cannot. Load average of 80 on
  8 vCPUs means demand is roughly 10× what the box can serve.
- **Report back**: peak load average vs vCPU count

#### Check 3 — Engine version, instance class, and `max_connections` ⭐

- **Where**: RDS → the cluster → **Configuration** tab; and the parameter group for `max_connections`
- **Why**: **this single check re-ranks the whole investigation.**
  - **PostgreSQL 13 or older** → idle connections are directly burning CPU (see 1.3), and an **engine upgrade
    becomes a real performance fix**
  - **PostgreSQL 14+** → look instead at connection churn and lock contention
  - Instance class gives vCPU count → the connections-per-core ratio
  - We also need to know whether `max_connections` is the AWS default formula or was manually raised
- **Report back**: version, instance class, vCPU count, `max_connections` value
- **Effort**: about two minutes. Please do this one first.

#### Check 4 — Exact time the idle timeouts were applied

- **Where**: RDS → **Events**, or parameter group modification history
- **Why**: to line the change up against the connection graph and confirm what the drop from 4,490 → 2,750
  actually represents

#### Check 5 — Measure the connection *rate* (not the count)

- **Where**: parameter group → set `log_connections = on` and `log_disconnections = on`
- **Capture a 30–60 minute window, then turn them back off** (log volume is heavy under this load)
- **Why**: gives us **connections opened per second** and how long each session lives. This is the **single
  most important missing number** — it is what distinguishes "thousands of connections sitting there" from
  "thousands of connections being created and destroyed every minute," and those have completely different
  fixes.
- **Note**: check whether these parameters are dynamic on our engine version, or whether they need a restart
- **Report back**: connections opened per second at peak; median session lifetime

#### Check 6 — Once a session is available, run these three queries

**How to get in when normal logins are refused**: Aurora reserves connection slots for administrators
(`superuser_reserved_connections`, default 3, plus `rds.rds_superuser_reserved_connections`, default 2). **The
master user holds the `rds_superuser` role and can connect when ordinary users cannot.** If even that is
refused, raising `rds.rds_superuser_reserved_connections` in the parameter group creates more headroom.

> Connect with a **short timeout, one attempt at a time**. An admin retry loop makes the problem worse.

```sql
-- (a) Who is connected, from where, and in what state
SELECT client_addr, application_name, usename, state,
       count(*)                  AS conns,
       min(backend_start)        AS oldest,
       max(now() - state_change) AS longest_in_state
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1,2,3,4
ORDER BY conns DESC;

-- (b) What the sessions are WAITING on  ← the most diagnostic query we have
SELECT wait_event_type, wait_event, state, count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1,2,3
ORDER BY count(*) DESC;

-- (c) What has consumed the most CPU over time (needs pg_stat_statements)
SELECT calls, total_exec_time, mean_exec_time, rows, left(query,150)
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 25;
```

**How to read query (b)** — this is what tells us which problem we have:

| If the top wait is… | The problem is… | Which means we should… |
|---|---|---|
| `CPU`, with very short-lived sessions | **Connection churn** — the cost of opening connections | Pool connections (Part 4, WS3/WS5) |
| `LWLock:lock_manager` or `LWLock:buffer_content` | **Lock contention** — too many jobs writing the same small control tables | Batch the writes (Part 4, WS4) |
| `Lock:extend` | Concurrent inserts fighting over the same table | Same as above |
| `IO:DataFileRead` on small tables | **Missing indexes** — full table scans | Add indexes (Check 11) |
| One query dominating `pg_stat_statements` | **A single heavy query** | Tune that query |

#### Check 11 — Indexes on the ABC control tables

- **Owner**: whoever owns the ABC database DDL (please confirm who this is)
- **Why**: ABC looks records up in ways that are very slow without indexes — `batch_metadata` by a
  **four-column combination**, `job_metadata` by `job_name + batch_id`, and constant *"find the latest run"*
  queries against `batch_run_stats` / `job_run_stats`. The ABC documentation confirms these tables are
  **populated by manual DML today**, which is exactly when indexes get forgotten.
- **Check**: does an index exist for each of those lookup patterns?
- **Effort**: low, and if this is a contributor the improvement is immediate

### Informatica side — owner: Nidwika / Prateek

#### Check 7 — Connection pool settings ⭐ *urgent — a new failure mode may already be live*

- **Where**: IDMC Administrator → the Aurora/PostgreSQL connection definition(s)
- **Find**: maximum active connections · maximum idle connections · **idle eviction / idle timeout**
- **Why**: **Aurora now closes idle connections at 10 minutes.** If Informatica's pool holds them longer, it
  will hand taskflows connections that Aurora has already closed, and jobs will fail with confusing errors
  (see 1.4). Standard guidance is that the pool's idle limit must be **comfortably shorter** than the
  database's — target **5 minutes or less** against our 10-minute setting.
- **Report back**: the three values above, per connection definition
- **This is the one check where delay creates a *new* problem rather than prolonging the current one.**

#### Check 8 — How much runs at once

- **Find**: how many batches run concurrently · how many jobs per batch · peak concurrent taskflows during
  unit testing · whether any concurrency ceiling is currently configured
- **Why**: this is the multiplier in the 1.7 arithmetic. Without it we cannot tell structural volume from a
  leak.

#### Check 9 — How the PostgreSQL connector behaves *(Prateek — this was already your action item)*

Three specific questions:

1. **Does each mapping task open its own connection, or is there pooling across tasks?** This is the
   unmeasured `connections per step` term in 1.7.
2. **Can the connector set `ApplicationName`?** If yes, we can label every connection with its taskflow ID and
   permanently solve the *"which taskflow owns this connection"* question the whole thread is stuck on.
3. **Does the connector issue `DISCARD ALL` when returning a connection to the pool?** This sounds obscure but
   it decides whether **RDS Proxy is worth doing at all** — `DISCARD ALL` pins connections and removes
   essentially all of the benefit.

### Application / ingestion teams — owner: all dev leads

#### Check 10 — Who else connects to this database?

Praveen's question — *"where are we hitting these connections from?"* — is still open. Each team please
confirm **yes or no**:

- Any **AWS Glue or Spark** jobs writing to this Aurora instance? *(In Spark, the `numPartitions` setting is
  also the maximum number of simultaneous connections per job — a single job can open dozens.)*
- Any **BI, reporting or monitoring tools** pointed at it?
- Any **CI/CD pipelines or automated test suites**?
- Any **developer GUI sessions** left open? *(DBeaver and pgAdmin each open several connections per window,
  and they stay open overnight.)*
- Anything **deployed or restarted** around 15–16 September?

**A "no" is as useful as a "yes."** We currently cannot rule any of these out, and ruling them out is what
lets us focus on the framework.

---

## Part 3 — Temporary fixes to get testing unblocked

**Do these in order. Step 4 is not optional — skipping it will cause a fresh wave of job failures.**

### Step 1 — Stop the inflow

Pause **StoneBranch schedules** for Zone2 batches, and **stop or suspend IDMC taskflows** (or stop the Secure
Agent). This is the fastest route to a usable database and is what Praveen already requested.

*If nothing else works*: temporarily restrict the security group to block the Secure Agent subnet. Blunt, but
when a database refuses every login, network-level isolation is the only remaining control, and it lets the
database drain and catch up on internal housekeeping.

### Step 2 — Get an admin session

Connect as the **master user**, which can use the reserved admin slots (see Check 6). This restores our ability
to diagnose.

### Step 3 — Put a hard cap on ETL connections

```sql
ALTER ROLE <idmc_user> CONNECTION LIMIT 300;   -- choose a number well below max_connections
```

**What this does**: guarantees the database stays reachable **no matter what the ETL layer does**. It is an
emergency brake.

**The trade-off, stated honestly**: taskflows that exceed the cap **fail immediately** with a connection error
rather than waiting in a queue. This converts a **total database outage** into **individual job failures** —
a better failure mode, but the teams **will see failures and must be told to expect them.**

Notes: takes effect immediately with no restart, and is reversible with one statement. Because all taskflows
currently share one database user, this throttles every domain together — during an incident that is the
intended behaviour, but it is why Part 4 WS2 (separate users per domain) matters.

### Step 4 — Fix the pool timeout mismatch ⚠️ *before resuming anything*

Act on **Check 7**. If Informatica's pool holds idle connections longer than Aurora's 10 minutes, **reduce the
pool's idle eviction to 5 minutes or less first.**

**If we resume taskflows without doing this, we will trade a database outage for a wave of confusing job
failures**, and the teams will reasonably conclude the fix made things worse.

### Step 5 — Cap concurrency

Set a ceiling on how many batches and taskflows can run at once — in **StoneBranch**, in **IDMC taskflow
concurrency settings**, or both. Nothing limits this today.

This needs agreement across teams on what the ceiling should be, which is a conversation to have now rather
than during the next incident.

### Step 6 — Resume in a controlled way

Do **not** switch everything back on at once — that recreates the thundering herd from 1.5.

1. Restart **one team's taskflows** first
2. Watch `DatabaseConnections` and `DBLoad` for 15–30 minutes
3. If stable, add the next team
4. Record the connection count each team adds — **this gives us the per-team connection cost, which is exactly
   the number we need for capacity planning**

### Step 7 — Consider a temporary scale-up

A larger instance buys headroom to investigate. **This is explicitly not a fix** — scaling up before
understanding the cause means paying more for the same problem. Do it only if it unblocks diagnosis, and plan
to reverse it.

---

## Part 4 — Long-term workstreams (run in parallel)

### The problem we are actually solving

> **The number of Aurora connections we need grows in direct proportion to how much work we run — and nothing
> in the current design puts a ceiling on either.**

Every new domain, every new table, every new wave adds connections. Everything in Part 3 **raises the ceiling**.
None of it **changes the slope**. Without the items below, **this will happen again at a bigger number.**

### WS1 — Observability *(start immediately — cheapest, unblocks everything else)*

**Owner**: Praveen / platform

- Enable **CloudWatch Database Insights** properly for Dev and Non-Prod
- Enable **Datadog** database monitoring as the longer-term standard. Prerequisites:
  `shared_preload_libraries = pg_stat_statements`, `track_activity_query_size = 4096`, a restart, and a direct
  instance connection (**not** through a proxy)
- **Label every connection with its identity**

On that last point: ABC already generates `execution_run_id` and `job_run_id` and threads them through every
runtime table. If we stamp them onto the connection itself:

```sql
SET application_name = '<execution_run_id>:<job_run_id>';
```

…then *"which taskflow owns this connection?"* becomes a one-line query, **permanently**. This is a small
change with a large, lasting payoff, and it uses identifiers the framework already computes. It depends on
Check 9 question 2.

### WS2 — Separate database users per domain

**Owner**: Nidwika + Praveen · **Effort**: medium · **Needs**: a change request

Today **every IDMC taskflow shares one Aurora user**. That single fact defeats three things at once:

1. We cannot tell which domain's connections are which
2. We cannot limit one domain without limiting all of them
3. We cannot hold any team accountable for its own consumption

Separate roles fix all three, and turn `CONNECTION LIMIT` into a **per-domain budget** so one domain cannot
starve the others.

### WS3 — Put a connection pooler in front of Aurora

**Owner**: Praveen / platform, with Prateek on the Informatica behaviour · **Depends on**: Check 9 question 3

**RDS Proxy** (AWS-managed) or **PgBouncer**. ABC's Aurora traffic is a good fit — short, simple control-table
reads and writes.

**Test this before committing**: if the Informatica connector issues `DISCARD ALL` when returning connections,
RDS Proxy will **pin** every connection and deliver close to zero benefit. RDS Proxy also offers no
configuration workaround for this on PostgreSQL. If that turns out to be the case, **PgBouncer gives more
control** and should be the fallback.

Also note: setting `application_name` via `SET` (WS1) pins connections under RDS Proxy — pass it in the
connection startup parameters instead. The two workstreams need to be designed together.

### WS4 — Make ABC talk to Aurora less often ⭐ *biggest win available inside the framework*

**Owner**: ABC framework team · **Effort**: medium · **No new infrastructure required**

Today each phase is several separate Informatica steps, each with its own Aurora round trip:

```
  Today:   job preload    = 3 separate tasks,  ~6 round trips
           job post load  = 5 separate tasks,  ~8 round trips

  Target:  job preload    = 1 call to a single Aurora function
           job post load  = 1 call to a single Aurora function
```

That is roughly a **5–8× reduction in connections and round trips per job**, with **no change to what the
framework does**.

It also fixes a correctness problem that exists today: if a job fails halfway through preload, it leaves
**partially written control state** across three tables — which is precisely why ABC needs its elaborate
preload-failure and postload-failure cleanup components. Doing each phase in **one transaction** makes those
writes all-or-nothing, and the "stuck at status = Started" case that the ABC documentation describes stops
being reachable through normal failure paths.

**If we only do one long-term item, this is the one** — highest benefit per unit of effort, and entirely within
our own control.

### WS5 — A control-plane service between taskflows and Aurora

**Owner**: architecture / ABC team · **Effort**: high · **Horizon**: next quarter+

The permanent fix. Instead of every Informatica task connecting to Aurora directly, expose ABC's control
operations as an API. Taskflows call the service; **the service owns a small, fixed pool of connections.**

```
  Today:   5,000 taskflow steps  ───────────────────▶  5,000 Aurora connections

  Target:  5,000 taskflow steps  ──▶ ABC service ──▶  20–50 Aurora connections
                                     (fixed pool)
```

This **permanently breaks the link between how much work we run and how many connections we need.** Aurora
demand becomes a number we choose, rather than something that emerges from how many teams happen to be testing.
It also gives us one place to implement retry logic, backoff and metrics, instead of relying on every copied
component behaving correctly.

**Real costs**: a new deployable component, its own availability requirements, and a migration path for
existing domains. Justified because the alternative is re-solving this problem at every scale increment.

### WS6 — Give ABC its own database

**Owner**: Praveen / platform · **Effort**: medium

The ABC documentation records that a dedicated ABC-only Aurora database was *"pending / under discussion, not
yet stood up."* **Prioritise it.**

Today ABC's bookkeeping shares an instance with business data access, so either can starve the other — and, as
we saw this week, starve the DBA out of being able to diagnose it. The two workloads are also genuinely
different: the control plane is very many tiny transactions needing connection headroom; the data plane is
fewer, larger operations. They should be sized and tuned separately.

### WS7 — Make concurrency a governed number

**Owner**: Nidwika + scheduling team

Formalise Step 5 into a standing control: a documented maximum concurrent batch/job count, enforced in
StoneBranch and IDMC, reviewed when new domains onboard. Pair it with a **published per-domain connection
budget** (enabled by WS2) so that when the budget is exhausted it triggers a **capacity review rather than an
outage**.

### WS8 — Retention policy for the control tables

**Owner**: ABC team · **Horizon**: within the year, not urgent this week

`job_run_stats`, `job_rule_execution_log` and `job_rule_error_detail` grow without limit — and
`job_rule_error_detail` is **permanent and append-only in both Aurora and Snowflake**, at **one row per failing
column per failing record**. A single bad source file can add millions of rows.

As these tables grow, the "find the latest run" lookups get slower, and today's connection problem becomes
tomorrow's query problem. Partition by date, archive history to S3 or Snowflake, set an explicit retention
policy.

### WS9 — Dev environment strategy

**Owner**: Shilpa / Gayatri (a prioritisation decision, not a technical one)

Dev currently absorbs production-shaped parallelism on Dev-shaped hardware, shared by every team, during unit
testing — when load is least predictable. **Either size Dev for the concurrency it must absorb, or cap
concurrency to what Dev can serve.** Today neither is true.

Worth evaluating: **per-team schemas or separate Dev databases**, so one team's unit testing cannot block
another's. That directly addresses the impact in the thread — TD and MVP unit testing blocked, SIT and Helix
deliverables slipping.

---

## Part 5 — Who does what

### Immediate (today)

| # | Action | Owner | Effort |
|---|---|---|---|
| 1 | Check 3 — engine version, instance class, `max_connections` | Praveen | 2 min |
| 2 | Check 1 — Database Insights: top SQL, top waits | Praveen | 15 min |
| 3 | Check 2 — Enhanced Monitoring load average | Praveen | 10 min |
| 4 | Check 7 — **Informatica pool idle timeout** | Nidwika / Prateek | 30 min |
| 5 | Step 1 — pause schedules / taskflows | Nidwika + scheduling | 30 min |
| 6 | Step 2 — admin session via master user | Praveen | 15 min |
| 7 | Check 6 — the three diagnostic queries | Praveen | 30 min |
| 8 | Check 10 — confirm yes/no on other connection sources | **All dev leads** | 15 min each |

### This week

| # | Action | Owner |
|---|---|---|
| 9 | Step 3 — `ALTER ROLE … CONNECTION LIMIT` | Praveen |
| 10 | Step 4 — align Informatica pool timeout | Nidwika / Prateek |
| 11 | Step 5 — concurrency ceiling | Nidwika + scheduling |
| 12 | Step 6 — controlled, team-by-team resumption | All |
| 13 | Check 5 — connection-rate logging | Praveen |
| 14 | Check 8 — concurrency numbers | Nidwika |
| 15 | Check 9 — connector behaviour (3 questions) | Prateek |
| 16 | Check 11 — indexes on control tables | ABC DDL owner |

### Parallel workstreams

| WS | What | Owner | Effort |
|---|---|---|---|
| 1 | Observability + connection labelling | Praveen / platform | Low |
| 2 | Separate DB users per domain | Nidwika + Praveen | Medium |
| 3 | Connection pooler (test `DISCARD ALL` first) | Praveen + Prateek | Medium |
| 4 | **ABC stored procedures per phase** ⭐ | ABC team | Medium |
| 5 | ABC control-plane service | Architecture | High |
| 6 | Dedicated ABC Aurora database | Praveen / platform | Medium |
| 7 | Concurrency governance + connection budgets | Nidwika + scheduling | Low |
| 8 | Control-table retention | ABC team | Medium |
| 9 | Dev environment strategy | Shilpa / Gayatri | Decision |

---

## Part 6 — Draft note for the thread

> **Subject**: Re: URGENT: Alignment Required – Dev Aurora DB Connection Issue
>
> Hi all,
>
> Summarising where we are and what we need, so we can work in parallel rather than sequentially.
>
> **One correction that changes our next step.** We are not fully blind. **CloudWatch Database Insights and
> Enhanced Monitoring both work without a database login**, and between them they show which queries, users
> and hosts are consuming the instance. Database Insights Standard mode is on by default and retains 7 days at
> no cost. This means we do **not** need to wait for Datadog to get query-level visibility — we can have it
> today.
>
> **Three checks we need first, because they change what we do next:**
>
> 1. **Praveen** — the **PostgreSQL engine version, instance class and `max_connections`** (two minutes in the
>    RDS Configuration tab). If we are on PostgreSQL 13 or older, thousands of idle connections are *directly*
>    consuming CPU, and an engine upgrade becomes a real fix rather than housekeeping. On 14+, we look
>    elsewhere. This single fact re-orders the whole investigation.
> 2. **Praveen** — **Top SQL and Top waits** from Database Insights for the saturation window. This tells us
>    what the CPU is actually doing. Nobody has yet looked at what the database is executing.
> 3. **Nidwika / Prateek** — **Informatica's connection pool idle-eviction setting**. Aurora now closes idle
>    connections after 10 minutes. If the pool holds them longer, it will hand taskflows connections Aurora has
>    already closed and jobs will fail with confusing errors. **This may already be live**, so it is the most
>    urgent item on the Informatica side.
>
> **On the connection volume itself.** Working through the ABC framework design, each job touches Aurora at
> roughly 8–10 separate points, each a separate task, and each domain runs its own copy of the ABC components
> rather than sharing them. Around 100 concurrent jobs reaches the observed 4,490 connections **without any
> leak**. That does not rule out a leak — with no idle timeout in place before 16 September, anything leaked
> accumulated indefinitely — but it does mean **a large part of this may be the framework working as designed
> at the concurrency we are now running.** The connection-rate logging in the plan will tell us which.
>
> **To all dev and ingestion leads** — please confirm **yes or no** whether your team connects to this instance
> from anything besides IDMC taskflows: Glue/Spark jobs, BI or reporting tools, CI/CD suites, or developer
> sessions left open in DBeaver/pgAdmin. **A "no" is as useful as a "yes"** — we currently cannot rule any of
> these out.
>
> **To unblock testing**, the proposed sequence is: pause the schedules → cap connections on the ETL role so
> the database stays reachable → **fix the pool timeout mismatch first** → then resume one team at a time
> while watching the metrics. Please note the cap means taskflows over the limit will fail rather than queue —
> that is deliberate, and a better outcome than the whole database being unreachable, but teams should expect
> some failures during the restart.
>
> The full plan, including the longer-term changes we should start in parallel, is attached.
>
> Regards,
> Nikhil

---

## Open questions we still need answered

| # | Question | Who | Why it matters |
|---|---|---|---|
| 1 | PostgreSQL engine version | Praveen | Decides whether idle connections are a primary cause |
| 2 | Instance class and `max_connections` | Praveen | Sets the real ceiling and the connections-per-core ratio |
| 3 | Connections opened **per second** | Praveen | Distinguishes "many connections" from "rapid churn" — different fixes |
| 4 | Top wait events | Praveen | Discriminates between every candidate cause in one screen |
| 5 | Connections per Informatica mapping task | Prateek | The unmeasured multiplier in the arithmetic |
| 6 | Does the connector issue `DISCARD ALL`? | Prateek | Decides whether RDS Proxy is viable at all |
| 7 | Informatica pool idle-eviction setting | Nidwika | A new failure mode may already be live |
| 8 | Any non-IDMC consumers of this instance? | All dev leads | Entirely unassessed today |
| 9 | Was there a recent engine upgrade? | Praveen | Stale statistics are a known cause of CPU spikes |
| 10 | Do ABC's control tables live on **this** instance? | Data integration team | Shared "GRS" naming makes it probable but unconfirmed |

Question 10 is worth flagging explicitly: **much of the framework-based reasoning in this plan assumes ABC's
control tables are on this instance.** The naming makes that very likely, but nobody has confirmed it. If it
turns out to be a different instance, Part 1.7 and workstreams WS4–WS6 need re-weighting.
