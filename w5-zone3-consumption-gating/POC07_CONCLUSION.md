# POC07 — Zone 3 consumption publication gating
### Requirement → approach → evidence → conclusion

Single document. Supersedes all earlier conclusion drafts.
Status as at **27 October 2026**.

---

## 1. The problem

- Reporting users can currently read Zone 3 consumption objects **while an upstream batch is still running**.
- What they see is a **partially refreshed, internally inconsistent dataset** — some objects on last night's data, some on tonight's.
- It fails **silently**. No error, no warning. A report renders, the numbers are wrong, and nothing says so.
- A second, quieter failure sits alongside it: if protection is not reapplied correctly when an object is republished, **PII can become readable with every check green**.

---

## 2. Scope

**In scope**
- Zone 3 / consumption-layer objects — tables and views
- What consumers may observe, and when
- The governance and security posture of an object **across a publication**
- The identity that performs the publication

**Out of scope**
- How Zone 2 and upstream loads work internally
- Consumer-facing as-of access to prior published states
- **Concurrency and load testing** — Nikhil, 27 Oct
- **R6** (publication must not block in-flight queries) — Nikhil, 27 Oct
- **N-1 / N-2 tag lineage** — new requirement, needs its own governance process
- **Liquibase deployment mechanics** — acknowledged as the carrier for the tag rule in §8, not built here

**Bounding assumptions**
- **A5** — batches are strictly serialised; a failed batch is fixed before the next runs
- **A4** — consumers read through the published path and do not bypass it

---

## 3. The requirement

- **29 requirements**, stated as *observable behaviour* and naming **no mechanism** deliberately, so options could be judged without prejudice.
- Split in two, and the problem statement is explicit that they are **not separable in delivery**:

| | **Part A — publication gating** | **Part B — governance continuity** |
|---|---|---|
| Requirements | R1–R13, R15, R19, R22, R29 | R14, R16, R17, R18, R25–R28 |
| Fails | **Visibly** — wrong numbers on a report | **Silently** — exposed data, no error |
| Reviewed by | Business, data engineering | Security and privacy |

- Two settled decisions frame everything below:
  - **D1** — the unit of **governance** is the **object**. Tags, masking and grants live on the objects themselves.
  - **D3** — the unit of **visibility** is the **consistency group**. Objects a report depends on become visible together.

---

## 4. The design approach — CTAS + Swap

**Chosen over INSERT OVERWRITE. Confirmed 27 October; INSERT OVERWRITE is not being pursued.**

**The mechanism**
- Each published table has **two schemas**: `D_LIVE` (what reports read) and `D_STAGE` (where the next batch is built).
- Each batch rebuilds into staging: `CREATE OR REPLACE TABLE D_STAGE.X COPY GRANTS COPY TAGS AS SELECT * FROM V_X`.
- Two gates run **on staging, before anything is visible**:
  - **Dependency gate** — every required upstream object reported COMPLETED for this batch, or carries an approved exception.
  - **Security gate** — the PII tags are present, and an unentitled role reads masks.
- Publication is **one metadata operation**: `ALTER SCHEMA D_STAGE SWAP WITH D_LIVE`.
- Reports never touch either schema. They read **thin views** in `D_VIEWS` that sit outside the swap, so object names never change.

**The property that drives most of the operating rules**
- The swap **exchanges the two physical storages**. The names stay put; the storage moves.
- So there are **two storages**, each with its own tag and grant lineage, and **each is rebuilt every other batch**.
- Anything applied to only one of them is therefore **absent on half of all batches, permanently**.

---

## 5. How it was tested

- **Two independent runs**, different accounts, different methods, same suite:

| | Our run | Colleague's run |
|---|---|---|
| Objects | `LM_POC_DB`, `NB_` roles | `P7_POC`, `P7_` roles |
| Method | Snowsight, **75 screenshots** | Python harness, **1,674 statements** captured |
| Coverage | S01–S05 + the two-session R2 test | S01–S10, 50 cases |

- Plus a dedicated **two-session atomicity test** written after both runs, because neither had answered R2.
- The colleague's run independently found **ten of the same defects** we did, and **the same two failures**. Where the two agree, the finding is solid.

---

## 6. Evidence — what the runs showed

**Part A — passed**
- **R2 — no reader sees a mixed state of one object.** 300 reads taken **while 40 swaps were in flight**: **zero mixtures**. The headline result.
- **R1 / R7** — readers held at the previous batch until the swap; upstream completion alone changed nothing visible.
- **R8 / R9** — the gate refused a FAILED dependency *and* a dependency that reported **nothing at all**; views stayed on the prior batch.
- **R15** — proven **both ways**: an unentitled writer persisted `***MASKED***` to disk; an entitled one wrote real values.
- **R19 / R11** — every publication attributable by batch, time, outcome, identity.
- **R29** — rollback by swapping back restored the prior batch, **with tags and grants**.
- **No drift** — four consecutive batches, tags and grants identical throughout (S02).

