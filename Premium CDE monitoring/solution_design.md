# Premium CDE monitoring — requirements, decisions and analysis

Status: **requirements under review, no solution locked.** Seven decisions (D1–D7) are open and
must be answered before a design can be finalised. This file is the written record behind
`premium-cde-monitoring-deck.html`; the deck is the review artefact, this is the detail that does
not fit on a slide.

| | |
|---|---|
| **Deck** | `premium-cde-monitoring-deck.html` — 8 slides, opens in a browser, no dependencies |
| **Basis** | Internal design discussion (18 Sep) + Snowflake documentation verified Oct 2026 |
| **Audience** | CDE review |
| **Platform** | Snowflake. ETL already runs inside it via push-down |

> **Every figure in the deck and in §5 of this file is illustrative.** The dollar amounts,
> premium ranges, alert volumes and percentages were chosen to show orders of magnitude and are
> **not measured from LM data**. They should be replaced with real figures before the review if
> anyone has them — the arguments hold at any realistic values, but a placeholder mistaken for a
> claim is worse than no number.

---

## 1. The problem

Premium data loads into Snowflake. Certain columns are designated **CDE** — Critical Data
Elements — meaning that if they are wrong, real damage follows: wrong financial reporting, wrong
regulatory filing, wrong actuarial pricing.

Two controls run today:

| Control | What it does | What it misses |
|---|---|---|
| Null checks on CDE columns | Flags blank values. Informational — does not reject | A value that is present but wrong |
| Balance reconciliation | Proves source total = loaded total | Whether the source value was right to begin with |

Together these prove **the pipeline did its job**: nothing went missing, nothing was corrupted in
transit, nothing arrived blank. They are a guarantee about *transport*.

They prove nothing about whether the numbers make sense.

### Why reconciliation is not enough

A homeowners policy that should be $1,200 a year is recorded as $120,000 — a decimal error, or an
upstream system multiplying by 100. Now run both controls:

- Source sends $120,000. Snowflake loads $120,000. Source total matches loaded total → **reconciliation passes**
- The value is not blank → **null check passes**

Both controls are green. The pipeline worked perfectly and faithfully delivered a wrong number,
which now flows into financial reporting, actuarial models and regulatory filings. Nobody notices
until someone downstream spots a strange figure — possibly at quarter close, possibly never.

> **The requirement in one sentence:** add a check that asks *"is this premium value plausible?"*,
> separate from the existing checks that only ask *"did we receive and load everything?"*

---

## 2. Requirements (R1–R11)

Taken from the 18 Sep discussion. Items marked *to confirm* are our reading of that discussion
rather than something stated outright.

| ID | The monitoring must… | Note |
|---|---|---|
| R1 | Keep the null checks on CDE columns — they flag, they do not reject | |
| R2 | Keep balance reconciliation — source amount = loaded amount | |
| R3 | Flag premiums much higher or much lower than normal — spikes, big drops | **Record-level by nature** — see D7 |
| R4 | Flag trend deviations — latest week vs prior weeks, far from history | **Aggregate by nature** — see D7 |
| R5 | Work at aggregate level, weekly and/or monthly — not record by record | **Conflicts with R3** — see D7 |
| R6 | Run after load, separate from ETL — no trend logic inside ETL | |
| R7 | Run automatically on a schedule — no repeated manual runs | *to confirm* |
| R8 | Produce DQ results, trend metrics and anomaly indicators, kept as history | |
| R9 | Let the team set thresholds — how far off is too far | *to confirm* |
| R10 | Notify the responsible team on a deviation — once D1–D4 are agreed | |
| R11 | Use Snowflake-native first, keep data in Snowflake — Informatica only if needed | |

### Grouped, for reading

- **Don't break what works** — R1, R2. The new check is additive.
- **What to detect** — R3 (implausible values), R4 (trend drift).
- **Where and when** — R5 (grain), R6 (outside ETL), R7 (scheduled).
- **What comes out** — R8 (stored history), R9 (tunable thresholds), R10 (alerts).
- **Built with what** — R11 (Snowflake first).

---

## 3. Decisions still open (D1–D7)

