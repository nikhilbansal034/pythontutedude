# Which joins cause the effective-date problem, and why

Status: **draft for review.**

This explains, with worked data, when joining source tables into a Type-2 target goes wrong. No solution
design — just which cases break and why.

Columns used throughout: `business_key`, `row_eff_dte`, `row_exp_dte`, `is_del`. `high end date` is the
far-future sentinel used to mean "still current".

---

## 1. The one thing that decides everything

Every source table is one of two shapes.

**A table that keeps history** — several rows per `business_key`, each covering a period:

| business_key | value | row_eff_dte | row_exp_dte |
|--------------|-------|-------------|-------------|
| K1 | a | 10-Sep | 21-Sep |
| K1 | b | 21-Sep | high end date |

**A table that keeps only the current value** — exactly one row per `business_key`, no dates at all:

| business_key | value |
|--------------|-------|
| K1 | p |

That's the whole classification. You can tell which one a table is by looking at it: does it have
`row_eff_dte` / `row_exp_dte` and more than one row per key, or not?

> ### The rule
>
> - **One table keeps history** → **no problem.** Its dates become the target's dates.
> - **Two or more tables keep history** → **problem.** Neither table's dates are correct on their own.
> - **Target is "current only" (Type 1)** → **never a problem**, however many history tables feed it.

Everything below is detail on top of that rule.

---

## 2. The easy case — only one table keeps history

**Table 1** — keeps history:

| business_key | value | row_eff_dte | row_exp_dte |
|--------------|-------|-------------|-------------|
| K1 | a | 10-Sep | 21-Sep |
| K1 | b | 21-Sep | high end date |

**Table 2** — current value only:

| business_key | value |
|--------------|-------|
| K1 | p |

**Target:**

| business_key | row_eff_dte | row_exp_dte | tbl1_value | tbl2_value | is_del |
|--------------|-------------|-------------|------------|------------|--------|
| K1 | 10-Sep | 21-Sep | a | p | N |
| K1 | 21-Sep | high end date | b | p | N |

Table 1's dates are copied straight through. Table 2's value is attached to each row. This is the pattern
the team builds today, and it works.

---

## 3. The problem case — two tables keep history

**Table 1:**

| business_key | value | row_eff_dte | row_exp_dte |
|--------------|-------|-------------|-------------|
| K1 | a | 10-Sep | 21-Sep |
| K1 | b | 21-Sep | high end date |

**Table 2:**

| business_key | value | row_eff_dte | row_exp_dte |
|--------------|-------|-------------|-------------|
| K1 | p | 9-Sep | high end date |

Whose dates do we use?

**Table 1's?** We'd start the target at 10-Sep. But Table 2 says `p` was already true from 9-Sep. We lose
9-Sep to 10-Sep entirely.

**Table 2's?** We'd get one row, 9-Sep to high end date. But Table 1 changed from `a` to `b` on 21-Sep. We
lose that change.

Neither is right. **We have to combine both tables' dates.**

Collect every date either table mentions — **9-Sep, 10-Sep, 21-Sep** — and cut the timeline at each one:

| business_key | row_eff_dte | row_exp_dte | tbl1_value | tbl2_value | is_del |
|--------------|-------------|-------------|------------|------------|--------|
| K1 | 9-Sep | 10-Sep | *(blank)* | p | N |
| K1 | 10-Sep | 21-Sep | a | p | N |
| K1 | 21-Sep | high end date | b | p | N |

Three target rows out of a two-row and a one-row table. **That is the problem.**

**Decided**: the 9-Sep to 10-Sep row is **kept**, with `tbl1_value` blank — matching
`scenario_screenshot.png`. We do not drop periods where one table has no value.

---

## 4. Why it is hard, not just fiddly

Everything above is one-time work. The difficulty shows up on the next load.

**Day 2.** Table 1 does not change at all. Table 2 gets new versions:

| business_key | value | row_eff_dte | row_exp_dte |
|--------------|-------|-------------|-------------|
| K1 | p | 9-Sep | 15-Sep |
| K1 | q | 15-Sep | 22-Sep |
| K1 | r | 22-Sep | high end date |

New date list: **9, 10, 15, 21, 22**. The target becomes:

| business_key | row_eff_dte | row_exp_dte | tbl1_value | tbl2_value | is_del | what happened |
|--------------|-------------|-------------|------------|------------|--------|---------------|
| K1 | 9-Sep | 10-Sep | *(blank)* | p | N | unchanged — left alone |
| K1 | 10-Sep | 21-Sep | a | p | **Y** | day-1 row, no longer valid |
| K1 | 21-Sep | high end date | b | p | **Y** | day-1 row, no longer valid |
| K1 | 10-Sep | 15-Sep | a | p | N | **new** |
| K1 | 15-Sep | 21-Sep | a | q | N | **new** |
| K1 | 21-Sep | 22-Sep | b | q | N | **new** |
| K1 | 22-Sep | high end date | b | r | N | **new** |

