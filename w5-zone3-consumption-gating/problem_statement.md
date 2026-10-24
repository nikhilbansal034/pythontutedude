# Zone 3 consumption publication gating — problem statement

**Status**: baseline, agreed. Requirements phase closed; solution phase not started.
**Date**: 2026-10-24
**Participants**: Prateek Singh, Nikhil Bansal, Idhanta Kakkar, Nidwika Vedanaparthi

## Provenance

Derived from the 24-Oct-2026 design discussion, as synthesised in
`sources/RE Discuss code freeze activities.msg` (a Copilot summary of the meeting transcript),
then refined over four rounds of review.

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
- Reintroducing a data-level validation or completion marker, in any store
- Consumer-facing historical / as-of access to prior published states
- Any specific platform mechanism — deferred to the solution phase

---

## 3. Model and vocabulary

Four entities. The distinction between the first two is the one that most often gets collapsed,
and collapsing it produces a broken design.

| Entity | Definition | Role |
|---|---|---|
| **Consumption object** | A table or view in the consumption layer | **Unit of governance.** Tags, masking policies and grants are bound here, never at domain level. |
| **Consistency group** | The closure of ground objects a report depends on | **Unit of visibility and of publication.** Publishes atomically. |
| **Batch** | The orchestration unit that refreshes a set of objects, via one or more jobs per object | **Unit of execution.** Assumed to coincide with a consistency group (A1). |
| **Publication** | The act of replacing the visible state of a consistency group | The controlled event the whole requirement exists to create. |

**Ground objects hold published state. Views do not.** A view is a query over ground objects and
has no state of its own. Views are therefore **not published** — they inherit consistency from
their published inputs, and their dependency closure forms part of the consistency group. This is
what keeps the problem tractable: the gated population is the ground objects beneath the view
estate, not the view estate itself.

---

## 4. Settled decisions

| # | Decision | Consequence |
|---|---|---|
| **D1** | The unit of governance is the object | Tags, masking and grants live on ground objects. A domain is a batch, not a governed entity. |
| **D2** | No completion signal is reintroduced | Publication may not depend on a stored validation marker or on querying completion state. Orchestration run state is not such a signal (see R8). |
| **D3** | The unit of visibility is the consistency group | Objects a report depends on become visible together. Cross-group skew is governed by R4. |
| **D4** | Views inherit consistency; they are not published | Resolves the view estate without physicalising it. |

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
| **R5** | A consumption object is continuously resolvable. At no instant does it fail to exist, return empty, or return a structurally invalid result. |
| **R6** | Publication does not cancel, error, or block in-flight consumer queries. |
| **R7** | The visible state changes **only** when publication is invoked. Completion of upstream loading does not, by itself, change what consumers see. |

### B — Gating, failure and override

| # | Requirement |
|---|---|
| **R8** | Publication is a terminal step of the batch, released by orchestration dependency on the jobs that refresh the group's members. It does not query stored completion state to decide whether to proceed. |
| **R9** | If any job in the group's dependency set fails or does not complete, no publication occurs. Consumers remain on the previously published state indefinitely. There is no timed auto-release of a partial state. |
| **R10** | A second, explicitly authorised path exists to publish the available state despite incomplete upstream processing. |
| **R11** | Every publication — normal or override — is attributable: what was published, when, by whom or by what, and under which path. |
| **R12** | The immediately preceding published state of a consistency group can be restored as the visible state by an operator action. One step back only; not retained beyond the next cycle; not a consumer-facing capability. |

### C — Governance and security

| # | Requirement |
|---|---|
| **R13** | After publication, each object carries the same effective object-level and column-level tags, masking behaviour and grants as it did before. |
| **R14** | Publication must not cause masked, hashed or otherwise transformed values to be **persisted as though they were real values**. Published data is the real data, with protection applied at read time as intended. |
| **R15** | There is no window in which the new state exists and is reachable while its sensitive columns lack their intended protection. |
| **R16** | A column present in the new state but absent from the previous one must not become consumer-visible without its intended protection. |
| **R17** | Existing governance objects — policies, tags and their definitions — are not modified by the mechanism. |

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
| **R22** | The dependency graph is reliably derivable and maintained at all three levels: `report → objects`, `view → ground objects`, `object → jobs`. Report-to-object edges must be **declared**, as a report resides in the BI layer and not in platform metadata; view-to-ground and object-to-job edges are **derivable** from platform metadata and orchestration configuration. An incorrect graph silently invalidates R1, R2, R3 and R4. |

### F — Non-functional (to be quantified)

| # | Requirement |
|---|---|
| **R23** | Publication completes within the batch window at production volume. |
| **R24** | Storage and compute overhead of retaining a previous published state is bounded and known. |

---

## 6. Assumptions

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
- It does not resolve R4. R4 is stated as a constraint the solution must satisfy for whatever
  number of batches the business operates; it is not a decision to be taken in advance.

---

## 10. Next step

Evaluate the option space against R1-R24, with R4, R14, R20 and R22 as the discriminating
requirements — each is capable of eliminating an otherwise attractive option on its own.