| ID | Decision | Who should answer |
|---|---|---|
| D1 | What counts as an **anomaly** for premium? | Premium / actuarial data owner — **not a technology call** |
| D2 | Which **threshold variables** do we create, and how is each measured against the data? | Data owner + whoever triages alerts |
| D3 | Which **business scenarios** to detect? | Business |
| D4 | **Who is notified**, on which channel? | Operations / governance |
| D5 | Which premium **tables and columns** are in scope? | Data owner. Also settles which arithmetic relationships can be checked — see §6 |
| D6 | **Weekly, monthly**, or both? | Business |
| D7 | Do we check **records, totals, or both**? | Design & data governance |

**Sequencing.** D7 and D1–D3 come first — they are scope and definition. D4 (who is alerted) is
decided last, because it depends on what the alerts turn out to be.

**D7 is new**, raised during review rather than in the original discussion. It exists because R5
and R3 contradict each other: R5 says aggregate only, R3 describes a record-level test. Answering
D7 includes amending R5 to match. The arithmetic behind why this matters is in §5.1.

Only **D1** currently has named options in the deck (slide 4). The rest are stated as questions.

---

## 4. D1 in full — what counts as an anomaly

This is the decision the whole design hangs on, and the one most likely to be answered vaguely if
asked open-endedly. Four named options, so the review confirms a choice rather than inventing one.

### The problem with asking "is $120,000 too much?"

Premium is not one population. A personal auto policy at $800 and a commercial property schedule
at $2M are both entirely normal. "Unusually high" has no meaning until you say **compared to
what**.

### The options

| ID | Compare each premium against… | What that means in practice |
|---|---|---|
| **D1-A** | One limit for all premium | Set it high and the mis-key passes unnoticed; set it low and the whole commercial book alerts every run. **Neither setting works.** |
| **D1-B** | A limit per product line | The mis-key is caught, commercial stays quiet. Needs a limit agreed per product line, kept current as the book changes. |
| **D1-C** ★ | A peer group — product + coverage + state + term | Tightest detection, fewest false alarms. Each group's limits come from its own history rather than being hand-set, so they stay current. |
| **D1-D** | A ratio, not an amount — premium ÷ exposure, e.g. rate per $1,000 of cover | The most stable measure, and the only one the business can state a defensible band for. Needs an exposure value on the record — depends on D5. |

★ = recommended for the POC. **D1-D is the target state** once exposure availability is confirmed.

### Why D1-A fails in both directions at once

A single global limit must be set high enough not to flag legitimate commercial property (~$2M).
At that setting a $120,000 premium on a *homeowners* policy sails through — a false negative. Set
it low enough to catch that (~$50k) and every commercial policy above $50k alerts on every run — a
flood of false positives. There is no value that does both. The deck's slide 4 chart shows this on
a log scale.

A related trap, if the band is computed from the live table each run: as bad data accumulates the
band widens, and the control quietly stops catching anything. Any statistical baseline should come
from a **frozen, blessed historical window** held in a reference table, not recomputed from
whatever is currently in the table.

### What "peer group" means — the four attributes (D1-C)

This did not fit on the slide. The peer group is the set of policies a given premium is compared
against, instead of comparing it to all premium. Each attribute narrows the group to policies that
*should* look alike:

| Attribute | What it is | Why it has to be in the key |
|---|---|---|
| **Product** | Line of business — personal auto, homeowners, commercial property, workers' comp | The single biggest driver of premium scale. An $800 auto premium and a $2M property premium are not comparable in any useful sense. |
| **Coverage** | Which cover the premium is for — on homeowners: dwelling, personal property, liability, medical payments | Within one product these differ by an order of magnitude. Lumping them together widens the band until it catches nothing. |
| **State** | The state the policy is written in | Rates are filed and approved per state. Hurricane-exposed states vs low-risk states differ several-fold for identical cover. Mix them and the band must be wide enough for the worst, so errors elsewhere walk through. |
| **Term** | The period the premium covers — 6-month vs 12-month | A 6-month auto policy is roughly half the premium of a 12-month one for the same risk. Without this you would flag every 6-month policy as suspiciously low. |

The group key is a composite: `(product_line, coverage_code, state, term_months)`. For each
combination you derive the normal range from **that combination's own history**, then test each new
premium against its own group's range.

