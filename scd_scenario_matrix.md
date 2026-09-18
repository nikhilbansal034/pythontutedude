# W3 scenario catalogue — which combinations hit the effective-date split problem

Status: **draft for review.** Built under both readings of Q1 (see `scd_glossary.md`) because the answer is
not yet confirmed with Nidhika. Team's informal answer is **Q1b**; both are carried until confirmed.

Nothing here proposes a solution. The purpose is to establish which source/target combinations are already
handled by the existing pattern and which need new logic, and *why* each one breaks.

---

## 1. The two worlds

| | Reading | Effect |
|---|---|---|
| **Q1a** | Zone1 current bucket holds **all** of the source's effective-dated versions | A current-bucket read of an SCD2 source still carries a timeline |
| **Q1b** | Zone1 current bucket holds **one row per business key** | A current-bucket read carries no timeline at all |

The whole difference between the two worlds is whether configuration **C2** below is a timeline contributor.
Everything else is identical.

---

## 2. Source read configurations

A source is characterised by *what it is in the SOR* × *which bucket we read it from* — not by SCD type
alone.

| Code | Source SCD type | Read from | Valid-time versions? | Transaction-time versions? |
|------|----------------|-----------|----------------------|----------------------------|
| **H2** | SCD2 | history | Yes — the source's own effective dates | Yes — Zone1 appends |
| **H1** | SCD1 | history | No | Yes — Zone1 appends on each change |
| **C2** | SCD2 | current | **Q1a: yes / Q1b: no** | No |
| **C1** | SCD1 | current | No | No |
| **REF** | reference / type-list | either | No | No |
| **Z2** | already-built Zone2 SCD2 table used as a source | Zone2 | Yes | — |

Two of these are not in the transcript and need confirming:

- **H1** — does Zone1 even build history-bucket tables for sources that are SCD1? If it does, that table has
  an ingest-time history and *can* drive target dates. **[Unknown]**
- **Z2** — the transcript mentions it in passing: *"Or the second table would have been your zone 2 table,
  not the zone 1 table."* A Zone2 target is SCD2, so it carries a timeline.

### Timeline Contributor classification

> A source **S** is a **Timeline Contributor** to target **T** if all of:
> 1. **T** is SCD2
> 2. the read exposes multiple versions per business key over time
> 3. at least one column of **S** that varies across those versions lands in **T**
> 4. the join preserves those versions rather than collapsing them
>
> **The problem occurs iff a target has ≥ 2 Timeline Contributors.**

| Config | Contributor under Q1a | Contributor under Q1b | Clock it dates on |
|--------|----------------------|----------------------|-------------------|
| H2 | **Yes** | **Yes** | business (valid time) |
| H1 | **Yes** | **Yes** | **ingest (transaction time)** |
| C2 | **Yes** | No | business (valid time) |
| C1 | No | No | — |
| REF | No | No | — |
| Z2 | **Yes** | **Yes** | business (inherited) |

---

## 3. Pair matrix (target = SCD2)

| # | S1 | S2 | Q1a | Q1b | Notes |
|---|----|----|-----|-----|-------|
| 1 | H2 | H2 | **PROBLEM** | **PROBLEM** | The transcript scenario |
| 2 | H2 | C2 | **PROBLEM** | OK | **The divergence** — this row is the whole reason Q1 matters |
| 3 | C2 | C2 | **PROBLEM** | Edge — 0 contributors | |
| 4 | H2 | H1 | **PROBLEM + clock mismatch** | **PROBLEM + clock mismatch** | See M10 |
| 5 | H1 | H1 | **PROBLEM** | **PROBLEM** | Both ingest-timed — internally consistent |
| 6 | H1 | C2 | **PROBLEM + clock mismatch** | OK | |
| 7 | H2 | Z2 | **PROBLEM + cascade** | **PROBLEM + cascade** | See M11 |
| 8 | H2 | C1 | OK | OK | Existing pattern — driving table sets dates |
| 9 | H2 | REF | OK | OK | Existing pattern |
| 10 | C2 | C1 | OK | Edge — 0 contributors | |
| 11 | C1 | C1 | Edge — 0 contributors | Edge — 0 contributors | Target dates must come from load date |
| 12 | *any* | *any* | **OK** | **OK** | **Target is SCD1** — no timeline to build |

**Under Q1b: 4 problem rows. Under Q1a: 7.** Rows 2 and 6 flip; row 3 changes character entirely.

For 3+ contributors the same rule applies — the algorithm generalises, the SQL grows, and every mechanism
below compounds.

---

## 4. Failure mechanisms

What actually goes wrong. Each problem scenario fires a different subset.

### M1 — Version boundary union
Each contributor has its own version boundaries; the target needs the **union** of them. Taking either
table's dates alone under-splits the target.

