# Nidwika's answers — what they settle, and what they reopen

Received 2026-11-04 against [`QUESTIONS_FOR_NIDWIKA.md`](QUESTIONS_FOR_NIDWIKA.md).
Three questions answered, two pushed back on, one turned round on us, one conditional yes.

---

## Settled

### Q1 — C4 CLOSED. Q2 is the right place.

> *"SEQ.NEXTVAL is mostly called in Q2 query only."*

**C4 closes as "already satisfied".** The key stays where Q2 line 50 already mints it, and nothing
moves. This also retires the Q1 option and with it the flag-4 complication — moving the mint to Q1
would have required moving the SCD-2 change-flag decision too, which we measured but no longer need.

*One word to keep an eye on:* "**mostly**". If any table mints its key somewhere other than Q2, that
table needs checking separately. Worth a one-line confirmation.

### Q4 — C5 DECIDED. Region name comes from IDMC; one mapping table.

> *"Region name will come from IDMC as input. There would be 1 mapping table which holds region name
> and equivalent prefix number for that region which will be prefix to seq.nextval value."*

That is **Candidate A** — literal argument supplied by the orchestrator — plus the single mapping
table we have been testing throughout. It **keeps R2's agreed signature**, so nothing about the
function shape changes.

What this does *not* dispose of is the failure mode, which is the part worth her attention:

| Input from IDMC | Result | Error? |
|---|---|---|
| Typo, or wrong case | `NULL` key | **no** |
| Omitted parameter | `NULL` key | **no** |
| **A valid region name for the wrong region** | **a structurally perfect, wrong key** | **no** |

Because the name now comes from IDMC, the realistic mistake is a **job pointed at the wrong region**
— which is exactly the undetectable case. We recommend the two controls regardless; see Q7.

### Q7 — Release checks: conditional yes.

> *"if these checks makes difference and adds value, we should include this check"*

They do, and here is the difference each makes, so it is a judgement rather than a promise:

| Check | What it catches | What happens without it |
|---|---|---|
| `VOLATILITY = 'VOLATILE'` **and** `IS_MEMOIZABLE = 'NO'` | Someone adding `IMMUTABLE` or `MEMOIZABLE` as a performance tweak | Every new row can receive **the same key**, silently. Snowflake calls it "undefined behavior" |
| `CREATED = LAST_ALTERED` on the function | The function being edited outside the release process | A region or sequence quietly rebound; keys change meaning with no audit trail |
| `NOT NULL` on the key column | A wrong or missing region name from IDMC | Rows load with **NULL surrogate keys and no error** — measured: 10 rows, 10 NULLs, success reported |

The first is one query and catches a failure that is otherwise invisible. **Recommend all three.**

---

## Pushed back on — fairly

### Q2 and Q5 — "duplicate counts without rationale"

> *"I noticed almost every place, you have quoted duplicate keys number (example - 1,200 of 4,800
> keys), this is good but doesnt set context of what we did... This is not something to highlight
> without rationale and analysis"*

**Accepted. The criticism is correct.** We led with evidence and omitted the mechanism, which makes
the numbers unarguable rather than persuasive — and the deck repeated the same mistake.

[`SCHEMES_EXPLAINED.md`](SCHEMES_EXPLAINED.md) is the answer: what each scheme **is**, worked through
step by step, **why** one breaks, and the measurements only at the end as confirmation.

The short version of what was missing:

> The schemes do not differ by **arithmetic versus text**. They differ by **fixed width versus
> variable width**.
>
> Digit concatenation glues `"1"` and `"42"` into `"142"`. To read the region back you take the
> first character — which is right only because every region code happens to be one digit today.
> Give a region the code `11` and the boundary becomes ambiguous: `11` + `1` and `1` + `11` are both
> `"111"`. Nothing in the key records where the region ends.
>
> Fixed-width offset reserves exactly 15 digit positions for the sequence and puts the region above
> them. The boundary is at a known place, so the region can grow to two or three digits without ever
> touching the sequence field.

The "198 duplicates" and "1,200 of 4,800" are then simply *that mechanism, counted*. 1,200 is not a
sample — it is every key belonging to the three two-digit regions, all of which must misdecode.