**Minimum group size.** The more attributes in the key, the tighter the band — but the fewer
policies land in each group. A group with a handful of policies in history cannot produce a
meaningful range. A minimum group size is needed, with a documented fallback to a coarser grouping
(drop term first, then state) when a combination is too thin. **This rule is not yet specified.**

**Two further candidate attributes** worth putting to the data owner: **new business vs renewal**
(renewals cluster far tighter than new business) and **policy form / package**.

---

## 5. Analysis — points raised in review

These are architectural observations made while cross-examining the deck. Some are reflected in
the deck, some are deliberately parked (§6).

### 5.1 R3 and R5 contradict each other — D7

R5 says monitor at aggregate level, "not record by record". But the motivating scenario in §1 is a
*single record* being wrong, and R3 ("flag premiums much higher or much lower than normal") is a
record-level test by its own wording.

The arithmetic, using illustrative figures:

| | |
|---|---|
| Weekly premium total | $50,000,000 |
| One policy, should be | $1,200 |
| Recorded as | $120,000 |
| Overstated by | $118,800 |
| New weekly total | $50,118,800 |
| **Movement** | **+0.24%** |
| Normal week-to-week variation on renewal timing alone | **±4%** |

The error is roughly **17× smaller than the ordinary noise it hides inside**. No trend check on a
total will ever separate the two. Aggregate monitoring is also blind to **offsetting errors** —
one policy +$1M and another −$1M nets to zero in any total.

Conversely, record-level checking alone misses slow drift where every individual record looks
entirely plausible.

**Conclusion:** both grains are required, with different mechanisms. R5 needs amending to match
whatever D7 decides. Also unresolved: when an aggregate alert fires, there is currently no
drill-down path to the contributing records, which makes such an alert hard to action.

### 5.2 Detection only, or gating?

DMFs and expectations are **observational**. They measure on a schedule and can notify. They do
**not** reject or quarantine rows. If a bad premium lands on Monday and a weekly check runs on
Sunday, that value sat in actuarial extracts and downstream reporting for six days.

For a *critical* data element, "detect or stop?" is a requirement nobody has stated. Most CDE
frameworks want at least a severity-1 circuit breaker. R6 does not prevent this — "no trend logic
in ETL" is compatible with "deterministic validity checks run as a gating post-load step, still
inside Snowflake".

**Not currently a numbered decision.** Worth adding if the review agrees it is open.

### 5.3 Premium gets restated — which date do we monitor on?

Premium is not written once and left alone. Endorsements change it mid-term, cancellations reverse
it, audits true it up months later. So "last month's total premium" is **not a fixed number** — it
moves as adjustments arrive.

A trend check comparing this month to last month will see last month change and flag it as a
deviation. The design has to choose whether it monitors on **transaction date** or **accounting /
booking date**; the two give different answers and both are legitimate for different purposes.

**Not mentioned anywhere in the requirements. This will bite in the first month of running.**

### 5.4 Alert volume is a design input, not an output

A control that raises 250 alerts a week is ignored within a month — and still shows green on a
governance report. This is the most common way a data quality programme fails.

The method that avoids it, in order:

1. Agree an **alert budget** with the team who will triage — say no more than 10 a week to begin.
2. Run the check over **6–12 months of history with alerting off**, and count what it would have raised.
3. **Move the threshold** until that count matches the budget.
4. Review monthly and tighten as confidence grows.

Illustrative sensitivity trade-off for a single check on a single product line:

| Setting | Alerts/week | Share that are genuine | Outcome |
|---|---|---|---|
| Flag top 5% | ~250 | ~4% | Switched off within a month |
| Flag top 1% | ~50 | ~16% | Still too noisy |
| Tuned to budget | ~6 | ~67% | Workable |
| Extremes only | ~1 | ~100% | Trusted, but misses most moderate errors |

The end state is **severity tiers** — extreme → stop the line, moderate → email, mild → dashboard
only — but that cannot be configured until D4 settles who is notified on which channel.

**Parked** — see §6.

### 5.5 Requirements that are missing

R1–R11 has no answer for any of the following. None are currently numbered decisions.

