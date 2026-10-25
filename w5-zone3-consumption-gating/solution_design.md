# Zone 3 Consumption Gating — Complete Solution Design

**The solution proposal for this workstream.** The requirement itself lives in
[`problem_statement.md`](problem_statement.md) — that is the baseline this design answers to, and if the
two ever disagree, the baseline wins.

| | |
|---|---|
| **Requirement baseline** | [`problem_statement.md`](problem_statement.md) — Part A, Part B, R1-R28. **The source of truth** |
| Background only | [POC02](sources/POC02_Recommendation_and_Design%201.html), [POC05](sources/POC05%20-%20Same-Name%20Clone%20Refresh%20for%20Consumption%20-%20Deck.html). The baseline excludes both as inputs. Citations to them are flagged where they occur and are pending a decision to lift that exclusion or drop them |
| Meeting source | "Discuss code freeze activities" — transcript synthesis |
| Test scripts | [`00_setup.sql`](00_setup.sql) … [`05_sizing_performance.sql`](05_sizing_performance.sql), [`99_teardown.sql`](99_teardown.sql) |
| Test tracker | [`Zone3_Gating_Test_Tracker.xlsx`](Zone3_Gating_Test_Tracker.xlsx) |
| Deck | [`requirement_deck_v2.html`](requirement_deck_v2.html) — the baseline deck extended with solution slides |
| Status | **Design proposal. Nothing concluded. Every mechanism needs POC validation before sign-off.** |

**Evidence discipline used throughout.** Every Snowflake behaviour statement carries one of three markers:

| Marker | Means |
|---|---|
| **✅ Verified** | Quoted from Snowflake documentation. Link given in §11 |
| **🧪 Needs test** | Not documented. The stated expectation is our assumption and is listed as a test case |
| **📋 POC evidence** | Proven by our own POC02 / POC05 capture, not by documentation |

---

## 1. The problem

A report reads 12 objects. The nightly batch refreshes all 12.

At 04:10 the batch is still running. Seven objects hold tonight's data; five still hold last night's. A user opens the report.

The report returns numbers. They are plausible. Each of the 12 objects is internally valid — every load check passed on every one. Nothing errors, nothing is blank, nothing is flagged. But the figures come from **two different nights mixed together**, and the user has no way to know.

Not corruption. Not failure. **Incompleteness that nothing reports.**

### 1.1 What the requirement asks for

- **Part A — publication gating.** A consumer sees one complete version, or the previous one. Never a mixture. New data appears only when a publication step runs, after all the cycle's jobs succeed. A failed cycle publishes nothing — unless the business explicitly authorises a partial release, on the record.
- **Part B — governance continuity.** Whatever the consumer reads carries the tags, masking and access **currently** defined for it, including a change governance made mid-cycle, and never re-adding a protection governance deliberately removed.

### 1.2 Constraints that are not negotiable

| | Constraint | Source |
|---|---|---|
| C1 | No rewriting existing view logic as new ETL | Requirement deck |
| C2 | Runs every cycle, unattended, under the batch identity | Requirement deck |
| C3 | Zone 2 load behaviour is untouched | Requirement deck |
| C4 | No consumer-facing access to earlier versions | Requirement deck |
| C5 | No masked value ever written to disk as though genuine | Requirement deck |
| C6 | **Development effort is a first-class design criterion, not an afterthought** | Meeting — Idhanta cautioned against adopting the earlier deck's preference because effort had not been weighed |
| C7 | Objects not created through the Liquibase deployment role may be treated as orphans and removed | Meeting — Nidwika, from discussion with Raja and Anoop |

**C6 and C7 are the two that overturn the obvious answer.** Without them, clone-and-swap wins on Snowflake behaviour alone. With them, it does not.

---

## 2. The five Snowflake concepts the design rests on

### 2.1 A table holds data. A view does not.

A **table** is storage. A **view** is a *saved SQL query* — nothing is stored; the SQL runs at query time against whatever the underlying tables hold at that instant.

1. **A view is always current.** It cannot hold yesterday's data, because it holds no data.
2. **So you cannot gate a view by doing anything to the view.** The only route is to make the tables beneath it consistent.
3. **Conversely, if the tables beneath a view all flip together, the view is consistent for free.** No work on the view at all.

Point 3 is the cheapest thing available. Point 2 is why the problem is hard.

### 2.2 Protection lives in the tag, not in the data

A sensitive column gets a **tag**; a **masking policy** attaches to the tag. **✅ Verified:** *"the tagged column is automatically protected by the conditions in the masking policy"* when data types match. Enforcement is a query rewrite — **✅ Verified:** *"Snowflake dynamically rewrites the query applying the masking policy SQL expression to the column."*

So the risk is not copying data. **The risk is losing the tag.** Identical data without the tag is exposed, and nothing errors.

**📋 POC evidence:** stored values remain plaintext — POC02 removed the policy binding and the real value read back. The documentation does not state this outright; treat it as proven by our own evidence pack.

### 2.3 A clone is free — with fine print

**✅ Verified:** tags — *"Tag associations in the source object (e.g. table) are maintained in the cloned objects."* Policies — *"A cloned table maps to the same policies as the source table."* Grants — *"do not copy grants on the source object to the object clone"* unless `COPY GRANTS`.

**✅ Verified, and it is the trap:** *"A table moved or cloned out of a schema with a tag-based masking policy is not protected by the tag-based masking policy set on the source schema or database."* So where the tag is **bound** decides whether a cross-schema clone stays protected. See §5.3.

### 2.4 A swap exchanges names

**✅ Verified, table level:** *"Swap renames two tables in a single transaction"*, requires OWNERSHIP on both.
**✅ Verified, schema level:** *"Swaps all objects (tables, views, etc.) and metadata, including identifiers, between the two specified schemas. Also swaps all access control privileges granted on the schemas and objects they contain"*, as *"a rename of both schemas as a single operation"*, OWNERSHIP on both.
**✅ Verified:** `ALTER DATABASE … SWAP WITH` also exists.

No data moves. It is a rename.

### 2.5 `INSERT OVERWRITE` replaces contents without replacing the table

**✅ Verified:** the target *"should be truncated before inserting the values into the table"*; *"specifying this option does not affect the access control privileges on the table"*; *"can be processed within the scope of the current transaction. This avoids DDL statements that commit a transaction"*; requires DELETE privilege. Snowflake's own comparison marks `INSERT … OVERWRITE` **Atomic: Yes** against TRUNCATE+INSERT as *"No (table is empty between the two statements)."*

The table object is never dropped, so it keeps its identity — and therefore, **🧪 by expectation**, its tags, policies and owner. Grants are documented; the rest is TC-004 / TC-005 / TC-006.

