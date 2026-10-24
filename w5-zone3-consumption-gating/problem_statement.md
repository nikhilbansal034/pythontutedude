# Zone 3 consumption publication gating — problem statement

**Status**: baseline, agreed and frozen. Requirements phase closed; solution phase not started.
Section 6 holds working positions that are **not** part of the freeze.
**Date**: 2026-10-24
**Participants**: Prateek Singh, Nikhil Bansal, Idhanta Kakkar, Nidwika Vedanaparthi

## Provenance

Derived from the 24-Oct-2026 design discussion, as synthesised in
`sources/RE Discuss code freeze activities.msg` (a Copilot summary of the meeting transcript),
then refined over five rounds of review.

Three deliberate exclusions, all confirmed:

- **Prior option analysis is not an input.** The earlier consumption-layer option analysis
  (referenced in the source as "pages 37-45") is excluded. This problem is approached fresh.
- **The two reference decks are not an input.** `sources/POC02_Recommendation_and_Design 1.html`
  and `sources/POC05 - Same-Name Clone Refresh for Consumption - Deck.html` are retained as
  background only. They address neighbouring problems and predate this requirement; no
  requirement or recommendation here derives from them.
- **The meeting subject is irrelevant.** The discussion was a tangent inside an unrelated
  code-freeze review. There is no connection between the two.

---

## 1. Problem statement

> The visible state of a consumption object currently changes as a **side effect of upstream
> loading**. It must instead change only as an **explicit, controlled publication event**.

Zone 3 consumption objects are read continuously by business and reporting users while their
upstream inputs are refreshed by batch. Because a consumption object reflects its upstream state
immediately and continuously, a reader arriving mid-batch can observe a state that was never a
valid published version — part of the current cycle's data combined with part of the previous
cycle's.

The consequence is that **reporting can be analytically wrong while every individual source
object is itself valid**. Nothing tells a reader whether they are looking at a complete version
or a half-formed one, and nothing prevents a failed or abandoned cycle from being exposed.

What is required is a boundary between *loaded* and *visible*: a defined set of objects holds one
published state, that state is replaced wholly or not at all, and its replacement is a decision
rather than a consequence.

---

## 2. Scope

**In scope**

- Zone 3 / consumption-layer objects — tables and views
- What consumers may observe, and when
- The governance and security posture of a consumption object across a publication
- The identity that performs publication
- Applicability across the existing consumption estate

**Out of scope**

- How Zone 2 and upstream loads work internally
- Consumer-facing historical / as-of access to prior published states
- Any specific platform mechanism — deferred to the solution phase

---

## 3. Model and vocabulary

Four entities. The distinction between the first two is the one that most often gets collapsed,
and collapsing it produces a broken design.

| Entity | Definition | Role |
|---|---|---|
| **Consumption object** | A table or view in the consumption layer | **Unit of governance.** Tags, masking policies and grants are bound here, never at domain level. |
| **Consistency group** | The full set of objects a report depends on, including those it reaches through views | **Unit of visibility and of publication.** Publishes atomically. |
| **Batch** | The orchestration unit that refreshes a set of objects, via one or more jobs per object | **Unit of execution.** |
| **Publication** | The act of replacing the visible state of a consistency group | The controlled event the whole requirement exists to create. |

---

## 4. Settled decisions

| # | Decision | Consequence |
|---|---|---|
| **D1** | The unit of governance is the object | Tags, masking and grants live on the objects themselves. A domain is a batch, not a governed entity. |
| **D3** | The unit of visibility is the consistency group | Objects a report depends on become visible together. Cross-group skew is governed by R4. |

D2 and D4 are no longer settled. They are carried in section 6 as working positions, under their
original IDs.

---

## 5. Requirements

Each is written to be falsifiable — a proof-of-concept can pass or fail it.

### A — Published-state semantics

| # | Requirement |
|---|---|
| **R1** | While an object's inputs are being refreshed, its consumers continue to see the previously published state, unchanged. |
| **R2** | A publication makes the entire new state of an object visible or none of it. No reader can observe a mixture of the previous and the new state of the same object. |
| **R3** | All objects in a consistency group become visible together, or none of them do. |
| **R4** | Publishing one consistency group must not cause any other consistency group to become internally inconsistent. |
| **R5** | Once first published, a consumption object is continuously resolvable. At no instant does it fail to exist, return empty, or return a structurally invalid result. Before its first publication — at go-live, or when a new object is added — nothing is visible. |
| **R6** | Publication does not cancel, error, or block in-flight consumer queries. |
| **R7** | The visible state changes **only** when publication is invoked. Completion of upstream loading does not, by itself, change what consumers see. |

### B — Gating, failure and override

| # | Requirement |
|---|---|
| **R8** | Normal publication of a consistency group occurs only after every job that refreshes its members has completed successfully for the cycle. |
| **R9** | If any job in the group's dependency set fails or does not complete, no publication occurs. Consumers remain on the previously published state until the next publication, however long that takes. There is no timed auto-release of a partial state. |
| **R10** | A second, explicitly authorised path exists to publish the available state despite incomplete upstream processing. |
| **R11** | Every publication — normal or override — is attributable: what was published, when, by whom or by what, and under which path. |
| **R12** | If an override publication (R10) is followed by the outstanding jobs completing successfully, the complete state of the cycle is then published through the normal path. An override does not close the cycle. |
| **R13** | If a later cycle completes while an earlier one is still held (R9), the later cycle is published. The held cycle is not published separately. |