> **The point worth making to anyone you explain this to:**
>
> **Table 1 did not change on day 2. Not one row. Yet three of its target rows had to be marked `is_del = 'Y'`
> and rewritten.**

Normal loading appends new rows. This has to go back and break apart rows that were already written and were
correct at the time. That is what makes it different.

**Consequence worth noting now**: `business_key` + `row_eff_dte` is no longer unique across the whole target.
It is unique only among rows where `is_del = 'N'`. Every query and every merge against this table has to
filter on `is_del`.

---

## 5. Which real tables keep history?

| Where the table comes from | Keeps history? | Notes |
|---|---|---|
| **History bucket**, source keeps its own versions | **Yes** | The normal problem case |
| **History bucket**, source overwrites in place | **Yes, but** | Its dates mean *"when we loaded it"*, not *"when it happened"* — see §8 |
| **Current bucket** | **Open question** | See §6 |
| **Lookup / reference / type-list** | No | Codes and descriptions |
| **An already-built Zone2 target table** | **Yes** | Creates a knock-on effect — see §8 |

---

## 6. The open question (Q1)

**Does a current-bucket table keep history, or hold only the current value?**

The team's answer is **current value only** — one row per `business_key`. To be confirmed with Nidhika.

| If current bucket... | Then |
|---|---|
| **holds current value only** (team's answer) | Only history-bucket tables can cause the problem. Smaller problem. |
| **keeps history** | Current-bucket tables can cause it too — **and bring two extra failures** (§8, quiet corrections and vanishing versions). |

**How to check without waiting for anyone:**

```sql
SELECT COUNT(*), COUNT(DISTINCT business_key) FROM <current_bucket_table>;
```

Same number → current value only. First number bigger → it keeps history.

---

## 7. Handling the unnecessary split

A source can change a column that never reaches the target. That still produces a new `row_eff_dte`, and if
we use it we split the target into two identical rows for no reason.

**Table 2 as it arrives** — `tgt_col` goes to the target, `other_col` does not:

| business_key | tgt_col | other_col | row_eff_dte | row_exp_dte |
|--------------|---------|-----------|-------------|-------------|
| K1 | p | x | 9-Sep | 15-Sep |
| K1 | p | y | 15-Sep | 22-Sep |
| K1 | r | y | 22-Sep | high end date |

Only `other_col` changed on 15-Sep. If we take the dates as they are, the target gets a split at 15-Sep
producing two rows both carrying `p` — identical, and wrong.

### How we handle it

**Collapse each source table first, before collecting any dates.** Three steps per source:

1. **Project** — keep only `business_key`, the dates, and the columns that actually land in the target.
   Drop everything else.
2. **Hash** — build a hash over the kept non-key columns.
3. **Collapse** — where consecutive versions have the same hash, merge them into one: earliest
   `row_eff_dte`, latest `row_exp_dte`.

Table 2 after collapsing:

| business_key | tgt_col | row_eff_dte | row_exp_dte |
|--------------|---------|-------------|-------------|
| K1 | p | 9-Sep | 22-Sep |
| K1 | r | 22-Sep | high end date |

The 15-Sep date is gone. Now collect dates and cut the timeline — no spurious split.

### Two things to be careful about

**Only merge versions that are next to each other in time.** If the value goes `p`, then `q`, then `p` again,
those two `p` periods must **not** be merged — there was a real change in between. Merge only on consecutive
versions with no different value between them.

**A gap is not the same as a merge.** If Table 1 covers 10-Sep to 15-Sep, then nothing until 20-Sep, then
`a` again from 20-Sep — those two periods stay separate even though the value is the same, because Table 1
genuinely had no value between 15-Sep and 20-Sep. The target correctly shows blank for that middle period.

### One thing to check

The framework already does hash-based change detection in Phase 3, but the ABC doc describes that hash as
being over *"business-key-only content"*. The hash we need here is over **target-relevant non-key columns**,
which is a different scope. Whether the existing hash can be reused or a second one is needed is worth
confirming before building.

---

## 8. The things that go wrong

Four apply to every problem case. Four depend on the open question or on which tables are involved.

### Always

**1. Neither table's dates are enough.** §3.

**2. Yesterday's rows must be broken apart.** §4. The expensive one — and it does **not** happen on the very
first (history) load, because there is nothing there yet to break.

**3. One table starts before the other.** §3. **Decided**: we keep those periods with a blank, per the
screenshot. The same situation arises at the end if one table's record is deleted while the other continues —
the same decision should apply there, and is worth stating explicitly when the rule is written down.

**4. Several versions arrive at once.** Multiple loads in a day, or a catch-up after being down two days, can
deliver two versions with the same `row_eff_dte`. Rule from the call: take the latest. Must happen *before*
dates are collected — alongside §7.

### Only if current-bucket tables turn out to keep history

**5. Quiet corrections.** The source decides an old value was wrong and fixes it — dates unchanged, value
changed. A history-bucket table keeps both the old and the new claim, so you can see it happened. A current
bucket only ever shows the latest claim, so the only way to notice is to compare against what you already
loaded.

**6. Vanishing versions.** Worse. If the source *removes* a version — merges two periods, deletes a
correction — a current-bucket table just stops showing it. There is no record it was ever there.

We find changed records by looking for rows whose timestamp has moved. **A row that no longer exists has no
timestamp to find.** That key never gets picked up, the wrong target rows stay in place, and no future run
will ever notice.

This is the strongest reason to confirm Q1 rather than assume.

### Only with particular table types

**7. Two tables measuring time differently.** If Table 1's dates mean *"when it happened in the business"* and
Table 2's dates mean *"when we loaded it"*, combining them gives a timeline that is neither.

*Example:* the real change happened 11-Sep, but we only loaded it 18-Sep. The target says the value changed
on 18-Sep. Ask "what did this look like on 12-Sep?" and you get the old value back — wrong, with nothing in
the output marking which columns are business-timed and which are load-timed.

**This cannot be fixed later by any query** — the information isn't there. We do not control how the sources
timestamp their data, so this is a limitation to state and accept, not something to design around. It should
be written into whatever documentation goes with these targets so consumers know.

**8. Knock-on rebuilds.** If one of the joined tables is an already-built Zone2 target, this load can't run
until that one is finished and correct. And if that table later gets its rows broken apart (§4), everything
built on top of it has to be rebuilt too.

---

## 9. The full picture

| Table 1 | Table 2 | Target | Problem? |
|---------|---------|--------|----------|
| Keeps history | Current value only | Type 2 | **No** — today's pattern |
| Keeps history | Lookup | Type 2 | **No** — today's pattern |
| Current value only | Current value only | Type 2 | **No** — but where do the target's dates come from? Probably load date. Confirm it's already solved |
| **Keeps history** | **Keeps history** | Type 2 | **YES** |
| Keeps history | Keeps history | Type 1 | **No** — no history to keep, take the latest |

Three or more history tables: same problem, more dates to combine, every issue above gets worse.

---

## 10. Decisions that would shrink the problem

Each removes cases rather than solving them. Worth putting to Nidhika before any build starts.

1. **Say that only history-bucket tables may set the target's dates.** Makes the Q1 answer stop mattering for
   design, and removes issues 5 and 6 completely.
2. **Treat load-timed tables as attributes only** — attach their values but don't let them create dates.
   Removes issue 7, but changes what the target means, so it needs business sign-off, not just ours. If the
   business can't accept it, we accept the mixed timeline and document it.
3. **Split `is_del` into two flags, or add a reason code.** Today the same flag means both "this row was
   replaced by a correction" and "this record was deleted at source". Downstream can't tell them apart.

**Option 1 is the most useful** — it makes the design safe whichever way Q1 turns out.

---

## 11. Questions still open

| # | Question | What it decides |
|---|----------|-----------------|
| Q1 | Does a current-bucket table keep history, or hold only the current value? | Whether current-bucket tables can cause the problem |
| Q2 | Can a source *remove* a version, or only add and correct? | How serious issue 6 is |
| Q3 | Does Zone1 build history-bucket tables for sources that overwrite in place? | Whether issue 7 is real |
| Q4 | Is "current value only + current value only → Type 2 target" already a solved pattern? | Whether it stays in scope |
| Q5 | Are Type 1 and Type 2 the only target types? | Whether §9 is complete |
| Q6 | Do we need to handle a join returning many rows per key per date? | Probably a separate problem |
| Q7 | Is joining to an already-built Zone2 table in scope? | Whether issue 8 needs designing |
| Q8 | Can the framework's existing Phase-3 hash be reused for §7, or is a second one needed? | How §7 gets built |

**Settled so far**

- Periods where one table has no value are **kept**, with the missing side blank (§3).
- Superseded rows are marked `is_del = 'Y'` and new rows inserted; rows are not updated in place (§4).
- Mixed business-timed and load-timed dates are accepted as a limitation, not designed around (§8, issue 7).

**For the asset list**: deciding whether a table "keeps history" *for a particular target* needs to know which
columns actually reach that target — per-mapping information, not something visible from the table itself.
Worth telling Abhi before he builds the list.
