# POC07 — where we stand, and what CTAS + Swap actually proved

One document. It replaces the earlier version, which grew by accretion as results came in.

---

## 1. What this POC was asked to settle

From [`problem_statement.md`](problem_statement.md). The requirement is deliberately stated
as **observable behaviour, naming no mechanism** — section 11: *"It names no mechanism.
Every requirement is stated in terms of observable behaviour so that the option space can
be evaluated against it without prejudice."*

So the question is not "does CTAS + Swap work". It is **"which of the 29 requirements does
CTAS + Swap satisfy, and which does it not"**.

The requirement splits in two, and section 2 says the two are *not separable in delivery*:

| | **Part A — publication gating** | **Part B — governance continuity** |
|---|---|---|
| Failure mode | **Visibly** — wrong numbers on a report | **Silently** — exposed data, no error |
| Requirements | R1–R13, R15, R19, R22, R29 | R14, R16, R17, R18, R25–R28 |

**In scope:** consumption-layer objects, what consumers may observe and when, the
governance posture across a publication, the identity that publishes.
**Out of scope:** how Zone 2 works, as-of access to prior states, and — explicitly — any
particular platform mechanism.

Two assumptions bound the answer: **A5**, batches are strictly serialised; **A4**,
consumers read through the published path and do not bypass it.

---

## 2. Where the evidence came from

| | Our run | The colleague's run |
|---|---|---|
| Objects | `LM_POC_DB`, `NB_` roles | `P7_POC`, `P7_` roles |
| Method | Snowsight, 75 screenshots | Python harness, 1,674 statements captured |
| Coverage | S01–S05, plus the R2 two-session test | S01–S10, 50 cases |
| Result | 23 pass · 1 fail · 2 inconclusive | 33 pass · 2 fail · 0 error · 12 need reading |

Same suite, corrected independently on both sides. **They hit ten of the same defects we
did, and the same two failures.** Where the two runs agree, the finding is solid.

---

## 3. The question that matters: are these real, or are they our scripts?

Roughly **thirty distinct defects** were found across both reviews. They are not all the
same kind of thing, and lumping them together is what makes the picture confusing. Sorted
by what they actually tell us:

### Bucket 1 — genuine properties of CTAS + Swap · **5 findings**

These cannot be fixed by writing better SQL. They are what the mechanism does.

| # | Property | Evidence | Consequence |
|---|---|---|---|
| 1 | **`COPY TAGS` copies from the table it replaces, not from live governance** | `TC-01.1` first build publishes untagged · `TC-03.1` **0,2,0,2** across four batches, reproduced in both runs · `TC-03.4` a newly tagged base column arrives unprotected and reads back as real phone numbers · `TC-04.3` + `TC-07.4` once tags are lost a rebuild cannot restore them | **A precaution, not a defect — see §4.** It imposes a deployment rule and needs a detective backstop |
| 2 | **The swap pair alternates between two physical storages** | `TC-03.1`, `TC-01.5` | Anything deployed to one schema only is missing on **every other batch, forever**. Makes #1 twice as damaging |
| 3 | **`COPY GRANTS` has the same bootstrap gap** | `TC-04.5` — no predecessor, nothing copied | Real, but future grants cover it |
| 4 | **CTAS replaces the table, so OWNERSHIP moves to whoever ran it** | `TC-08.4` | Per-cycle ownership churn; the publishing role can lose its own table |
| 5 | **CTAS reads and rewrites the data** | `TC-08.4` unentitled writer persists `***MASKED***` · `TC-08.5` entitled writer persists real values | **Closes R27 route (b).** The batch identity *must* be entitled to see all PII in the domain |

### Bucket 2 — genuine properties, and they are the good news · **3 findings**

| # | Property | Evidence |
|---|---|---|
| 6 | **A single published table flips atomically** | **300 reads taken mid-swap, 0 mixed.** R2 holds |
| 7 | **Grants travel with the storage across a swap** | `TC-04.1` |
| 8 | **Rollback by swapping back works, and tags and grants come back with it** | `TC-10.3` |

### Bucket 3 — open, and possibly not the mechanism at all · **1 finding**