### C — Governance and security

| # | Requirement |
|---|---|
| **R14** | After publication, each object carries the object-level and column-level tags, masking behaviour and grants currently defined for it. Protection that has not changed is preserved; protection that governance has changed since the previous publication is applied as changed. |
| **R15** | Publication must not cause masked, hashed or otherwise transformed values to be **persisted as though they were real values**. Published data is the real data, with protection applied at read time as intended. |
| **R16** | There is no window in which the new state exists and is reachable while its sensitive columns lack their intended protection. |
| **R17** | A column present in the new state but absent from the previous one must not become consumer-visible without its intended protection. |

### D — Platform and execution

| # | Requirement |
|---|---|
| **R18** | Publication, and the governance operations it entails, are executable by the identity that runs the batch, using privileges that identity can legitimately be granted. |
| **R19** | For any consumption object it is determinable which published version consumers are currently seeing, and when it was published. |

### E — Estate and lifecycle

| # | Requirement |
|---|---|
| **R20** | The mechanism is applicable across the consumption estate **without requiring existing view logic to be redeveloped as new ETL per object**. Development effort is a first-class requirement, not a secondary consideration. |
| **R21** | Publication is repeatable every cycle, indefinitely, without accumulating manual steps per object per cycle. |
| **R22** | The membership of every consistency group — the objects whose states must agree, and the jobs that refresh them — is known and kept current as reports and objects change. An incorrect membership silently invalidates R1, R2, R3 and R4. |

### F — Non-functional (to be quantified)

| # | Requirement |
|---|---|
| **R23** | Publication completes within the batch window at production volume. |
| **R24** | Storage and compute overhead of keeping the published state visible while its replacement is prepared is bounded and known. |

---

## 6. Working positions — not frozen

Carried into the solution phase, to be confirmed or overturned there. None of them is part of the
freeze.

### Positions

| # | Position | What it would mean |
|---|---|---|
| **D2** | No completion signal is reintroduced | Publication is released by orchestration dependency as the batch's terminal step, and does not depend on a stored validation marker or on querying stored completion state. The removed validation-date concept stays removed, in any store. Orchestration run state is not such a signal. |
| **D4** | Views inherit consistency; they are not published | Ground objects — the tables beneath the views — hold published state. A view is a query with no state of its own, so it inherits consistency from its published inputs, and its dependency closure forms part of the consistency group. If this holds, the gated population is the ground objects beneath the view estate, not the view estate itself, and the view estate is not physicalised. |

How group membership (R22) is derived is also a solution-phase question. The working view: a
report's objects are **declared**, as a report resides in the BI layer and not in platform
metadata; a view's underlying objects and an object's jobs are **derivable** from platform metadata
and orchestration configuration.

### Assumptions

Load-bearing, and recorded rather than embedded.

| # | Assumption | Risk if false |
|---|---|---|
| **A1** | The batch boundary and the report dependency closure coincide — a batch runs for a domain or report. | If a report spans batches, or two reports in different batches share an object, R4 becomes materially harder to satisfy. |
| **A2** | Publication latency for a group is `max(all its jobs)`. A single straggler delays the whole group. | Accepted consequence of R3 and R9, not a defect. Requires alerting. |
| **A3** | Skew *between* consistency groups is acceptable. Reports in different groups may legitimately show different cycles, subject to R4. | — |
| **A4** | Reporting consumers read consumption objects through a path that respects the published state and does not bypass it. | A consumer reading ground objects directly defeats every guarantee here. |

---

## 7. Dependencies and parked items

| # | Item | Owner | Note |
|---|---|---|---|
| **P1** | Object lifecycle legitimacy — whether objects created at runtime by a service account are classed as orphans and reaped | Raja / Anoop (platform) | Parked as secondary; out of this scope. **Constrains any option that creates objects at runtime; does not constrain options that only manipulate pre-existing objects.** Keep visible when evaluating the option space. |

Note the split: **R18** (can the batch identity *execute* publication) stays in scope and is ours.
**P1** (are the resulting objects *legitimate* under platform lifecycle policy) is parked and is
the platform team's.

---

## 8. Open operational policy

Not architecture, but they must be answered before build. All follow from R9.

| # | Question |
|---|---|
| **C1** | Alerting threshold for a batch held open by a slow or hung job — without one, the first signal is a business user asking why yesterday's numbers are still showing. |
| **C2** | Retry window: a job fails, is re-run and succeeds. Does the batch stay active and then publish, however late? |
| **C3** | Permanent-failure exit: if a job cannot be made to succeed, does the batch close unpublished (R9), or is R10's override invoked? Who decides, and on what timeframe? |
| **C4** | Authorisation for R10: who may authorise an override publication, and what record is required. |

---

## 9. What this statement deliberately does not do

- It names **no mechanism**. Every requirement is stated in terms of observable behaviour so
  that the option space can be evaluated against it without prejudice.
- It carries **no inherited recommendation**. No option is favoured or excluded here.
- It does not freeze its working positions. Section 6 records them so that the solution phase
  tests them rather than assumes them.
- It does not resolve R4. R4 is stated as a constraint the solution must satisfy for whatever
  number of batches the business operates; it is not a decision to be taken in advance.

---

## 10. Next step

Evaluate the option space against R1-R24, and test the working positions in section 6, with R4,
R15, R20 and R22 as the discriminating requirements — each is capable of eliminating an otherwise
attractive option on its own.
