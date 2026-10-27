# POC07 — what the testing concluded

Two independent runs of the same suite: ours in `LM_POC_DB` captured as screenshots, the
colleague's in `P7_POC` captured as 1,674 statements of JSON. Same defect list, same two
failures. This is the combined verdict against the 29 requirements in
[`problem_statement.md`](problem_statement.md).

---

## The short answer

**The swap works. The rebuild is what breaks governance.**

`ALTER SCHEMA … SWAP` delivers the consistency requirement cleanly — every gating,
override, rollback and attribution requirement that was tested, passed. Nothing in two
runs suggests the publication mechanism is wrong.

But `CREATE OR REPLACE TABLE … COPY TAGS` is a **snapshot of the table it replaces**, not
a read of live governance. Three requirements depend on protection reflecting current
governance at publication time, and all three fail by design, not by defect. That is not
a bug to fix in the scripts; it is the mechanism doing what it is documented to do.

**So: adopt the swap, and do not adopt `COPY TAGS` as the protection mechanism.**

One further thing must be said plainly: **the single requirement this POC was created to
settle — R2, that no reader can observe a mixture of the old and new state — has not been
tested by anyone.** See section 3.

---

## 1. What is proven

| Req | Statement | Evidence |
|---|---|---|
| **R1** | Consumers see the previous state while inputs refresh | Every scenario. Readers hold at the previous `batch_id` until the swap |
| **R3** | Group members become visible together | `batch ids across the thin views` unions both objects and returns `distinct_batches = 1` in all ten scenarios, both runs. One schema swap moves both tables |
| **R7** | Visible state changes only on publication | S05 TC-05.2: upstream `CUSTOMER` COMPLETED, `POLICY` FAILED, no swap, views unchanged |
| **R8** | Publication only after every job completed | S05 TC-05.1 gate empty → publish |
| **R9** | Any failure or non-completion blocks publication, no auto-release | S05 TC-05.2 (FAILED) and TC-05.3 (**no status row at all**) both refused; views stayed at B1 |
| **R10** | An authorised override path exists | S06 TC-06.3: B2 REFUSED, then B2 PUBLISHED with `exceptions_used` naming the approver — **for the FAILED case only, see §2** |
| **R11** | Every publication attributable | `PUBLISH_LOG` carries batch, time, outcome, reason, exception, identity |
| **R12** | An override does not leak into the next cycle | S06 TC-06.4: B2 → `Y` with approver, B3 → `N` with none |
| **R15** | No masked value persisted as real | Proven **both ways**: S08 TC-08.4 an unentitled writer stored `***MASKED***` to disk; TC-08.5 an entitled one stored real values |
| **R19** | Determinable which version consumers see | `batch_id` in the data plus `PUBLISH_LOG.attempted_at` |
| **R28** | Consumer-side protection unchanged across publication | S08 TC-08.1/08.2 through the thin views; S10 TC-10.3 after rollback |
| **R29** | One-step rollback by operator action | S10 TC-10.3: swap back, `batch_seen` returns to B1, tags and grants return with the storage |

---

## 2. What fails

### R14, R17, R25 — protection does not follow live governance

`COPY TAGS` copies a table's tags **from the table it replaces**. Four independent results:

| Evidence | Result |
|---|---|
| S01 TC-01.1 | First build: no predecessor, table published **untagged**; an unentitled reader saw real e-mail and SSN |
| S03 TC-03.1 | Tags seeded in one schema only → **0, 2, 0, 2** across four batches. Reproduced identically in both runs. The swap pair alternates between two storages, so the loss repeats on every other batch **forever** |
| S03 TC-03.4 | A column newly tagged in the Zone 3 base table arrives **untagged** on the published table and reads back as real phone numbers — **a direct R17 violation** |
| S04 TC-04.3 / S07 TC-07.4 | Once tags are lost, a rebuild **cannot** restore them — it copies the now-untagged predecessor. TC-07.4 proves it with two refusals either side of a full rebuild |

R25 requires protection to come from live governance state, "not a snapshot". `COPY TAGS`
is definitionally a snapshot. **This cannot be fixed by tightening the scripts.**

### R10 — the override cannot be granted in the case that needs it most

Their TC-05.3b. The gate reads `exception_flag` from the dependency's own `BATCH_STATUS`
row. A dependency that **never reported** has no row, so there is nothing to flag: the
approving `UPDATE` matches zero rows and **reports success**. `rows_updated = 0`, proven.
The approver believes the block is cleared; it is not. The domain stays stuck until
someone writes a status the ETL never reported — putting a fiction in the control table.