**Part B — passed, conditional on the operating rules in §8**
- **R28** — entitled reader sees real values, unentitled sees masks, through the views, before and after the swap.
- **R14 / R17 / R25** — satisfied **provided tags are deployed to both schemas**, per §8. Consistent with **D1**: the tags on the object *are* the governance state, and `COPY TAGS` carries them between cycles.
- **R27 — now settled.** CTAS reads and rewrites the data, so route (b) is closed. **The batch identity must be entitled** to see all PII in the domain it publishes.

**Still open**
- **R3** — one reading in 300 saw **two objects on different batches at the same instant**. Each table flipped atomically; the two did not reliably flip *together* for a reader in another session. **Unresolved.**
- **R4, R26** — never tested. No second consistency group and no row access policy exist in either pack.
- **R10** — the override works for a FAILED dependency, but a dependency that **never reported** has no status row to flag, so the approving `UPDATE` is a silent no-op.
- **R12** — the "publish the completed cycle through the normal path after an override" leg was never run.
- **R16** — the gate works but **nothing enforces it**; there is no stored procedure.

---

## 7. Findings, classified

~30 distinct defects were found across both reviews. They are not the same kind of thing:

- **5 — genuine properties of CTAS + Swap**
  - `COPY TAGS` copies from the table it replaces → drives the operating rule in §8
  - The swap pair alternates between two storages → drives the *both schemas* rule
  - `COPY GRANTS` has the same bootstrap gap → covered by future grants
  - CTAS moves `OWNERSHIP` to whoever ran it → ownership churn per cycle
  - CTAS reads and rewrites → settles R27 to route (a)
- **3 — genuine, and the good news**
  - Per-object atomicity (R2), grants travel with the storage, rollback restores tags and grants
- **1 — open, possibly not the mechanism at all**
  - The cross-session group read (R3)
- **4 — our control-table design, not CTAS + Swap**
  - Would be identical under any publication mechanism: the exception flag with nowhere to live, the rollback logged as a refusal, the unenforced gate, static `is_required`
- **~20 — defects in our own test scripts**
  - Unqualified grants, missing tag filters, impossible expectations, contradictory comments, wrong roles. **They say nothing about the approach** — they explain why earlier runs looked worse than the mechanism deserved.

> **24 of ~30 findings are not arguments against CTAS + Swap.**

---

## 8. The operating rules this POC produces

These are the deliverable. They are precautions, not defects — but they are **not optional**.

- **Deploy every business tag to the published table in BOTH schemas.**
  - Before the first batch that includes the column.
  - Applies to a **new column** from a schema change, and to **any governance change** to an existing tag.
  - Both schemas **every time** — a tag on one storage is absent from every other batch, permanently.
- **The batch identity must be entitled** to see every protected value in the domain it publishes. An unentitled identity silently writes masks to disk as if they were data.
- **Future grants on both swap schemas**, or `COPY GRANTS` — but not neither. A plain `CREATE OR REPLACE` drops every grant.
- **Ownership must return to the publishing role** after any build run by another identity, or the next batch fails on privileges rather than on data.
- **Capture each scenario's control-table output before running the next** — every reset truncates them.

---

## 9. Conclusion

- **CTAS + Swap is the right mechanism, and the POC validates it.**
- **Part A is satisfied.** Atomic per object — proven, not assumed. Gates correctly, refuses correctly, rolls back, audits. R2, the requirement the POC was created to settle, **passed**.
- **Part B is satisfied under the operating rules in §8.** `COPY TAGS` carries governance forward between cycles; governance is applied at deployment, which is consistent with D1.
- **The POC's main contribution is §8** — the rules are not obvious from the documentation, and two of them were found only by running the thing.
- **One question about the mechanism remains open: R3.** It is the last item that could change the design rather than the runbook.

---

## 10. What remains

**Tests — one session, designed as a single pack**

| | Test | Req | Why it matters |
|---|---|---|---|
| **T-A** | Two-session reader/publisher with the account on `READ_CONSISTENCY_MODE = GLOBAL`, run twice | **R3** | The only open question about the mechanism. Clean → an account setting closes it. Dirty → the swap does not give group atomicity across sessions |
| **T-B** | A second consistency group, published while the first is mid-publication | **R4** | Untested. A failure means publishing one report's data can corrupt another's |
| **T-C** | A row access policy through a rebuild | **R26** | Untested. If row policies behave differently from masking policies, **rows** leak rather than columns |
| **T-D** | Exception approvals in their own table, keyed on `(batch_id, object_name)` | **R10** | Closes the silent no-op. Design already proven by the colleague's `TC-05.3c` |
| **T-E** | Override → late job completes → cycle publishes complete through the normal path | **R12** | Never run. A failure means an overridden cycle never gets corrected |

**Decisions — no Snowflake time needed**
- Adopt `ROLLED_BACK` as a `PUBLISH_LOG` outcome (R11) — logging a rollback as `REFUSED` states the opposite of the truth
- Wrap publication in one owner's-rights stored procedure (R16, R18)
- Model `is_required` per cycle rather than as a static flag (R22)
- Settle future grants vs `COPY GRANTS`
- **Assign an owner to the tag deployment rule in §8** — currently nobody owns it
