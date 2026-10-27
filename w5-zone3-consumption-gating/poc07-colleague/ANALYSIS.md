# Review of the colleague's POC07 run

What is in this folder, what it establishes, and where it disagrees with our own run.
Written after reading `CHANGES.md` and verifying every claim against the twelve JSON
capture files in `evidence/` rather than taking the write-up at its word.

---

## 1. What this actually is

Not a separate design. **It is our own `poc07/` P7_ suite** — same `P7_POC` object model,
same seven `P7_*` roles, same `TC-NN.N` case ids — taken as input, corrected, and then
actually executed. `CHANGES.md` describes the author of the original as "a colleague,
working independently from the same brief"; that is us.

| | |
|---|---|
| Run | 27 October 2026, account `pn56976-deloittena`, warehouse `LM_PII_POC_WH` |
| Cases | 50 (our 48, plus their new `TC-05.3b` and `TC-05.3c`) |
| Statements captured | 1,692 across 12 files — 1,674 excluding teardown, matching their count |
| Status totals, from the JSON | 131 PASS · 2 FAIL · 16 REVIEW · 0 ERROR |

Their headline figures reconcile with the captures. Nothing is overstated.

---

## 2. Independent corroboration — ten defects found twice

Two people, two Snowflake accounts, two methods (their Python harness against our
Snowsight screenshots), and the same defect list. Each of these we found independently
in `poc07-nb/`:

| Defect | Theirs | Ours |
|---|---|---|
| Unqualified grants after `USE ROLE SECURITYADMIN` drop the database context | 58 grants | same, all 10 scenarios |
| Tag checks not filtered to `PII`; schema tag inherits to every column | 44 checks | 86 across both packs |
| `distinct_batches = 1` over an empty view is arithmetically impossible | `TC-01.2` | same, corrected to 0 |
| Contradictory doubled `EXPECT` lines | 8 sites | 9 sites |
| `SHOW GRANTS` + `RESULT_SCAN` under `SECURITYADMIN` has no warehouse | s04, teardown | same |
| Future grants need `MANAGE GRANTS`, not schema ownership | setup | same |
| `CREATE OR REPLACE MASKING POLICY` makes setup un-rerunnable | setup | same |
| The unentitled writer loses `SELECT` when s03 rebuilds the source views | `P7_BATCH_NOENT` | same |
| Drift fingerprints running as the reader role | s02 ×4, s10 | same |
| The two failures | `TC-04.3`, `TC-04.5` | same two |

That both runs land on the same two failures, from different directions, is the
strongest evidence either pack produces.

---

## 3. Five things they found that we did not

Worth taking into our pack.

1. **`s05` `TC-05.3` — a block that can never be cleared.** The gate reads
   `exception_flag` from the dependency's own `BATCH_STATUS` row. When the dependency
   never reported there is no row, so there is nothing to flag, and the approving
   `UPDATE` is a **silent no-op** — proven, `rows_updated = 0`. The approver believes
   they cleared the block; the domain stays stuck. Their fix is a separate
   `EXCEPTION_APPROVAL` table keyed on `(batch_id, object_name)` with approver and
   reason, and one extra `LEFT JOIN` in the gate. **This is a real hole in the control
   table model we agreed, and it is the best single finding in their pack.**

2. **`s07` `TC-07.4` proved nothing as we wrote it.** It unset the tags, flipped the
   status to FAILED, re-set the tags and flipped back — with no CTAS in between. That
   demonstrates a status column can be updated. Their Part A / Part B rewrite proves the
   real point: a rebuild **cannot** repair a tag failure, evidenced by
   `REFUSALS_FOR_B3 = 2` with a full rebuild between the two refusals. Only an in-place
   `SET TAG` fixes it. Same mechanism we found in S04, turned into an actual test.