Their TC-05.3c shows the fix: approvals in their own table keyed on
`(batch_id, object_name)`, one extra `LEFT JOIN` in the gate, and the reset property
preserved.

### R16 — satisfiable, but nothing enforces it

The security gate works: it refused correctly every time it was run. But the publish steps
are plain SQL, so **nothing stops an operator reading "2 rows returned" and swapping
anyway.** S03 TC-03.1 is the demonstration — four batches published with no security
check, two of them carrying unprotected PII, every one logged `PUBLISHED`. R16 requires
the governance step to be *inside* the gate; without an owner's-rights procedure it is
merely beside it.

---

## 3. What has not been tested at all

| Req | Why it matters | Status |
|---|---|---|
| **R2** | *"No reader can observe a mixture of the previous and the new state"* — **the reason this POC exists** | **No evidence.** S09 TC-09.2 returned `READER_READINGS = 0`: the publisher ran 25 swaps and logged 25 rows, all publisher markers with `distinct_batches` null. No read was taken while a swap was in flight. TC-09.3 recorded only the same-session row; the cross-session row is absent |
| **R6** | Publication must not cancel, error or block in-flight consumer queries | **No evidence.** Same gap — no concurrent reader ever ran |
| **R4** | Publishing one group must not make another inconsistent | **Never tested.** Only one consistency group exists in the suite |
| **R26** | Row access policies subject to R14/R16/R17 | **Never tested.** No row access policy anywhere in either pack |
| **R22** | Per-cycle refresh expectation for mixed cadences | **Partial.** `is_required` is a static flag on the object, not a per-batch expectation. R22 explicitly calls out objects on different cadences |

A single-threaded harness cannot produce R2 or R6. Two genuine concurrent sessions are
required, and the account is on `READ_CONSISTENCY_MODE = SESSION` (verified), which is the
condition under which the question is interesting.

---

## 4. One decision the POC has settled

**R27 is now forced.** It permits R15 to be satisfied either by (a) the publication
identity passing through every masking policy, or (b) a mechanism that does not read and
rewrite the data. CTAS **is** read-and-rewrite, so route (b) is closed. S08 proves both
halves of (a): an unentitled writer persists masks, an entitled one does not.

The consequence is an operating decision, not a technical one: **the batch identity must
be entitled to see every protected value in the domain it publishes.**

---

## 5. What is needed before this can be called done

Ordered by what blocks a conclusion.

1. **Test R2 and R6 properly.** Two concurrent Snowsight sessions: one looping reads
   across the union of the published objects, one looping swaps. Count readings where
   `distinct_batches > 1`. Until this returns a number, the POC has not answered its own
   question.
2. **Replace `COPY TAGS` with re-applying tags from live governance** after each build,
   and re-run S01, S03 and S07. This is the design change the evidence demands. Note that
   the original `INSERT OVERWRITE` proposal sidesteps R14/R17/R25 entirely, because the
   table object is never replaced and its tags and grants are never disturbed — worth
   re-examining with this evidence in hand, as an input to the decision rather than a
   reversal of it.
3. **Move exception approval into its own table** keyed on `(batch_id, object_name)`
   (their TC-05.3c) so R10 is satisfiable for a dependency that never reported.
4. **Wrap publication in one owner's-rights stored procedure** so R16 is enforced rather
   than merely available, and so R18 can be answered.
5. **Add a second consistency group** and test R4.
6. **Add a row access policy** and test R26.
7. **Adopt `ROLLED_BACK`** as a `PUBLISH_LOG` outcome. Logging a rollback as `REFUSED`
   states that the batch never reached readers, which is the opposite of the truth and
   the one fact an incident review needs.
8. **Decide future grants vs `COPY GRANTS`.** Both work. Future grants also cover the day-1
   bootstrap; `COPY GRANTS` does not. But S04 TC-04.7 shows the cost of the future-grant
   route — the view owner can read **unpublished staging data** precisely because of it.

Items 1 and 2 are blocking. Items 3 to 8 are scope and design decisions that do not need
more Snowflake testing to settle.

---

## 6. So, does CTAS + Swap work?

**As a publication mechanism — yes, subject to R2 being proven.** It is atomic at the
object and group level, it gates correctly, it refuses correctly, it rolls back, and it
is auditable. Two independent runs agree.

**As a governance mechanism — no.** `COPY TAGS` carries yesterday's protection, not
today's, and three requirements turn on that distinction. The swap is not the problem;
the rebuild is.

The recommendation that follows is narrow: **keep the swap, change how protection is
applied to the rebuilt table, and prove R2 before anything is signed off.**