*Example (the transcript's):* Tbl1 changes at 10-Sep and 21-Sep. Tbl2 changes at 15-Sep and 22-Sep. The
target needs boundaries at 9, 10, 15, 21, 22 — five intervals, not the two or three either table implies.

**Fires in:** every problem row.

### M2 — Retroactive split of an already-loaded interval
A later run introduces a boundary that falls *inside* an interval already written to the target. The existing
target row is no longer valid and must be superseded, then replaced by two or more rows.

*Example:* Day 1 wrote `10-Sep → 21-Sep`. Day 2 brings a boundary at 15-Sep. That row must be soft-deleted
and replaced by `10-Sep → 15-Sep` and `15-Sep → 21-Sep`.

This is the expensive mechanism — it is what makes the load a reconciliation rather than an append.
**Does not fire on initial/history load**, where there is nothing to supersede.

**Fires in:** every problem row, incremental mode only.

### M3 — Coverage gaps and non-overlapping lifespans
One contributor's timeline starts later, ends earlier, or has a hole. Intervals exist where one side has no
version at all.

*Example:* Tbl2 is valid from 9-Sep but Tbl1 only starts at 10-Sep. The interval `9-Sep → 10-Sep` has a Tbl2
value and no Tbl1 value.

This forces the **inner vs. full outer** decision, which the call debated and never settled. The screenshot
keeps that row with a NULL, implying full outer. Mid-timeline gaps are a second, unexercised case.

**Fires in:** every problem row.

### M4 — Restatement (transaction-time correction)
The source corrects the value of a *past* version without moving its effective dates. The dates stay right;
the payload is now wrong.

*Example:* Source previously said `10-Sep → 21-Sep = a`. It now says that interval was always `= z`.

A **history-bucket** read shows you both assertions. A **current-bucket** read shows only the latest, so the
restatement is invisible in the source and can only be found by diffing against the target.

**Fires in:** rows with a C2 contributor (Q1a), and any row with a current-bucket attribute source.

### M5 — Disappearing versions
Distinct from M4 and more dangerous. If the source *removes* a version — merges two intervals, deletes a
correction — a current-bucket read simply stops showing it. There is no tombstone.

Delta detection scans for rows whose audit/refined timestamp moved. **A row that no longer exists has no
timestamp to scan.** So the key is never flagged as impacted, and the stale target rows survive indefinitely.

This needs a tombstone mechanism, a periodic full reconciliation, or a source guarantee that versions are
never removed. None of the three is currently established.

**Fires in:** rows with a C2 contributor (Q1a) — this is the single strongest argument for confirming Q1
rather than assuming Q1b.

### M6 — Intra-day / multi-batch arrival
Several versions for the same key arrive in one run — multiple batches in a day, or a catch-up after several
days. Two rows may share a `row_eff_dt`.

Nidhika's stated rule: *"there are two records for the same row effective date when you are reading it at
once — at that time you take the latest record of it."* Must happen **before** boundary computation.

**Fires in:** every problem row.

### M7 — Over-splitting from hash scope mismatch
A source version changes only in columns that are **not** projected to the target. That creates a boundary
that produces two adjacent, identical target versions.

Nidhika: *"maybe the non-key that you have to take to the target is still intact, only some other values have
changed — in this case it is not a real split."*

Deduplication must run on target-relevant columns only, before boundaries are computed.

**Fires in:** every problem row.

### M8 — Source deletes at the tail
A key is deleted in one contributor while the other continues. Does the target timeline terminate at the
delete date, or continue with NULL for the deleted side? This is M3 applied to the tail, and the answer
follows from the inner/outer decision — but it also collides with `is_del`, which is already being used to
mean "superseded". One flag cannot express both "this version was corrected" and "this record was deleted
at source".

**Fires in:** every problem row where sources can delete.

### M9 — Grain mismatch (1:N)
One contributor has multiple rows per key at the same instant. The join fans out and the target grain is no
longer (key, eff date). Probably a **separate problem class** rather than a variant of this one.

**Fires in:** any row where the join is not 1:1.

### M10 — Clock mismatch
Two contributors dating on different clocks — one on business effective dates, one on ingest timestamps.
Unioning those boundaries produces a timeline that is neither.

*Example:* Tbl1 (H2) says a change was effective **11-Sep**. Tbl2 (H1) has no business date; the only date
available is when Zone1 ingested it, **18-Sep**. The target will assert Tbl2's value changed on 18-Sep. An
as-of-12-Sep query returns the stale Tbl2 value, and nothing in the output marks which columns are
business-timed and which are ingest-timed.

This is **information loss, not a SQL bug** — it cannot be fixed downstream. It needs an explicit decision.

Compounded by timezone: the ABC doc records IDMC/Teradata on EST, Snowflake/Aurora on UTC, and business date
fields **deliberately left un-normalised**. Two contributors may be stamped in different zones.

**Fires in:** rows 4 and 6.

### M11 — Cascade (Z2 as a source)
Joining to an already-built Zone2 SCD2 table makes that table's timeline an input to this one. Two
consequences: this job cannot run until that table is fully and correctly loaded for the run, and if that
table is later retro-split (M2), **every target built on top of it needs rebuilding too**.

**Fires in:** row 7.

---

## 5. Scenario detail

### Row 1 — H2 + H2 *(problem in both worlds)*
The transcript scenario, worked in `scenario_screenshot.png`.
**Fires:** M1, M2, M3, M6, M7, M8.
Both contributors are bi-temporal and business-timed, so the clocks agree. This is the cleanest of the
problem cases despite being the one that triggered the work.

### Row 2 — H2 + C2 *(the divergence)*
**Q1b:** one contributor. The existing driving-table pattern works. Nothing to build.
**Q1a:** two contributors, and the C2 side is valid-time only with no transaction history.
**Fires:** M1, M2, M3, M6, M7, **M4, M5**.

M5 is the reason this row is worse than row 1 rather than merely equivalent. With no transaction-time history
on the C2 side, a removed version leaves no trace and no delta signal. The target keeps serving a version the
source no longer believes in, and no run will ever notice.

### Row 3 — C2 + C2
**Q1b:** zero contributors. The target is SCD2 but nothing supplies a timeline — dates would have to come
from the load date. Probably already a solved pattern; needs confirming.
**Q1a:** two contributors, both valid-time, neither with transaction history. Same as row 2 but with M4/M5
exposure on **both** sides.

### Row 4 — H2 + H1
**Fires:** M1, M2, M3, M6, M7, **M10**.
Problem in both worlds, and the clock mismatch is the dominant issue rather than the splitting. Worth
deciding as policy before writing any SQL — see §6.

### Row 5 — H1 + H1
**Fires:** M1, M2, M3, M6, M7.
Both ingest-timed, so internally consistent. The target's effective dates mean "when we learned", uniformly.
That is defensible as long as it is documented; the trap is a consumer assuming business dates.

### Row 7 — H2 + Z2
**Fires:** M1, M2, M3, M6, M7, **M11**.
Introduces load-ordering dependencies and cascading rebuilds. May deserve its own track.

### Rows 8–10 — one contributor
Handled by the existing pattern: the single contributor is the driving table and sets the target's effective
and expiration dates; everything else is enrichment via left join.

Row 8 carries one caveat — classifying a source as "enrichment only" is a claim about **which columns land
in the target**, which is per-mapping metadata, not a table property. It cannot be determined by looking at
the table alone, which affects how the asset inventory has to be produced.

### Row 11 — zero contributors
Target SCD2 fed only from non-historised sources. Dates must come from the load/ingest date. Standard
warehouse-derived SCD2; the ABC doc's Phase 3 already describes row-expiration computation for Type-2
targets, so this is likely already built. Confirm and drop from scope if so.

### Row 12 — target SCD1
No timeline to maintain. Take the latest version per key from each source and overwrite. **Never a problem,
regardless of how many SCD2 sources feed it.**

---

## 6. Policy options that shrink the problem

Worth putting to Nidhika, because each one removes scenarios rather than solving them:

1. **Bar SCD1-sourced attributes from driving boundaries.** Treat H1 contributors as enrichment only,
   snapped to the nearest contributor boundary. Removes rows 4 and 6 and eliminates M10 entirely. Costs
   some fidelity on ingest-timed attributes.
2. **Require all contributors to a given target to share one clock.** Weaker version of (1) — allows H1+H1
   (row 5) but bars mixing.
3. **Bar C2 from contributing** (relevant only under Q1a) — mandate that any table contributing to target
   effective dates is read from the history bucket. Removes rows 2, 3 and 6, and eliminates M4/M5 exposure.
   Makes Q1a behave like Q1b by policy rather than by accident.
4. **Split `is_del` into two flags or add a reason code** — separating "superseded by correction" from
   "deleted at source". Does not remove a scenario but removes an ambiguity that will otherwise reach
   downstream consumers.

Option 3 is the highest-leverage: it makes the answer to Q1 stop mattering for design, though the answer is
still needed to know whether existing built assets already violate it.

---

## 7. Open questions

| # | Question | Blocks |
|---|----------|--------|
| Q1 | Current bucket: one row per key, or all source versions? | Rows 2, 3, 6 |
| Q2 | Are SCD1 and SCD2 the only target load types in scope? | Completeness of the matrix |
| Q3 | Is row 11 (zero contributors, SCD2 target) already a solved pattern? | Whether it stays in scope |
| Q4 | Is M9 (1:N join grain) in scope here or a separate track? | Scope boundary |
| Q5 | Does Zone1 build history-bucket tables for SCD1 sources (config H1)? | Rows 4, 5, 6 exist at all |
| Q6 | Is Z2-as-source (row 7) in scope? | Whether M11 needs designing |
| Q7 | Inner vs. full outer semantics? | Output of every problem row |
| Q8 | Can sources remove versions, or only add and correct them? | Severity of M5 |