| # | Finding | Status |
|---|---|---|
| 9 | **Two objects did not flip together for a reader in another session** — 1 mixed read in 300, `RA` and `RB` at the same instant | **Unresolved.** R3. Each table flipped atomically (#6), so the swap is not at fault. Snowflake's `READ_CONSISTENCY_MODE` default of `SESSION` does not guarantee a concurrent session sees another session's change immediately, which is exactly our case — but the docs do not say how this interacts with `ALTER SCHEMA … SWAP`. **Could be a one-line account setting; could be a design problem. Not yet known** |

### Bucket 4 — our control-table design, not CTAS + Swap · **4 findings**

**These would be identical under INSERT OVERWRITE, or any other publication mechanism.**

| # | Finding | Why it is not about CTAS |
|---|---|---|
| 10 | A dependency that never reported has no `BATCH_STATUS` row, so `exception_flag` has nothing to attach to and the approving `UPDATE` is a **silent no-op** (`rows_updated = 0`, proven) | Fails **R10**. It is a flaw in where we chose to put the flag |
| 11 | A rollback logged as `REFUSED` states the batch never reached readers — the opposite of the truth | Fails **R11**. A logging choice |
| 12 | No stored procedure, so the gate is advisory — `TC-03.1` published four batches, two unprotected, with no check at all | Fails **R16** enforcement. A deliberate POC simplification |
| 13 | `is_required` is a static flag on the object, not a per-cycle expectation | Partial **R22**. A modelling choice |

### Bucket 5 — defects in our test scripts · **~20 findings**

Unqualified grants after `USE ROLE SECURITYADMIN`; tag checks not filtered to `PII`;
`distinct_batches = 1` over an empty view; doubled contradictory `EXPECT` lines;
`RESULT_SCAN` under a role with no warehouse; drift fingerprints running as the reader;
a probe selecting a column the view had just renamed; `s09` not executable; `TC-07.4`
proving nothing; wrong batch ranges in headers.

**Every one of these is a bug in how we tested, and tells us nothing about the approach.**
They are worth recording only because they explain why earlier runs looked worse than the
mechanism deserved.

---

## 4. So: is CTAS + Swap the wrong approach?

**No.** Its publication semantics are right — atomic per object (proven), gates, refuses,
rolls back, audits. And **nothing in Buckets 4 or 5 — 24 of the ~30 findings — argues
against it at all.** Four are our control-table design and would survive a change of
mechanism; twenty were our own test bugs.

### `COPY TAGS` — the precaution, stated properly

**Decision, 27 October: we stay with CTAS + Swap. `INSERT OVERWRITE` is not being
pursued.** The `COPY TAGS` behaviour is therefore recorded not as a defect in the
mechanism but as **an operating precaution the POC exists to surface.**

That is the right call, and the evidence supports it. `S02` ran four consecutive batches
with tags and grants identical throughout — **zero drift**. With both schemas correctly
governed, `COPY TAGS` carries protection forward indefinitely. Governance applied at
deployment rather than at publication is a legitimate posture; the requirement states
what must be true after a publication, not which layer makes it true.

**The precaution, precisely.** It is sharper than "keep the tables tagged":

> Every column that governance requires to be protected must carry its tag **on the
> published table in BOTH schemas**, applied **before** the first batch that includes it.
> This covers a new column added by a schema change, and any governance change to an
> existing tag. Both schemas every time — because the swap pair alternates, a tag applied
> to only one storage is absent from every other batch, permanently (`TC-03.1`: 0, 2, 0, 2).

**The precaution alone is not sufficient, and this is the part to carry into the POC
write-up.** The security gate as built is a list-and-eyeball:

```sql
SELECT ... FROM TABLE(... TAG_REFERENCES_ALL_COLUMNS(...)) WHERE tag_name = 'PII'
/* EXPECT  2 rows — email=EMAIL and ssn=SSN */
```

There is **no source of truth for which columns ought to be tagged**. So:

| Failure | Does the gate catch it? |
|---|---|
| A tag is **lost** from a column the gate knows about | **Yes** — 0 rows instead of 2. Proven, `TC-01.2` refused the publish |
| A **new column** arrives untagged | **No.** The gate still sees its 2 expected rows. `TC-03.4`: `phone` published and read back as real phone numbers with every check green |

So the precaution needs one change to become safe:

| | |
|---|---|
| **Preventive** | The deployment rule above. Owner currently unassigned — Liquibase was scoped out, so no mechanism carries it today |
| **Detective** | **Change the gate from `EXPECT 2 rows` to an assertion against a governance list** — *every column governance says should be tagged is tagged on the staging table, or the publish refuses.* Small change, keeps `COPY TAGS`, and turns a silent process failure into a refused batch |

Without the detective control the precaution is a procedure with no verification, and the
failure mode is silent — exactly what Part B exists to prevent. **With it, R14 and R17 are
met.**

**R25 is a different matter and should go to the business as an explicit risk
acceptance**, not as a solved item. It requires protection to be determined by *"live
governance state, not by a snapshot"*, and `COPY TAGS` is definitionally a snapshot of the
predecessor. Deployment discipline plus the gate makes the *outcome* match live
governance; it does not make the *mechanism* read it. That is a process guarantee where
the requirement asks for a mechanism guarantee — a reasonable trade, but one somebody has
to accept in writing.

## 5. Requirement-by-requirement

| Req | Verdict | Basis |
|---|---|---|
| R1 | **PASS** | Readers hold at the previous batch until the swap, every scenario |
| **R2** | **PASS** | **300 single-object reads mid-swap, 0 mixed** |
| **R3** | **OPEN** | 1 mixed read in 300 across objects. Bucket 3 |
| R4 | **UNTESTED** | Only one consistency group exists |
| R5 | PASS (partial) | Thin views sit outside the swap and always resolve |
| R6 | **OUT OF SCOPE** | Nikhil's call, 27 Oct |
| R7 | **PASS** | Upstream completion alone changed nothing visible |
| R8 | **PASS** | Gate empty → publish |
| R9 | **PASS** | FAILED *and* missing-row both refused; views held |
| R10 | **PARTIAL** | Works for FAILED; **cannot be granted** for a never-reported dependency. Bucket 4 |
| R11 | **PARTIAL** | Attributable, but a rollback is logged as a refusal. Bucket 4 |
| R12 | PARTIAL | Reset proven; the "publish the completed cycle through the normal path" leg is untested |
| R13 | N/A | Unreachable under A5 |
| **R14** | **CONDITIONAL** | Met if the deployment rule holds **and** the gate asserts against governance. §4 |
| R15 | **PASS** | Proven both ways — `TC-08.4` / `TC-08.5` |
| R16 | **PARTIAL** | Gate works; nothing enforces it. Bucket 4 |
| **R17** | **CONDITIONAL** | `TC-03.4` — a new column publishes unprotected and the gate does **not** catch it today. Met once the gate asserts against a governance list. §4 |
| R18 | **OPEN** | Steady-state publish is fine; setup and recovery needed `MANAGE GRANTS` / `SECURITYADMIN` / `ACCOUNTADMIN` |
| R19 | **PASS** | `batch_id` + `PUBLISH_LOG` |
| R22 | PARTIAL | Static `is_required`, not per-cycle |
| **R25** | **RISK ACCEPTANCE** | `COPY TAGS` is a snapshot by definition. Outcome can be made to match governance; the mechanism still does not read it. Needs explicit sign-off. §4 |
| R26 | **UNTESTED** | No row access policy exists anywhere |
| R27 | **SETTLED** | Route (b) closed by Bucket 1 #5. Route (a) works and is now mandatory |
| R28 | **PASS** | Entitled sees real, unentitled sees masked, through the views, before and after |
| R29 | **PASS** | `TC-10.3` |

---

## 6. What still needs testing — one session, not a drip

Six things remain. They can be designed as **one test pack and run in a single sitting**,
which is how it should have been done from the start.

| | Test | Requirement | Why it matters — what a failure would mean |
|---|---|---|---|
| **T-A** | Re-run the two-session reader/publisher with the account on `READ_CONSISTENCY_MODE = GLOBAL`, twice | **R3** | The only open question about the mechanism itself. Clean → the group guarantee costs an account setting and milliseconds. Dirty → the swap does not give group atomicity across sessions and the design needs rework. **Run it twice: one mixed read in 300 is a thin signal, and a single clean run is also what "got lucky" looks like** |
| **T-B** | A second consistency group, published while the first is mid-publication | **R4** | Untested entirely. A failure means publishing one report's data can corrupt another's — the blast radius of the whole design |
| **T-C** | A row access policy on a published object, through a rebuild | **R26** | Untested entirely. Row policies may behave differently from masking policies across `CREATE OR REPLACE`. If they do not survive, rows leak rather than columns |
| **T-D** | **The governance-asserting gate.** Add a list of what should be tagged, have the gate compare the staging table against it, then re-run `TC-03.4` — the new tagged column must now be **refused**, not published | **R14, R17** | Converts the deployment precaution from a procedure into an enforced control. Without it a missed tag on a new column publishes PII in the clear with every check green, which is the one silent failure left in Part B |
| **T-E** | An exception approval in its own table, keyed on `(batch_id, object_name)` | **R10** | Closes the silent no-op. Design is already proven by the colleague's `TC-05.3c`; it needs porting and re-running |
| **T-F** | An override, then the late job completes, then the cycle publishes complete through the normal path | **R12** | The leg nobody has run. A failure means an overridden cycle never gets corrected |

**Not tests — decisions that need no Snowflake time:**
adopt `ROLLED_BACK` (R11) · wrap publication in an owner's-rights procedure (R16, R18) ·
model `is_required` per cycle (R22) · settle future grants vs `COPY GRANTS` · decide who
owns deploying tags to **both** schemas, which is the fix for Bucket 1 #2 and currently has
no owner.

---

## 7. Bottom line

CTAS + Swap satisfies Part A. On the evidence of two independent runs it gates, refuses,
publishes atomically per object, rolls back and audits correctly, and R2 — the requirement
the POC was created to settle — passed.

For Part B it is workable but conditional. `COPY TAGS` carries forward the protection of
the table it replaces rather than reading live governance. **We are staying with CTAS +
Swap, so this is recorded as an operating precaution, not a defect** — but the precaution
only holds with a detective control behind it, because the gate as built cannot see a new
column that should have been tagged and was not. **Two things close Part B: the
governance-asserting gate (T-D), and an explicit business acceptance of R25.** R3 remains
open until T-A is run.

Everything else found — twenty-four of roughly thirty findings — is either our own test
code or our own control-table design, and none of it is an argument against the mechanism.