- **Severity tiering** of a failed check — informational vs warning vs stop-the-line
- **Alert suppression / deduplication** — a sustained defect must not alert daily forever
- **Known-exception allowlist with expiry** — a genuinely large new commercial account *will* fire; without a documented suppression path the team mutes the whole control
- **Triage drill-down** — from an aggregate alert to the contributing records
- **Ownership and SLA** — who triages, within what window, escalating to whom
- **Control effectiveness measurement** — precision (what share of alerts were real) and recall (defects found later that the control missed). The first thing an auditor asks
- **Remediation path** — detection without a correction or restatement process is theatre
- **Backfill / replay behaviour** — what happens on a historical reload; does it re-trigger every alert

### 5.6 Informatica CDGC — the right reason to set it aside

The deck sets CDGC profiling aside because "profiles must be re-run repeatedly". That reason is
weak — CDGC profiling *can* be scheduled. The better arguments for Snowflake-native are: no data
movement, results land where the trend history must live anyway, one less licensed component in
the control path, and lineage plus alerting already present.

The honest argument *for* CDGC is governance: if LM's CDE framework requires controls to be
**catalogued** in CDGC, the answer is not "Snowflake instead" but **"Snowflake executes, CDGC
records"**. Worth confirming with whoever owns the CDE framework.

---

## 6. Deliberately parked

Raised in review, consciously deferred. Recorded here so they are not silently lost.

### Arithmetic checks — waiting on D5

There are two fundamentally different ways to test a premium value:

- **Arithmetic** — test the data against a rule true *by definition*. A policy's total premium must equal the sum of its coverage premiums. If dwelling $820 + liability $240 + medical $60 = $1,120 but the record says $1,450, the record is wrong. No threshold, no false alarms, buildable immediately. Only catches errors that break an internal relationship.
- **Statistical** — test a value against what similar values look like. Needs D1 and a threshold, always produces some false alarms, cannot be built until the business decides. Catches errors that are internally consistent but implausible.

Arithmetic checks are a **baseline rather than a choice**, so they are not framed as a decision.
The specific rules that apply depend on which tables and columns are in scope, so the question list
below is held until **D5** is answered:

- Does policy total premium = sum of coverage premiums in our data model?
- Is written premium = earned + unearned available on the same table?
- Must cancellations carry a negative premium, or are they a separate transaction type?
- Is there a filed rate band we can check premium ÷ exposure against?
- Does term premium × (12 ÷ term months) = annual premium within tolerance?

Each one the business confirms becomes a check buildable with **no further decisions** — which is
why they are worth collecting as soon as D5 lands.

### Threshold strictness and alert volume

§5.4 in full. Real, but it is a **calibration** concern rather than what D2 means. D2 is about
which threshold variables exist and how each is measured. No slide; revisit once D2 itself is
answered.

### A D2 options slide

Candidate threshold variables, if the review wants the same named-options treatment D1 got: weekly
total premium by product line; average premium per policy; policy and transaction counts; premium
per exposure unit; period-over-period % change; null rate on CDE columns; p95 / p99 of the
distribution. Each would need what it catches and what baseline it is measured against. **Not
built** — offered, not requested.

---

## 7. Snowflake findings

Verified against Snowflake documentation in October 2026. The deck marks several of these as "to
check"; most are now answerable, and one feature the deck predates materially improves the design.

### Confirmed

| Area | Finding |
|---|---|
| **Edition** | Data quality monitoring and DMFs require **Enterprise Edition**. Not available in trial accounts |
| **Expectations** | A documented feature. A pass/fail rule on a DMF's returned value, set via SQL or Snowsight. `DATA_METRIC_FUNCTION_EXPECTATIONS` view |
| **Notifications** | Documented. Fire on an expectation violation **or** an anomaly detection. Email or webhook (Slack, Teams, PagerDuty) |
| **Snowsight** | A per-object quality monitoring view plus a centralized data quality dashboard |
| **Results history** | `SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS`. Requires the `DATA_QUALITY_MONITORING_VIEWER` or `_ADMIN` application role |
| **Scheduling** | `DATA_METRIC_SCHEDULE` supports `N MINUTE` (minimum **5**), `USING CRON …`, or `TRIGGER_ON_CHANGES`. Weekly/monthly via cron is supported |
| **DMF anomaly detection** | Covers volume (`ROW_COUNT`) and `FRESHNESS`. Needs ~2 weeks of DMF history for weekly seasonality; trains on up to 60 days |
| **Billing** | Serverless, itemised under a "Data Quality Monitoring" line. Only **scheduled** runs are billed — calling a DMF in a `SELECT` is not |