---

## 3. Why views are the hard part

The consumption layer contains **both tables and views**, and the Teradata estate carries **thousands of views**.

Clone and swap only work on physical objects. A view has nothing to clone. So gating a view means first turning it into a table — and done naively that means rebuilding each view's SQL as a new ETL mapping, thousands of times, each needing development and validation. That is C6, and it is what makes "which feature is technically best" the wrong question. The right one:

> How do we get a gated, physical, correctly-governed object out of an existing view **without rebuilding its logic as ETL**?

### 3.1 The three scenarios

| | Scenario | What it needs |
|---|---|---|
| **T** | Consumption object is already a table | Physical already. Only the *publication* question applies |
| **V-a** | View whose base tables all sit inside one gated group | **Nothing.** The tables flip together, the view inherits. Zero effort |
| **V-b** | View whose tables span groups, or which is itself the frozen consumer contract | Must be physicalized. This is where all the effort is |

**V-a is the lever.** Every view pushed into V-a costs nothing. Only the V-b remainder costs anything, and nobody currently knows whether that is 40 objects or 4,000 — which is why §9 item 2 comes before any build.

---

## 4. Every option, discussed

Stable IDs. These are referenced by the deck and the test tracker.

### O1 — Per-object load checks (status quo)
**What it is.** Each object has load validation; trust it.
**Why it fails.** The exposure is invisible by construction — every object is individually valid, so every individual check passes. A per-object check can never detect a disagreement *between* objects. This is today's state and it is what we were asked to fix.
**Verdict:** rejected. It is the problem statement, not a solution.

### O2 — Lock readers out during the batch
**What it is.** A maintenance window, or revoke reporting access for the duration.
**Why it fails.** Reports are read throughout the day; there is no window. Revoking access mid-session produces errors rather than stale-but-correct data — worse than the defect. The requirement wants uninterrupted reads.
**Verdict:** rejected.

### O3 — Shrink the load window
**What it is.** Make the load fast enough that the inconsistent window hardly matters.
**Why it fails.** The requirement says *never* a mixed state, not *rarely*. A one-second window is still a wrong report, and the user who hits it gets no signal. Shrinking is not eliminating.
**Verdict:** rejected.

### O4 — One transaction around the whole batch
**What it is.** `BEGIN;` load all 12 objects; `COMMIT;`. Snowflake DML is transactional, so on paper readers see the before-state until commit.
**Why it fails — four independent reasons.**
1. The loads run as **separate IDMC mappings in separate sessions.** A transaction cannot span them. Fatal on its own.
2. **✅ Verified:** *"DDL statements implicitly commit active transactions"* — any DDL in the block breaks it.
3. It would hold a write transaction open for hours. **✅ Verified:** a transaction not blocking others is aborted when *"older than 4 hours"*.
4. **No gate.** Validation would have to happen inside the transaction before commit, which the orchestrator cannot do across tools — and a failure at hour three rolls back everything.
**Verdict:** rejected as stated — but see **O11**, which applies the same idea to the *publication step only* and survives.

### O5 — Filter inside each view ("show only the latest safe version")
**What it is.** Each view adds a predicate restricting it to the last fully validated load. Publication becomes one update of a control value.
**Why it fails.** Raised by Prateek in the meeting and rejected there: **there is no reliable universal "latest" criterion across all participating tables.** It would require consistent date/audit columns on every object *plus* a known batch-completion value controlling what may be released, and the earlier validation-date concept had been removed. It also violates C1 — every view in the estate would be edited.
**Verdict:** rejected. This is what pushed the discussion toward publication as an explicit event rather than asking every view to decide for itself. **O12** is the same idea moved off the view and onto the table, which changes the objection from feasibility to cost.

### O6 — Materialized views
**What it is.** Snowflake maintains a physical, auto-refreshed copy of a query — superficially "a view that is also a table".
**Why it fails. ✅ All verified:** *"A materialized view can query only a single table"*; *"Joins, including self-joins, are not supported"*; a non-materialized view cannot be queried by one; no window functions, `HAVING`, `ORDER BY`, `LIMIT` or nested subqueries; limited aggregates; *"automatically and transparently maintained by Snowflake"* so there is nowhere for a gate. And decisively: *"A materialized view cannot be created if the underlying table is protected by a tag-based masking policy."*
Our consumption objects are fact/dimension joins over masked bases. Every one of those rules it out.
**Verdict:** rejected on documented limitations.

### O7 — Dynamic tables
**What it is.** Declare the target as a dynamic table on a freshness target; Snowflake refreshes it and makes the result visible atomically. No cutover code.
**What changed since POC02.** POC02 rejected these partly on cost, citing `091955 Change tracking is not supported on queries using policies that contain subqueries` — full rebuild every cycle over a masked base. **✅ Verified, and this is now partly obsolete:** *"Dynamic tables that have base tables with arbitrary masking or row access policies can now maintain incremental refresh when the policy is pass-through for the role used during refresh (that is, when the refresh role has unrestricted access to all rows and columns regardless of the policy condition). Previously, only policies using allow-listed functions, such as `CURRENT_ROLE()`, `IS_ROLE_IN_SESSION()`, were compatible with incremental refresh."* (GA 2026-07-20.)
Note what "pass-through" means: **the refresh role sees everything unmasked.** That is the same security question as §8.1, not an escape from it. And **✅ Verified:** *"Subqueries outside of FROM clauses (for example, WHERE EXISTS) are not supported"* for incremental refresh.
**Why it still fails, and this is decisive.** Refresh is *"automatically and transparently maintained"* — **there is no point between "loaded" and "visible" where a gate can live.** The requirement makes publication a *decision*; a dynamic table makes it a consequence. It is also a second physical copy whose protection must be managed on its own columns.
**Verdict:** rejected for gated objects — on governance and the missing gate, no longer on cost. Still viable for an unmasked single-SELECT feed where freshness beats control.

### O8 — CTAS each cycle
**What it is.** `CREATE OR REPLACE TABLE t AS SELECT * FROM <the existing view>`. The point, and it is a good one: **let the existing view be the SELECT.** No ETL rebuild. This is why CTAS came back into the discussion.

```
existing view  →  CTAS  →  physical consumption object      ← cheap
existing view logic  →  new ETL mapping  →  physical table  ← expensive
```

