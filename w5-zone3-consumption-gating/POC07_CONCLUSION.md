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

**R2 is now settled, and it passed.** 300 reads of a single object taken while 40 swaps
were in flight produced zero mixtures. The mechanism does what it was chosen to do.

**R3 did not.** One reading in 300 saw both objects on different batches at the same
instant. Each table flips atomically; the two do not reliably flip *together* for a reader
in another session. The likeliest cause is the account's `READ_CONSISTENCY_MODE`, and
`PART 5` of the test settles whether a configuration change closes it. That is now the
most important open question in the POC.

---

## 1. What is proven

| Req | Statement | Evidence |
|---|---|---|
| **R1** | Consumers see the previous state while inputs refresh | Every scenario. Readers hold at the previous `batch_id` until the swap |
| **R2** | **No reader observes a mixture of the old and new state of the same object** | **300 readings of one object taken while 40 swaps were in flight: zero mixtures.** The swap is atomic for a single table. See §1a |
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

### 1a. R2 — settled, 27 October

The two-session test (`poc07-nb/r2_atomicity_two_session.sql`) finally ran. The validity
gate passed first: **600 readings, 40 swaps, 40 of them inside the reading window**, and
the reader observed the batch id alternate — so it genuinely was reading across swaps,
which is what the earlier attempt could not establish.

| Probe | Readings | Mixed | Result |
|---|---|---|---|
| one object, one statement | 300 | **0** | **R2 HOLDS** |
| both objects, one statement | 300 | **1** | **R3 FAILS** — see §2 |

**R2 is answered, and the answer is yes.** A single published table flips atomically; no
reader ever saw part of one batch and part of another in the same object. That is the
guarantee the mechanism was chosen for, and it holds.

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

### R3 — the two objects did not flip together

**One reading in 300 saw `RA` and `RB` at the same instant** — seq 131,
`2026-10-27 01:17:38.175`, `distinct_batches = 2`. One published object was still on the
previous batch while the other had already moved to the new one. Over 40 swaps that is
roughly one mixed read per publication for a reader querying continuously.

R3 requires that all objects in a consistency group become visible together or not at
all. They did not. **This is the mixed-batch read the whole requirement exists to
prevent — at group level rather than object level.**

The swap itself is a single metadata operation and each table moved atomically (§1a). So
the failure is not in the swap; it is in **cross-session visibility of it**. Snowflake
documents `READ_CONSISTENCY_MODE`: the default `SESSION` gives consistency within a
session but *"a concurrent session may not see another session's changes straight away"*;
`GLOBAL` makes them immediately visible across sessions for a cost of milliseconds. Our
swap runs in one session and our read in another, which is exactly that case.

**The docs do not state how this interacts with `ALTER SCHEMA … SWAP`, so that is a
hypothesis, not a conclusion.** `PART 5` of the test file settles it: archive the
SESSION-mode evidence, set the account to `GLOBAL`, re-run, compare. If GLOBAL closes the
window, the group guarantee is reachable by configuration. If it does not, it needs a
design change. **This is now the single most important open item in the POC.**

Note the operational cost either way: `READ_CONSISTENCY_MODE` is **account-level only and
ACCOUNTADMIN-only**, so turning it on affects every workload on the account, not just
this one.

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
| **R6** | Publication must not cancel, error or block in-flight consumer queries | **Out of scope** — Nikhil's call, 27 October. The R2 run would answer it as a by-product, since all 600 reader statements returned, but nothing has been built or claimed for it |
| **R4** | Publishing one group must not make another inconsistent | **Never tested.** Only one consistency group exists in the suite |
| **R26** | Row access policies subject to R14/R16/R17 | **Never tested.** No row access policy anywhere in either pack |
| **R22** | Per-cycle refresh expectation for mixed cadences | **Partial.** `is_required` is a static flag on the object, not a per-batch expectation. R22 explicitly calls out objects on different cadences |

R2 is no longer on this list — see §1a. The remaining four need either a second
consistency group, a row access policy, or a change to how `is_required` is modelled;
none of them needs the two-session apparatus.

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

1. **Run `PART 5` — does `GLOBAL` consistency mode close the R3 window?** Archive the
   SESSION evidence, set the account to `GLOBAL`, re-run the two blocks, compare. A clean
   GLOBAL run means the group guarantee costs a configuration change and milliseconds of
   latency. A dirty one means it needs a design change. Everything else in this list is
   cheaper than this question is important. *(R2 itself is done — §1a.)*
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