### `WITHIN GROUP` — the feature the deck predates

Went **GA in May 2026** (release 10.16). Associates a DMF with a table so it is evaluated
separately per distinct combination of grouping columns:

```sql
ALTER TABLE <premium_table>
  ADD DATA METRIC FUNCTION <dmf> ON (<col>)
  WITHIN GROUP (product_line, coverage_code, state, term_months)
  [GROUP LIMIT <n>];
```

This is exactly the peer-group lever D1-C needs, natively. `GROUP LIMIT` accepts 1–1000, default
1000. Combinable with the existing `FILTER` clause.

**Not supported with:** `FRESHNESS`, `REFERENTIAL_INTEGRITY_COUNT`, anomaly detection,
schema-level associations, or custom DMFs using CTEs, `UNION` / `UNION ALL`, `JOIN`, `DISTINCT`,
**or window functions**. That last exclusion matters — most peer-group outlier formulations reach
for window functions, so the peer-group logic must either be expressible as a plain aggregate
under `WITHIN GROUP`, or live outside DMFs in a scheduled task. **Test this in week one.**

### Constraints that could block the design

1. **Object types.** DMFs cannot be set on dynamic tables, external tables, hybrid tables or streams — regular tables (and views) only. **If the premium CDE layer is dynamic-table-based, the deck's Option 2 does not work as drawn.** This is the single most important thing to verify on LM's account.
2. **One schedule per table.** All DMFs on a given table share a single schedule, so a cheap daily check and an expensive weekly check cannot both run on the same table. Different cadences force different views.
3. **Custom DMF limits.** Must return `NUMBER`. Columns must be in the same table (a multi-table argument form exists for referential integrity). Cannot be used as an argument to `SYSTEM$DATA_METRIC_SCAN`.
4. **Scale.** 50,000 DMF-to-object associations per account. `GROUP LIMIT` caps at 1000 groups — product × coverage × state × term could exceed that at LM's scale.
5. **Cost.** A custom DMF on a large premium fact scans it on every scheduled run. Scope with the association-level `FILTER` clause, or associate to a thin view over the latest load window.
6. **Retention.** `DATA_QUALITY_MONITORING_RESULTS` retention is finite. If R8 means "history for audit", **persist a copy into LM-owned tables** — do not hang a CDE audit trail off a system view.

### ML anomaly detection (`SNOWFLAKE.ML.ANOMALY_DETECTION`)

| | |
|---|---|
| Minimum data | **12 rows per series** for the real algorithm. With 2–11 it returns a *naive* result where every prediction equals the last observed value — worse than useless here |
| Sensitivity | `prediction_interval`, default `0.99` (~1% flagged). **Lower** it for stricter detection |
| Multi-series | Supported via `SERIES_COLNAME` — e.g. one series per product line |
| Algorithm | Cannot be chosen or tuned. Trend and seasonality are inferred, not overridable |
| Compute | Runs on **your warehouse**, not serverless — so its cost lands differently from DMFs |
| Edition | Not stated as Enterprise-only the way DQ monitoring is. **To verify on LM's account** |

**The deck understates the data requirement.** The 12-point minimum is real but is not the binding
constraint — **seasonality is**. Premium has strong *annual* cycles (Jan 1 commercial renewals,
seasonal lines). Learning yearly seasonality needs roughly **2–3 years of weekly points**, not 12
weeks. With 12 monthly points you have exactly one annual cycle and cannot separate seasonality
from trend at all.

Worse, the deck's own caveat — the model cannot flag anomalies inside its training data — is fatal
for bootstrapping, because LM's premium history almost certainly already contains the defect class
being hunted. Training on it teaches the model those defects are normal. A **curated, blessed**
training window is required.