**What I had wrong.** I rejected this on tag loss, citing POC02's capture of 4 tagged columns becoming 0. **✅ Verified, and that rejection no longer holds as stated:** `COPY TAGS` for `CREATE OR REPLACE TABLE` reached GA on 2026-04-02; *"tags from the replaced table and its columns are retained on the new table"*; it works with `AS SELECT` — the documentation's own example is `CREATE OR REPLACE TABLE dst1 COPY TAGS AS SELECT b AS a, a AS b FROM src1`; and *"You don't need privileges on the tags to use COPY TAGS."* POC02's finding holds only for CTAS *without* the clause.

So the viable form is:

```sql
CREATE OR REPLACE TABLE Z3_STG.CUSTOMER_360
  COPY GRANTS COPY TAGS
  AS SELECT * FROM Z3_CONSUME.V_CUSTOMER_360;
```

**What still counts against it.**
1. **✅ Verified:** *"Using OR REPLACE is the equivalent of using DROP TABLE on the existing table."* The object is genuinely destroyed and recreated every night.
2. **✅ Verified, and this is the discriminator:** `COPY GRANTS` *"copies all privileges, except OWNERSHIP"*, and without it *"the role that runs the statement owns the new table."* So **ownership moves to the service account every cycle** — C7, nightly.
3. **✅ Verified:** a renamed column loses its tag. An ordinary view edit becomes a silent protection gap.
4. **✅ Verified:** CTAS does not carry a clustering key forward — to have one you *"must spell out the column definitions yourself"*. So clustering can be silently dropped, and Automatic Clustering then pays to rebuild it every cycle.
5. Time Travel retains a whole dropped table version per cycle.
6. N objects = N statements = N commits → **not atomic across a group.**
**Verdict:** viable fallback. Not preferred, because of (2) and (4).

### O9 — Clone and swap (POC02's recommendation)
**What it is.** Clone the live object, load the clone, gate it, swap the names.
**What it gets right.** Atomic at schema level; tags maintained; policies mapped; zero-copy; never reads column values; a real gate point; rollback is another swap. On Snowflake behaviour alone this is the best-behaved option, and POC02 proved it.
**Why it cannot be the whole answer.**
1. **It needs a physical source object.** Nothing to clone for thousands of views — C6. This is the objection raised in the meeting and it is decisive.
2. A daily `CREATE OR REPLACE … CLONE` **creates an object at runtime** with the same ownership move as O8 — C7.
3. **✅ Verified:** grants are not copied without `COPY GRANTS`, and on a first creation with it they come from the *clone source*, not the intended consumption object — POC05's Day-1 bootstrap gap.
4. The §2.3 schema-level tag-based masking trap.
**Verdict:** its *swap* half is kept (→ O16). Its *clone-as-refresh* half is rejected. Clone is retained only for the cheap carry-forward of objects not refreshed this cycle.

### O10 — `INSERT OVERWRITE` into a pre-deployed table ← **recommended refresh mechanism**
**What it is.** Deploy the table once through Liquibase with tags, masking, grants and owner set at deployment. Then every cycle replace its *contents*:

```sql
INSERT OVERWRITE INTO Z3_STG.CUSTOMER_360
SELECT * FROM Z3_CONSUME.V_CUSTOMER_360;   -- the existing view IS the transform
```

**Why it wins.** It keeps O8's cost advantage (the existing view supplies the logic) while changing *contents* rather than *objects* — and governance is attached to the object.

| | O8 CTAS + `COPY TAGS`/`COPY GRANTS` | O9 Clone/swap | **O10 `INSERT OVERWRITE`** |
|---|---|---|---|
| Reuses existing view logic | ✅ Yes | ❌ No — needs a physical source | ✅ **Yes** |
| Tags survive | ✅ Verified | ✅ Verified | 🧪 **Expected — TC-004** |
| Grants survive | ✅ Verified | ✅ with `COPY GRANTS` | ✅ **Verified** |
| **Owner unchanged** | ❌ **No — moves to executing role** | ❌ **No** | ✅ **Yes — object never recreated** |
| Creates an object at runtime (C7) | ❌ Yes, nightly | ❌ Yes, nightly | ✅ **No** |
| Clustering key survives | ❌ Not unless restated | ✅ Yes | 🧪 **Expected — TC-030** |
| Renamed column keeps tag | ❌ No | n/a | 🧪 Expected — TC-012 |
| Runs inside a transaction | ❌ No — DDL commits | ❌ No | ✅ **Verified** |
| Atomic for one object | ✅ Yes | ✅ Yes | ✅ **Verified** |
| Atomic across a group | ❌ No | ✅ via schema swap | ✅ via O11 or O16 |

**The discriminator is ownership, not tags.** Now that `COPY TAGS` exists, CTAS can keep its metadata. What it cannot avoid is being a `DROP` + `CREATE`, which hands the service account a new object every night against C7.
**Honest costs.** Storage is a genuine second copy of the rows. The load reads the data, so §8.1 applies. And the shape-change dependency — addressed by O18.
**Verdict:** recommended, conditional on TC-004 / TC-005 / TC-006 passing.

### O11 — N × `INSERT OVERWRITE` inside one explicit transaction ← **recommended publication, multi-table**
**What it is.** O4's idea applied to the publication step only. Build into staging outside any transaction — slowly, with joins, over hours, in any tool. Then publish in one short transaction:

```sql
BEGIN;
  INSERT OVERWRITE INTO Z3_PUB.FACT_PREMIUM SELECT * FROM Z3_STG.FACT_PREMIUM;
  INSERT OVERWRITE INTO Z3_PUB.DIM_POLICY   SELECT * FROM Z3_STG.DIM_POLICY;
  INSERT OVERWRITE INTO Z3_PUB.DIM_BROKER   SELECT * FROM Z3_STG.DIM_BROKER;
  INSERT OVERWRITE INTO Z3_PUB.DIM_DATE     SELECT * FROM Z3_STG.DIM_DATE;
COMMIT;
```

**✅ Verified mechanics.** *"READ COMMITTED is the only isolation level currently supported for tables"*; a statement *"sees only data that was committed before it began, and it never reads uncommitted data from other transactions"*; *"All statements in the transaction are either applied (committed) or undone (rolled back) together"*; `INSERT OVERWRITE` *"can be processed within the scope of the current transaction"*; standard tables in one transaction *"may reside in different databases"*; readers are unaffected — *"Only UPDATE and DELETE DML operations are blocked when a table is locked"* and SELECT is *"always read-only"*.

**Why this matters more than it looks.** It dissolves the constraint that was shaping the whole physical design:

> **The consistency group no longer has to map to a schema.**

That was the frozen working position flagged as most likely to be wrong. A transaction has no schema boundary. Groups can be whatever the dependency walk says, with no re-cutting of schemas. It also removes three further problems:

| Problem with O16 swap | Under O11 |
|---|---|
| OWNERSHIP on both schemas — the C7 privilege question | Only INSERT + DELETE on the published tables |
| Previous version left readable under the staging name (§5.5) | Does not arise — nothing is renamed |
| Group must align to a schema | Any arbitrary set |

**Honest costs.** You write the data twice — the publish transaction is a straight `SELECT *` copy, no join cost, but a real second write. Publish duration is proportional to group size, not milliseconds.
**✅ Verified limits to respect.** No DDL inside the block. A transaction blocking another and idle for 5 minutes is aborted; one not blocking others is aborted past 4 hours. *"Overly large transactions can reduce parallelism or increase deadlocks."*
**🧪 Needs test.** That a reader spanning the `COMMIT` never sees a mixed state across the group is the documented consequence of READ COMMITTED, but it is the single most important claim in this design and must be demonstrated, not inferred — TC-020.
**Verdict:** recommended default for multi-object groups.

### O12 — Row access policy + control table
**What it is.** O5 moved off the view and onto the table. Each published table carries a version column; a row access policy restricts reporting roles to the published version, read from a single control row. Publication is one `UPDATE`.
**The appeal is real.** One statement flips any number of tables in any schema or database; **views need no edits at all**, because the policy attaches to the table and views inherit; objects are never recreated, so governance is untouched; rollback is another `UPDATE`.
**✅ Verified costs.** *"Including one or more subqueries in the policy body may cause errors"* — Snowflake advises limiting subqueries and JOINs and recommends a **memoizable function** in place of a mapping-table lookup. *"Mapping tables may result in decreased performance compared with simple policies."* And the one that hurts most on a reporting layer: metadata shortcuts such as `COUNT` and `MAX` are generally unavailable on protected tables. External tables cannot be mapping tables. A policy's rule changes take effect on the next query, but its signature cannot be changed in place.
It also needs two versions of every row in the table, and a version column on the consumption contract.
**Verdict:** documented fallback if neither O11 nor O16 can cover a group. It buys atomicity at the price of a permanent read-time tax, where O11 pays once at publish time.

### O13 — Hybrid tables
**What it is.** Snowflake's OLTP table type, with genuine multi-table ACID transactions and row-level locking.
**Why it fails. ✅ All verified:** **2 TB of hybrid-table data per database**, and exceeding it blocks writes that add data; explicitly *"not recommended for interactive analytics workloads"*; no clustering keys, no dynamic tables, no materialized views, no streams, no replication; transaction scope for hybrid tables is the database they sit in.
A consumption layer is bulk-loaded, scanned and aggregated — the opposite of their purpose.
**Verdict:** rejected.