3. **`s10` logging a rollback as `REFUSED` is wrong.** B2 *was* published; readers saw
   it. They added a `ROLLED_BACK` outcome and an audit query that derives, per batch,
   "reached readers and stands" vs "reached readers, then withdrawn" — a query that
   cannot be written while a rollback is recorded as a refusal. Correct, and we should
   adopt it.

4. **`s09` `TC-09.2` and `TC-09.3` were not executable as written** — a bare `SWAP` plus
   a prose instruction to "repeat at least 50 times", and a reader query left commented
   out. See section 4.

5. **`s03` `TC-03.3`'s probe selected `email` after the view renamed it** to
   `email_address`, so it errored with "invalid identifier" instead of demonstrating.
   This explains the missing third screenshot in our own S03 evidence.

---

## 4. What their summary understates: S09 produced no atomicity evidence

"33 passed, 2 failed, 0 errored" reads as near-complete. The captures say otherwise for
the one scenario that tests the POC's central question.

- **`TC-09.2` verdict: `READER_READINGS = 0`, `MIXED_READINGS = null`.** The publisher
  loop ran its 25 swaps and wrote 25 rows, but every one is tagged `A-publisher` with
  `distinct_batches = null` and `note = 'swap'`. Those are swap markers. **No read was
  taken while any swap was in flight.**
- **`TC-09.3` verdict: one row, `A-same-session`.** The `B-other-session` row — reading
  from a different session across the swap, which is the entire point — is absent.

`CHANGES.md` is honest that these "need the second session", and a single-threaded
harness structurally cannot provide one. But the consequence deserves stating plainly:

> **Can a reporting user see a partially refreshed, internally inconsistent dataset
> during the swap? Neither pack has answered this.** It is the requirement the whole POC
> exists to settle, and it needs two genuine concurrent sessions.

The account is on `READ_CONSISTENCY_MODE = SESSION` (verified, account default, set at
no level), which is the condition under which the question is interesting.

---

## 5. Caveats on the document itself

- **`CHANGES.md` reads as self-contradictory.** The header says *"Nothing in either
  folder has been run"* and §6 says *"`00_setup.sql` has not been run"* — while §4 reports
  a full execution. **Confirmed with Nikhil: he had already run `00_setup.sql` before the
  colleague took the suite over**, which is why their pre-flight notes say otherwise.
  Those two passages were written before their own run and never refreshed. Not an error
  of fact about the account, but read top-down the document still says the opposite of
  what happened, so it should not be circulated as-is.
- Two sections are both numbered `## 4`.
- It references `../POC07_DESIGN.md` (v14), `../POC07_TEST_DESIGN.md`, `../NIkhil/` and
  `../POC/_common/03_evidence/`. **None of these are in this repository.** Much of their
  commentary is framed against that design document — tests `T31`, `T32`, `T40`, `T41`
  and decisions `D11`, `D24`, `D25` — which we cannot see or check.

---

## 6. The one substantive disagreement: future grants vs COPY GRANTS

On `TC-04.5` they conclude that the `P7_VIEW_OWNER` `SELECT` present on a first build
comes from the **future grant**, and therefore *"future grants do cover the day-1
bootstrap that `COPY GRANTS` alone cannot"* — reading it as support for standardising on
future grants rather than the `COPY GRANTS` route.

The observation is correct and we reached it independently. The conclusion drawn from it
is the opposite of ours, and the disagreement is worth settling explicitly rather than
leaving implicit:

| | Future grants | `COPY GRANTS` |
|---|---|---|
| Covers the day-1 bootstrap | yes | no |
| Needs `MANAGE GRANTS` to set up | yes | no |
| Standing access to **staging**, i.e. pre-publication data | **yes — this is `TC-04.7`** | only what was explicitly granted |
| Survives a plain `CREATE OR REPLACE` | yes | no |

`TC-04.7` — the view owner reading unpublished staging data — exists *because* of the
future grant. That is a real security cost on the future-grant side, and it is the thing
to weigh against the bootstrap convenience. Neither run settles it; it is a decision.