**Recommendation: defer ML to a later phase.** A trailing-median tolerance rule ("weekly new-business
written premium by product line within ±X% of the trailing 8-week median") will outperform it in
year one and, critically, is **explainable** — which for a CDE control is not optional.

---

## 8. The POC

### The goal needs restating

The deck's next step reads *"build and test the premium outlier check on LM's account"*. That is an
activity, not a goal — it does not say what question the POC settles or how you would know it
succeeded. Three candidate goals, producing three very different POCs:

| Goal | The question it answers |
|---|---|
| Feasibility | Can Snowflake do this at all? |
| Fitness | Can Snowflake do this well enough *for premium data specifically*? |
| **Value** | If we build it, will it catch real defects, and will people trust the alerts enough to act? |

The deck implicitly aims at **feasibility**, which is the least useful — it is largely answerable
from documentation without building anything (see §7). The real risk is **value**: that the control
is built, floods, and is ignored by week three.

> **Proposed goal:** prove we can produce a premium plausibility check whose alerts are
> trustworthy enough to act on — and put a **number** on how trustworthy.

### Proposed scope

- **One** premium table, 2–3 CDE columns, **one** product line
- Build the D1-C peer-group check plus whichever arithmetic checks D5 unlocks (§6)
- Results persisted into LM-owned tables, one alert route wired up
- **Out of scope:** ML anomaly detection, full CDE coverage, Informatica integration
- Timebox: 2–3 sprints

### Success criteria — the part currently missing

Two validations, both producing numbers:

1. **Defect injection on a zero-copy clone.** Plant a 1000× value, a sign flip, a component mismatch, a 20% volume drop. Measure which checks catch which → **recall**.
2. **Backtest over 6–12 months of real history.** Count the alerts the check *would* have raised and have the business adjudicate a sample as true or false positive → **precision, before alerting is switched on**.

Without (2) there is no defensible basis for choosing a threshold, and no way to tell the review
whether the control is worth operating.

---

## 9. To verify before build

| | Why it matters |
|---|---|
| **Object type of the premium CDE layer** | DMFs do not work on dynamic / external / hybrid tables. Blocking — §7 |
| LM account is on **Enterprise Edition** | Required for DQ monitoring at all |
| Which **system DMFs** are available on LM's account | Determines how much is built vs configured |
| `WITHIN GROUP` behaviour with the intended peer-group logic | The window-function exclusion may force a different shape — §7 |
| Group count for product × coverage × state × term vs `GROUP LIMIT` 1000 | May force a coarser key |
| Whether **exposure** is available on the premium record | Gates D1-D |
| How much **clean, curated** weekly premium history exists | Gates any ML approach; 12 weeks is not enough — §7 |
| ML anomaly detection edition and release status on LM's account | |
| Whether LM's CDE framework requires controls catalogued in **CDGC** | Changes the Snowflake-vs-Informatica question into a hybrid — §5.6 |
| Premium table size and clustering | Drives serverless cost of scheduled DMFs |

---

## 10. Still open on the problem side

Beyond D1–D7, these have no owner and no decision ID yet:

- Detect-only or gating, and whether quarantine is expected for a CDE (§5.2)
- Transaction date vs accounting date for trend monitoring, given restatement (§5.3)
- Minimum group size and the fallback hierarchy for D1-C (§4)
- The eight missing requirements in §5.5 — severity, suppression, exceptions, drill-down, ownership, effectiveness measurement, remediation, backfill
- Whether new-business-vs-renewal and policy form belong in the peer-group key (§4)

---

## 11. Deck change log

The deck began as a 7-slide artefact proposing a Snowflake direction. Changes made during this
review, and why:

| Change | Reason |
|---|---|
| **Added** a "Decisions needed" section with named options per decision | Open questions put to a review come back partial or contradictory. Options with a marked recommendation get a confirmable answer |
| **Added** D7 (records / totals / both) | R3 and R5 contradict each other and nothing surfaced it |
| **Added** D8 (which families of check), then **removed** it | Arithmetic checks are a baseline rather than a choice. The rule list depends on D5 and is parked in §6 |
| **Added** then **removed** a decision-ask roadmap slide | The decision set is now small enough not to need a summary slide |
| **Added** then **removed** a D7 grain slide | R3 and R4 already imply both grains; the question stays in the decision table rather than getting a slide |
| **Added** then **removed** a D2 strictness slide | D2 is about which threshold variables exist, not how strict one threshold is. Content parked in §5.4 |
| **Reworded** D2 on slide 3 | To match what D2 actually means in the source discussion |
| **Corrected** the worked example to use slide 2's own figure | Two different mis-key amounts were in circulation |
| Cover, agenda, sidebar, numbering | Kept in sync throughout |

Final state: **8 slides**, one decision slide (D1), D1–D7 open on slide 3.