### O14 — Iceberg tables
**What it is.** Zone 1 already uses Iceberg, so a fair question for Zone 3.
**✅ Verified:** masking policies and tags **are** supported, and v3 supports `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `TRUNCATE TABLE` and `COPY INTO`.
**Why it is not the mechanism.** Iceberg's atomic snapshot commit is **per table** — nothing gives multi-table atomicity, which is the actual requirement. **✅ Verified:** the limitations include that **you cannot roll back to a previous snapshot**, so "publish by moving the snapshot pointer" is unavailable. And **🧪** `INSERT OVERWRITE` on Snowflake-managed Iceberg tables is **not named in the documentation** — TC-033.
**Verdict:** a storage-format choice, not a publication mechanism. If Zone 3 lands on Iceberg, O11 is still the mechanism, subject to TC-033.

### O15 — `CREATE TABLE IF NOT EXISTS` as the refresh
**What it is.** Asked directly: use `IF NOT EXISTS` instead of `OR REPLACE`.
**✅ Verified:** *"The `OR REPLACE` and `IF NOT EXISTS` clauses are mutually exclusive. They can't both be used in the same statement."*
**🧪 Not documented:** what happens when the table already exists. The CTAS syntax block does not show the clause at all — TC-013.
**Why it fails regardless of that detail.** `IF NOT EXISTS` is a **creation guard**. It asks one question — does this object exist? — and if yes, declines to create. It is not a refresh instruction and has no opinion about data.

| | What happens | Consumer sees |
|---|---|---|
| Day 1 | Created and populated | Day-1 data |
| Day 2 | Table exists → declines to act | **Day-1 data** |
| Day 3+ | Same | **Day-1 data, forever** |

No error. The table never changes again and nobody is told — a *worse* failure than the one being fixed: a permanent silent defect in place of an intermittent one.
**Where it does belong:** deployment. Idempotent create — "ensure this exists, don't complain if it does." Right tool, wrong layer.
**Verdict:** rejected as a refresh mechanism; adopted for deployment, alongside O18.

### O16 — `ALTER SCHEMA … SWAP WITH` ← publication, large schema-aligned groups
**What it is.** Two pre-deployed schemas, `Z3_PUB_<group>` and `Z3_STG_<group>`. Build into staging; one swap exchanges the names.
**✅ Verified:** swaps all objects and metadata including identifiers, and all access control privileges on the schemas and the objects they contain, as one operation; OWNERSHIP on both schemas.
**What it buys over O11.** No second write — it is a rename, so publish time is milliseconds regardless of group size.
**What it costs.** The group must align to a schema. OWNERSHIP on both schemas, which is the C7 conversation. And §5.5's unresolved consequence — grants travel with objects, so the previous version sits under the staging name still carrying the reporting grant.
**Verdict:** keep for groups large enough that O11's second write is unaffordable **and** which already align to a schema.

### O17 — `ALTER DATABASE … SWAP WITH`
**✅ Verified** to exist; swaps all objects including schemas, tables and views, and metadata, between two databases. The bigger-grained version of O16 — relevant if a group spans schemas but fits one database. Same trade-offs, larger blast radius.
**Verdict:** available; not expected to be needed if O11 is adopted.

### O18 — `CREATE OR ALTER TABLE` (deployment, not refresh)
**What it is.** Brings an existing table up to a stated definition **without destroying it**. GA for tables 2026-07-14.
**✅ Verified:** *"If the object exists, it's altered into the object defined in the statement"*; data, tag associations, attached policies and privilege grants on the object are preserved. **✅ Verified limits:** cannot set or unset a tag or policy (use `ALTER`); cannot rename objects or columns or change column order; CTAS / `LIKE` / `USING TEMPLATE` forms unsupported; cannot change a column to an incompatible type; dropping a column loses its data; OWNERSHIP required; no search optimization.
**Why it matters here.** It resolves the shape-change dependency O10 otherwise has: Liquibase can evolve the table as the source view gains columns, without destroying the object, so governance survives the change.
**Verdict:** adopted for deployment.

### O19–O22 — considered and set aside

| ID | Option | Why not the mechanism |
|---|---|---|
| O19 | Time Travel `AT(TIMESTAMP =>)` | Cannot be driven from a control table inside a view definition. Retention is charged, and DDL changes break `AT` reads. Useful for rollback evidence only |
| O20 | Streams + Tasks; task-graph finalizer task | Orchestration, not visibility. A finalizer runs after all tasks complete *including on failure*, which makes it a good home for the publish *decision* — but it is not a publication mechanism |
| O21 | Three-step `ALTER TABLE … RENAME TO` | Not atomic, and leaves a window where the name does not exist at all. Strictly worse than O16 |
| O22 | Secure views | Access control, not versioning. Also blocks optimiser pushdown |

---

## 5. The recommended design

> Every gated consumption object is a **physical table, deployed once through Liquibase with its governance attached, and refreshed by replacing its contents — never by recreating the object.** Publication is chosen by group shape. Views sitting entirely above a gated group are left untouched and inherit consistency for free.

### 5.1 Mechanism by group shape

| Group shape | Refresh | Publication | Why |
|---|---|---|---|
| **One table** | O10 | **Nothing extra** | `INSERT OVERWRITE` is already atomic and already leaves grants alone. No staging, no swap, no OWNERSHIP question |
| **Several tables, any layout** | O10 into staging | **O11 — one transaction** | Atomic across the set, no schema-alignment constraint, no OWNERSHIP escalation. Costs a second write |
| **Several, very large, already schema-aligned** | O10 into staging | **O16 — schema swap** | Avoids the second write. Costs the schema constraint, the C7 question and §5.5 |
| **Nothing above fits** | O10 | **O12 — row access policy** | Works anywhere. Costs a permanent read-time tax |

The refresh statement is O10 in every row. **Only publication varies** — which keeps this one design, not four.

### 5.2 Object layout

| Layer | Swapped (O16 only)? | Holds |
|---|---|---|
| `Z3_GOVERNANCE` | never | Tags, masking policies, row access policies, the declared governance baseline |
| `Z3_PUB_<group>` | yes | Published tables consumers read. Liquibase-deployed |
| `Z3_STG_<group>` | yes | Same tables, next cycle's contents. Liquibase-deployed |
| `Z3_CONSUME` | never | The existing view estate — **text unchanged** |
| `Z3_CONTROL` | never | Publication state, gate results, partial-release authorisations |

Views stay outside the swapped pair because a swap exchanges schema **names** — `Z3_PUB_SALES.CUSTOMER` keeps resolving, now to the other storage — so view SQL is untouched (C1). It also avoids POC02's caveat about a view inside a swapped schema referencing its own fully-qualified path.

### 5.3 Bind tags at column level — a rule, not a preference

Because **✅ Verified** *"a table moved or cloned out of a schema … is not protected by the tag-based masking policy set on the source schema or database"*, choose one and apply it consistently:

- **Bind tags at column level** on both published and staging tables, at deployment. Clone and swap then both preserve protection because the tag travels on the object. **Recommended.**
- Or bind at schema level and set identically on both schemas — more moving parts, and it fails silently if one side drifts.

Also **✅ Verified** and constraining where `Z3_GOVERNANCE` sits: tag-based masking blocks `DROP` and `CREATE OR REPLACE` of a database or schema when the tag and policy share a schema but the protected table is elsewhere, or when the protected column is in a different schema from the policy and tag. Check the layout against that list before fixing it.

### 5.4 The cycle

```
 Zone 2 completes  (unchanged — C3)
      │
      ▼
 ┌───────────────────────────────────────────────────────────────┐
 │ 1 PREPARE   carry forward anything not refreshed this cycle   │
 │             (clone, COPY GRANTS — cheap, no data read)        │
 │ 2 LOAD      O10: INSERT OVERWRITE into Z3_STG_<group>.        │
 │             Source = the existing view, or an existing IDMC   │
 │             mapping retargeted by parameter (no logic change) │
 │ 3 GATE      completeness checks + governance reconciliation   │
 │             FAIL → publish nothing; consumers keep previous   │
 │             AUTHORISED PARTIAL → recorded, then proceed       │
 └───────────────────────────────────────────────────────────────┘
      │              ← nothing above is visible to any consumer
      ▼
 ┌───────────────────────────────────────────────────────────────┐
 │ 4 PUBLISH   per §5.1, by group shape                          │
 └───────────────────────────────────────────────────────────────┘
      │
      ▼
 ┌───────────────────────────────────────────────────────────────┐
 │ 5 VERIFY    post-publish assertions → publication record      │
 │ 6 HOLD      previous version retained one cycle for rollback  │
 └───────────────────────────────────────────────────────────────┘