**R12 and R13 are also explained properly there** (§6): what each protects, what failure looks like,
and which one is genuinely in doubt. The honest position: **R12 is almost certainly a real
requirement** — a surrogate key that is not unique is not a key. **R13 is the one that needs her
decision**, because if the global database will always carry a region column alongside the key, R13
is a convenience rather than a requirement.

That would not change the recommendation — concatenation still fails R12 — but it would mean the
case rests on one leg instead of two, and she should know that.

---

## Reopened

### Q3 — The target datatype varies. This reopens R6.

> *"EMPLOYEE_ID NUMBER(38,0) - this is reference applicable to only this provided reference SQL. We
> can have any other column applicable for other table and datatype could be VARCHAR as well. So,
> this POC should consider CAST should happen as per target column datatype."*

**This is a real gap and she is right to call it.** Every run assumed one numeric key column. The
reference Q2 alone casts 27 columns to `VARCHAR`.

The difficulty is specific: a SQL UDF has exactly **one** declared return type, and R6's run proved
the **base type is enforced at CREATE** (precision and length are not). So one function cannot
return `NUMBER` for one table and `VARCHAR` for another.

**What we already know this does not change:** the *principle*. Scheme C — zero-padded text — is the
same fixed-width idea expressed for a `VARCHAR` target:

```
region 1, sequence 42   ->  "01" || "000000000000042"  ->  "01000000000000042"
region 11, sequence 1   ->  "11" || "000000000000001"  ->  "11000000000000001"
```

Padding is what plain concatenation was missing, so a text key is perfectly safe **provided it is
padded**.

**What needs testing** — `poc/12_q3_variable_target_datatype.sql`, written and ready:

| | |
|---|---|
| T12.1 | Confirm one function cannot serve both base types |
| T12.2 | Close off passing the target type as a parameter — the declared return type cannot vary by argument |
| T12.3 | Scheme C at twelve regions, including the two-digit codes that broke plain concatenation |
| T12.4 | Whether the target column's `VARCHAR` length bites |
| T12.5/6 | One function per type, versus one numeric function plus a cast at the call site |
| T12.7 | `VARCHAR` keys sort **lexically** — padding preserves ordering, an unpadded cast does not |

**Expected answer: one function per target base type** — Scheme B for numeric columns, Scheme C for
text — with identical region and sequence widths in both, so a key means the same thing either way.

---

## Turned back on us

### Q6 — "how and where this new table insert is coming in POC?"

Fair — we raised it without context. Here it is.

It comes from **R2's design**, not from any test. The agreed signature is
`f(region_name, sequence_name)`, and we proved the sequence name **cannot** be used to look up a
sequence at run time: Snowflake refuses dynamic object references inside a SQL UDF. The only shape
that works is a branch selector, where every sequence is named **literally** in the function body:

```sql
CASE sequence_name
    WHEN 'EMPLOYEE_SEQ' THEN EMPLOYEE_SEQ.NEXTVAL
    WHEN 'JOB_SEQ'      THEN JOB_SEQ.NEXTVAL
END
```

So:

| Change | Effort |
|---|---|
| Adding a **region** | **Insert one row** into the mapping table. Proven: 3 → 12 regions, zero lines of code |
| Adding a **table** | **Edit the function** to add a `WHEN` arm for its sequence |

That is the asymmetry we were flagging. It is still *one place* rather than per-ETL — which is what
§1 asked for — but it means table onboarding touches deployed code.

**Our suggestion**, since these queries are already generated: keep a registry table of
sequence names and **generate the `CASE` arms from it** at deploy time. Onboarding then becomes
"insert a row, re-run the generator", with no hand-editing. We are not asking for a decision now —
only flagging that someone owns the step.

---

## Where this leaves the POC

| | |
|---|---|
| **Closed by her answers** | C4 (Q2 placement), C5 (IDMC + mapping table), release checks |
| **Needs one more run** | **Q3** — `poc/12`, variable target datatype |
| **Needs her decision** | **R13** — is region-from-key-without-a-join a requirement, or a convenience? |
| **Awaiting ratification** | C3 and C6, now that the rationale is written up |
| **Flagged, not blocking** | "mostly called in Q2" — confirm no table mints elsewhere |