```

Steps 1–3 are invisible to consumers. Only step 4 changes what anyone can see.

### 5.5 The open consequence of O16 that needs a decision

**✅ Verified:** schema swap swaps *"all access control privileges granted on the schemas and objects they contain."* Grants therefore travel **with the objects**. After the swap, last night's data sits under the staging name **still carrying the reporting role's SELECT**. A reporting user naming `Z3_STG_SALES.CUSTOMER` explicitly could read the previous version.

Not a Part A failure — reports point at the published name and see one consistent version — but it sits against C4. **🧪** Whether schema-level `USAGE` also swaps, which decides whether this is reachable at all, is not settled by the documentation — TC-022. **O11 does not have this problem at all**, which is a further reason to prefer it.

---

## 6. Views and tables: one solution, three entry points

| Scenario | How it enters | Extra effort |
|---|---|---|
| **T** | It *is* a `Z3_PUB_<group>` table. O10, then publication per §5.1 | None beyond the standard pattern |
| **V-a** | **Left alone.** Inherits consistency from the published tables | **Zero** |
| **V-b** | A table is deployed with its shape and tags, then `INSERT OVERWRITE … SELECT * FROM <the view>`. **The view supplies the logic — no ETL is built** | One deployment per object |

After that all three are the same object type, same schema pair, same refresh, same gate, same publication, same governance handling. **Combine them. One mechanism.**

If V-b consumers must keep today's object name: deploy the table as `CUSTOMER_360_T` and redefine the view `CUSTOMER_360` as `SELECT * FROM CUSTOMER_360_T`. One mechanical line per view, not a logic rewrite — but it is a change to the view estate and should be named as one.

---

## 7. ETL pipeline implementation

Orchestration stays in Stonebranch, which already holds the dependency graph and was confirmed able to report completion/fail status rather than just invocation.

```
Stonebranch workflow: Z3_PUBLISH_<group>
├── 00 wait        Zone 2 completion signal for the group's sources
├── 10 prepare     SQL: carry-forward clones into staging (COPY GRANTS)
├── 20 build       existing IDMC mappings, retargeted to Z3_STG_<group>
│                  (target schema is a mapping parameter — no logic change)
├── 30 gate        SQL: checks + governance reconciliation → Z3_CONTROL
│   └── on FAIL →  publish nothing; notify; optional authorisation branch
├── 40 publish     SQL per §5.1 (nothing / transaction / swap / control row)
├── 50 verify      SQL: post-publish assertions; write publication record
└── 60 notify      success, or stale-data alert per the Ops threshold
```

- **IDMC change is a parameter, not a rewrite.** Mappings point at a staging schema instead of the published one. No mapping logic changes — this is what keeps the design inside C1.
- **Steps 10–50 are plain SQL** run by the batch identity. Confirm whether named stored procedures are permitted; if not, an anonymous Snowflake Scripting block via `EXECUTE IMMEDIATE` does the same work with no persistent object.
- **Gate output is data, not an exit code.** Write every check result to `Z3_CONTROL` so a failed cycle is diagnosable and the authorisation decision has something to reference.
- **No DDL inside the O11 publish transaction.** A stray `CREATE` or `ALTER` silently commits and breaks atomicity.
- **Set `DATA_RETENTION_TIME_IN_DAYS` explicitly.** Rollback needs one cycle, not the default.
- **Check for streams** on any published object before go-live — TC-031.
- **No `USE SECONDARY ROLES ALL`.** POC02's least-privilege open item applies here too.

### 7.1 Publication state

One record per group per cycle in `Z3_CONTROL`: `group_name`, `cycle_id`, `published_at`, `published_by`, `jobs_expected`, `jobs_succeeded`, `gate_result` (PASS / FAIL / AUTHORISED_PARTIAL), `authorisation_ref`, `previous_cycle_id`.

This is what the Ops alerting threshold hangs off — alert when `now() - last successful published_at` exceeds the agreed limit. Without it, the first signal is a user asking why the numbers look stale.

Natural home is the existing ABC audit framework rather than a parallel one. Confirm before building a separate control schema.

---

## 8. What can still break this

### 8.1 The security call decides how much can be gated

Physicalizing a view means **reading its output and writing those rows down** — true of O10, O8, any ETL mapping, and O7's pass-through refresh role. If the batch identity sees masked values it writes masked values, which C5 forbids. It is inherent to physicalization, not a property of one mechanism.

| Step | Reads sensitive values? |
|---|---|
| Prepare (carry-forward clone) | No — metadata and pointers |
| **Load (O10 from a view)** | **Yes** |
| Gate | No — metadata and counts |
| Publish (O11 copy) | **Yes — it is a second read of staging** |
| Publish (O16 swap) | No — a rename |

So the open call does not merely tune the build. **It decides how much of the view estate can be gated at all.** If the answer is no: exclude sensitive columns from physicalized objects and accept they are not gated; obtain the exemption POC02 already used; or keep those objects in V-a and gate the tables beneath them.

*Correction on the record: I earlier stated a "no" would constrain only the build step and not threaten the architecture. That understated it.*

### 8.2 Part B needs something to reconcile against

Part B's non-reinstatement clause (R25) is not satisfied by inheritance. A clone carries what the source had *at clone time*, so a publish can silently reinstate a tag governance deleted mid-cycle.

O10 is much better — the object is never recreated, so a live governance change applies immediately and nothing was lost. But the gate must still **verify** that what is about to be published carries the protection currently declared, and fail if not. That requires a **declared governance baseline** — the configuration-table idea Nidwika raised, formalised. Without one there is nothing authoritative to compare against and the clause is unimplementable. Security's prerequisite, not ours.

### 8.3 Open calls

- **May the batch identity read sensitive data in the clear?** §8.1. Answer first.
- **Is there a declared governance baseline?** §8.2.
- **Can the batch identity execute the publication step** under platform ownership policy? O11 needs only INSERT + DELETE; O16 needs OWNERSHIP on both schemas. Ruling needed from Raja / Anoop.
- **Does publication state live in ABC** or a separate control schema?
- **Are named stored procedures permitted?**
- **Do any Zone 3 objects feed a share or replication?** A swap follows the name, so share consumers would see new data.

---

## 9. What to measure and prove

Full scenario and test-case breakdown is in [`Zone3_Gating_Test_Tracker.xlsx`](Zone3_Gating_Test_Tracker.xlsx); scripts are the numbered `.sql` files in this folder. The three that can change the design:

| Priority | Question | Test |
|---|---|---|
| 1 | **Does `INSERT OVERWRITE` preserve tags, masking policies and owner?** Grants are documented; the rest is our assumption and the whole design rests on it | TC-004 … TC-006 |
| 2 | **Does a reader spanning the O11 `COMMIT` ever see a mixed state?** | TC-020 |
| 3 | **How many objects actually need gating, and do groups fit a schema?** | TC-040, TC-041 |

If 1 fails, O10 collapses toward O8 and the ownership problem returns. If 2 fails, O11 is out and O16's constraints come back. If 3 shows groups spanning schemas, O11 is the only viable publication mechanism.

---

## 10. Sizing and group derivation

Two answers from one query pair, runnable now, offline.

```sql
-- 1. Objects the reporting identities actually read (scope the real population)
SELECT DISTINCT bo.value:objectName::string AS object_name
FROM   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
       LATERAL FLATTEN(base_objects_accessed) bo
WHERE  query_start_time > DATEADD(day, -90, CURRENT_TIMESTAMP())
  AND  user_name IN (/* Power BI / reporting service identities */);

-- 2. Walk each consumed view down to its base tables = group membership
WITH RECURSIVE dep AS (
    SELECT referencing_database, referencing_schema, referencing_object_name,
           referenced_database,  referenced_schema,  referenced_object_name, 1 AS lvl
    FROM   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
    WHERE  referencing_object_name IN (/* result of query 1 */)
    UNION ALL
    SELECT d.referencing_database, d.referencing_schema, d.referencing_object_name,
           o.referenced_database,  o.referenced_schema,  o.referenced_object_name, d.lvl + 1
    FROM   dep d
    JOIN   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES o
      ON   o.referencing_object_name = d.referenced_object_name
     AND   o.referencing_schema      = d.referenced_schema
    WHERE  d.lvl < 10
)
SELECT referenced_schema, COUNT(DISTINCT referenced_object_name) AS tables_to_gate
FROM   dep GROUP BY referenced_schema ORDER BY tables_to_gate DESC;
```

Query 2 **is** the test of whether groups fit schemas: if one consumed view's base tables land in more than one `referenced_schema`, that group spans schemas and O16 cannot publish it atomically.

**Note:** `ACCOUNT_USAGE` has replication latency of up to hours — fine for offline sizing. **A gate must use the `INFORMATION_SCHEMA` table functions instead** (`TAG_REFERENCES`, `POLICY_REFERENCES`), which are real-time.

---

## 11. Verified facts, with sources

| # | Claim | Documentation wording | Status |
|---|---|---|---|
| 1 | `INSERT OVERWRITE` is atomic | `INSERT … OVERWRITE` **Atomic: Yes**; TRUNCATE+INSERT **"No (table is empty between the two statements)"** | ✅ [input data optimization](https://docs.snowflake.com/en/user-guide/dynamic-tables/input-data-optimization) |
| 2 | `INSERT OVERWRITE` preserves grants | *"specifying this option does not affect the access control privileges on the table"* | ✅ [INSERT](https://docs.snowflake.com/en/sql-reference/sql/insert) |
| 3 | `INSERT OVERWRITE` needs DELETE privilege | *"OVERWRITE will delete the existing records in the table"* | ✅ [INSERT](https://docs.snowflake.com/en/sql-reference/sql/insert) |
| 4 | `INSERT OVERWRITE` can run in a transaction | *"can be processed within the scope of the current transaction"* | ✅ [INSERT](https://docs.snowflake.com/en/sql-reference/sql/insert) |
| 5 | `INSERT OVERWRITE` preserves tags, policies and owner | **Not stated.** The page contrasts OVERWRITE with `DROP`+`CREATE`, implying the object persists | 🧪 **TC-004/005/006** |
| 6 | `OR REPLACE` destroys the object | *"Using OR REPLACE is the equivalent of using DROP TABLE on the existing table"* | ✅ [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 7 | `OR REPLACE` and `IF NOT EXISTS` are mutually exclusive | *"The OR REPLACE and IF NOT EXISTS clauses are mutually exclusive. They can't both be used in the same statement."* | ✅ [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 8 | `IF NOT EXISTS` behaviour when the table exists | Not documented; CTAS syntax block does not show the clause | 🧪 **TC-013** |
| 9 | Without `COPY GRANTS` a replaced table loses explicit grants | *"does not inherit any explicit access privileges granted on the original table, but does inherit any future grants"* | ✅ [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 10 | Without `COPY GRANTS` ownership moves to the executing role | *"the role that runs the statement owns the new table"*; `COPY GRANTS` copies all privileges **except OWNERSHIP** | ✅ [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 11 | `COPY GRANTS` on CTAS copies from the replaced table | *"copies permissions from the table being replaced … not from the source table(s) being queried"* | ✅ [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 12 | `COPY GRANTS` on CLONE falls back to the clone source on first creation | From the replaced table if one exists, else from the source being cloned | ✅ confirms POC05's Day-1 gap — [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 13 | **CTAS can retain tags** via `COPY TAGS` | GA 2026-04-02; *"tags from the replaced table and its columns are retained on the new table"*; docs example uses `AS SELECT` | ✅ [release note](https://docs.snowflake.com/en/release-notes/2026/other/2026-04-02-create-table-copy-tags-ga) |
| 14 | A renamed column loses its tag under `COPY TAGS` | Stated in CREATE TABLE usage notes | ✅ [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 15 | CTAS does not carry a clustering key forward | With clustering keys in a CTAS, column definitions *"must be explicitly specified"*; CLONE and LIKE do inherit the key | ✅ [CREATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/create-table) |
| 16 | Table swap is one transaction, OWNERSHIP on both | *"Swap renames two tables in a single transaction"*; *"must have OWNERSHIP privileges on the table or tables"* | ✅ [ALTER TABLE](https://docs.snowflake.com/en/sql-reference/sql/alter-table) |
| 17 | Table swap carries grants | **Not stated anywhere on the page** | 🧪 **TC-021** |
| 18 | Schema swap exchanges objects, metadata and grants as one operation | *"Swaps all objects (tables, views, etc.) and metadata, including identifiers … Also swaps all access control privileges granted on the schemas and objects they contain"*; OWNERSHIP on both | ✅ [ALTER SCHEMA](https://docs.snowflake.com/en/sql-reference/sql/alter-schema) |
| 19 | `ALTER DATABASE … SWAP WITH` exists | Swaps all objects including schemas, tables and views, and metadata | ✅ [ALTER DATABASE](https://docs.snowflake.com/en/sql-reference/sql/alter-database) |
| 20 | A clone maintains tags | *"Tag associations in the source object (e.g. table) are maintained in the cloned objects"* | ✅ [cloning](https://docs.snowflake.com/en/user-guide/object-clone) |
| 21 | A clone maps to the same policies | *"A cloned table maps to the same policies as the source table"* | ✅ [cloning](https://docs.snowflake.com/en/user-guide/object-clone) |
| 22 | A clone does not copy grants by default | *"do not copy grants on the source object to the object clone"* | ✅ [cloning](https://docs.snowflake.com/en/user-guide/object-clone) |
| 23 | **A clone out of a schema loses that schema's tag-based masking** | *"A table moved or cloned out of a schema with a tag-based masking policy is not protected by the tag-based masking policy set on the source schema or database"* | ✅ [cloning](https://docs.snowflake.com/en/user-guide/object-clone) |
| 24 | Tag-based masking protects a tagged column automatically when types match | *"the tagged column is automatically protected by the conditions in the masking policy"* | ✅ [tag-based masking](https://docs.snowflake.com/en/user-guide/tag-based-masking-policies) |
| 25 | A direct column policy beats a tag-based one | *"the masking policy that is directly assigned to the column takes precedence over the tag-based masking policy"* | ✅ [tag-based masking](https://docs.snowflake.com/en/user-guide/tag-based-masking-policies) |
| 26 | Masking is enforced by query rewrite at read time | *"Snowflake dynamically rewrites the query applying the masking policy SQL expression to the column"* | ✅ [column-level security](https://docs.snowflake.com/en/user-guide/security-column-ddm-use) |
| 27 | Stored data remains plaintext | **Not stated in the docs** | 📋 POC02 |
| 28 | Materialized views cannot serve this use case | *"A materialized view can query only a single table"*; *"Joins, including self-joins, are not supported"*; cannot query a non-materialized view; *"automatically and transparently maintained"* | ✅ [materialized views](https://docs.snowflake.com/en/user-guide/views-materialized) |
| 29 | A materialized view cannot be created over a tag-based-masked table | *"A materialized view cannot be created if the underlying table is protected by a tag-based masking policy"* | ✅ [tag-based masking](https://docs.snowflake.com/en/user-guide/tag-based-masking-policies) |
| 30 | **Dynamic tables can refresh incrementally over a masked base** | *"…can now maintain incremental refresh when the policy is pass-through for the role used during refresh"* | ✅ [release note](https://docs.snowflake.com/en/release-notes/2026/other/2026-07-20-dynamic-tables-pass-through-policies) |
| 31 | Dynamic tables offer no gate point | Refresh is *"automatically and transparently maintained"*; no documented pre-visibility hook | ✅ by absence — [refresh modes](https://docs.snowflake.com/en/user-guide/dynamic-tables/refresh-modes) |
| 32 | Subqueries outside `FROM` block incremental refresh | *"Subqueries outside of FROM clauses (for example, WHERE EXISTS) are not supported"* | ✅ [supported queries](https://docs.snowflake.com/en/user-guide/dynamic-tables/supported-queries) |
| 33 | `CREATE OR ALTER TABLE` alters in place, preserving governance | *"If the object exists, it's altered into the object defined in the statement"*; data, tag associations, attached policies and grants preserved | ✅ [CREATE OR ALTER](https://docs.snowflake.com/en/sql-reference/sql/create-or-alter) |
| 34 | `CREATE OR ALTER TABLE` cannot set tags, rename columns, or do CTAS | Setting/unsetting a tag or policy unsupported; cannot rename objects or columns or change column order; CTAS/LIKE/USING TEMPLATE unsupported; OWNERSHIP required | ✅ [CREATE OR ALTER](https://docs.snowflake.com/en/sql-reference/sql/create-or-alter) |
| 35 | Tag-based masking restricts DROP/REPLACE of databases and schemas | Restricted when tag and policy share a schema but the table is elsewhere, or the protected column is in a different schema from policy and tag | ✅ [tag-based masking](https://docs.snowflake.com/en/user-guide/tag-based-masking-policies) |
| 36 | READ COMMITTED; a statement sees only pre-commit data | *"READ COMMITTED is the only isolation level currently supported for tables"*; a statement *"sees only data that was committed before it began, and it never reads uncommitted data from other transactions"* | ✅ [transactions](https://docs.snowflake.com/en/sql-reference/transactions) |
| 37 | All statements in a transaction commit or roll back together | *"All statements in the transaction are either applied (committed) or undone (rolled back) together"* | ✅ [transactions](https://docs.snowflake.com/en/sql-reference/transactions) |
| 38 | DDL implicitly commits an active transaction | *"DDL statements implicitly commit active transactions"*; *"you cannot roll back a DDL statement"* | ✅ [transactions](https://docs.snowflake.com/en/sql-reference/transactions) |
| 39 | Transaction abort thresholds | Blocking another and idle 5 minutes → aborted; not blocking others and *"older than 4 hours"* → aborted. *"Overly large transactions can reduce parallelism or increase deadlocks"* | ✅ [transactions](https://docs.snowflake.com/en/sql-reference/transactions) |
| 40 | Readers are not blocked by writers | *"Only UPDATE and DELETE DML operations are blocked when a table is locked"*; SELECT statements are *"always read-only"* | ✅ [transactions](https://docs.snowflake.com/en/sql-reference/transactions) |
| 41 | Standard tables in one transaction may span databases | *"standard Snowflake tables referenced in the same transaction may reside in different databases"* | ✅ [hybrid tables](https://docs.snowflake.com/en/user-guide/tables-hybrid) |
| 42 | A group publish under O11 never shows a mixed state to a reader | Follows from #36 and #37, but not stated as such | 🧪 **TC-020** |
| 43 | Row access policy subqueries may error; mapping tables cost performance | *"Including one or more subqueries in the policy body may cause errors"*; *"Mapping tables may result in decreased performance compared with simple policies"*; metadata shortcuts such as COUNT and MAX generally unavailable on protected tables | ✅ [row access policies](https://docs.snowflake.com/en/user-guide/security-row-intro), [using](https://docs.snowflake.com/en/user-guide/security-row-using) |
| 44 | Hybrid tables: 2 TB/database, not for analytics, many unsupported features | 2 TB per database; *"not recommended for interactive analytics workloads"*; no clustering keys, dynamic tables, materialized views, streams, replication | ✅ [limitations](https://docs.snowflake.com/en/user-guide/tables-hybrid-limitations), [interactive](https://docs.snowflake.com/en/user-guide/interactive) |
| 45 | Iceberg supports masking and tags; cannot roll back to a prior snapshot | Data protection policies supported; v3 supports INSERT/UPDATE/DELETE/MERGE/TRUNCATE/COPY INTO; *"can't roll back to a previous snapshot"* | ✅ [Iceberg tables](https://docs.snowflake.com/en/user-guide/tables-iceberg) |
| 46 | `INSERT OVERWRITE` on Snowflake-managed Iceberg tables | **Not named in the documentation** | 🧪 **TC-033** |
| 47 | TRUNCATE leaves the table and its privileges intact | *"Removes all rows from a table but leaves the table intact (including all privileges and constraints on the table)"* | ✅ [TRUNCATE TABLE](https://docs.snowflake.com/en/sql-reference/sql/truncate-table) |
| 48 | Relative performance of `INSERT OVERWRITE` vs CTAS | **No published benchmark exists** | 🧪 **TC-050…TC-053** |

---

## 12. Glossary

| Term | Meaning |
|---|---|
| **Consistency group** | The objects one report needs to agree with each other. §4 O11, §5.1 |
| **Publication** | The moment a new version becomes visible — a decision, not a side effect |
| **CTAS** | `CREATE TABLE AS SELECT`. Recreates the object; needs `COPY TAGS` / `COPY GRANTS` to keep governance, and still moves ownership |
| **Clone** | Zero-copy snapshot. Keeps tags and policy mappings; keeps grants only with `COPY GRANTS` |
| **Swap** | Exchanges two objects', schemas' or databases' names. No data moves |
| **`INSERT OVERWRITE`** | Replaces a table's contents atomically while keeping the object — and therefore its governance and owner |
| **`CREATE OR ALTER`** | Brings an existing object up to a stated definition without destroying it |
| **Tag-based masking** | A tag marks a column sensitive; a policy on the tag masks it at read time |
| **Pass-through policy** | A policy under which the refresh role sees all rows and columns regardless of the condition |
| **Physicalization** | Turning a view into a real table. Required for gating, and the main source of effort |
| **V-a / V-b** | A view that inherits gating for free / a view that must itself be physicalized |
| **Liquibase** | The deployment tool. Objects it creates are owned by the deployment role, which keeps them off the orphan list |
