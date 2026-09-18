# Which joins cause the effective-date problem, and why

Status: **draft for review.**

This explains, with worked data, when joining source tables into a Type-2 target goes wrong. No solution
design — just which cases break and why.

---

## 1. The one thing that decides everything

Every source table falls into one of two groups.

**Dated table** — it tells you *when* each value was true.

| K1 | value | from | to |
|----|-------|------|-----|
| K1 | a | 10-Sep | 21-Sep |
| K1 | b | 21-Sep | forever |

**Undated table** — it only tells you what the value is *now*.

| K1 | value |
|----|-------|
| K1 | p |

That's the whole classification.

> ### The rule
>
> - **One dated table** in the join → **no problem.** That table's dates become the target's dates.
> - **Two or more dated tables** → **problem.** Neither table's dates are correct on their own.
> - **Target is "current only" (Type 1)** → **never a problem**, however many dated tables feed it.

Everything below is detail on top of that rule.

---

## 2. The easy case — one dated table

**Table 1** (dated):

| K1 | value | from | to |
|----|-------|------|-----|
| K1 | a | 10-Sep | 21-Sep |
| K1 | b | 21-Sep | forever |

**Table 2** (undated):

| K1 | value |
|----|-------|
| K1 | p |

**Target:**

| K1 | from | to | Table 1 value | Table 2 value |
|----|------|-----|---------------|---------------|
| K1 | 10-Sep | 21-Sep | a | p |
| K1 | 21-Sep | forever | b | p |

Table 1's dates are copied straight through. Table 2's value is just attached to each row. This is the
pattern the team builds today, and it works.

---

## 3. The problem case — two dated tables

**Table 1** (dated):

| K1 | value | from | to |
|----|-------|------|-----|
| K1 | a | 10-Sep | 21-Sep |
| K1 | b | 21-Sep | forever |

**Table 2** (also dated):

| K1 | value | from | to |
|----|-------|------|-----|
| K1 | p | 9-Sep | forever |

Now — whose dates do we use?

**Use Table 1's dates?** We'd start the target at 10-Sep. But Table 2 says `p` was already true from 9-Sep.
We'd lose the 9-Sep to 10-Sep period entirely.

**Use Table 2's dates?** We'd get one row, 9-Sep to forever. But Table 1 changed from `a` to `b` on 21-Sep.
We'd lose that change.

Neither is right. **We have to combine both tables' dates.**

Collect every date either table mentions: **9-Sep, 10-Sep, 21-Sep**. Cut the timeline at each one:

| K1 | from | to | Table 1 value | Table 2 value |
|----|------|-----|---------------|---------------|
| K1 | 9-Sep | 10-Sep | *(nothing yet)* | p |
| K1 | 10-Sep | 21-Sep | a | p |
| K1 | 21-Sep | forever | b | p |

Three rows, from two tables that had two rows and one row. **That is the problem.**

---

## 4. Why it is hard, not just fiddly

Everything above is one-time work. The real difficulty shows up on the next load.

**Day 2.** Table 1 does not change at all. Table 2 gets new versions:

| K1 | value | from | to |
|----|-------|------|-----|
| K1 | p | 9-Sep | 15-Sep |
| K1 | q | 15-Sep | 22-Sep |
| K1 | r | 22-Sep | forever |

New date list: **9, 10, 15, 21, 22**. The target has to become:

| from | to | Table 1 | Table 2 | what happens |
|------|-----|---------|---------|--------------|
| 9-Sep | 10-Sep | — | p | unchanged, leave it alone |
| 10-Sep | 15-Sep | a | p | **new row** |
| 15-Sep | 21-Sep | a | q | **new row** |
| 21-Sep | 22-Sep | b | q | **new row** |
| 22-Sep | forever | b | r | **new row** |

And the two rows written yesterday — `10-Sep → 21-Sep` and `21-Sep → forever` — are no longer correct.
They get marked deleted (`is_del = 'Y'`) and replaced.

> **This is the point worth making to anyone you explain it to:**
>
> **Table 1 did not change on day 2. Not one row. Yet three of its target rows had to be torn up and
> rewritten.**

Normal loading appends new rows. This has to go back and break apart rows that were already written and
already correct at the time. That is what makes it different.

---

## 5. Which real tables are "dated"?

| Where the table comes from | Dated? | Notes |
|---|---|---|
| **History bucket**, source keeps its own versions | **Yes** | The normal problem case |
| **History bucket**, source overwrites in place | **Yes, but** | Dates mean *"when we saw it"*, not *"when it happened"* — see §7 |
| **Current bucket** | **Open question** | See §6 |
| **Lookup / reference / type-list** | No | Codes and descriptions — no history |
| **An already-built Zone2 target table** | **Yes** | Creates a knock-on effect — see §7 |

---

## 6. The open question (Q1)

**Is a current-bucket table dated or undated?**

The team's answer is **undated** — one row per key, showing today's value only. To be confirmed with
Nidhika.

| If current bucket is... | Then |
|---|---|
| **Undated** (team's answer) | Only history-bucket tables can cause the problem. Smaller problem. |
| **Dated** | Current-bucket tables can cause it too — **and bring two extra failures** (§7, "quiet corrections" and "vanishing versions"). |

**How to check without waiting for anyone**: on any current-bucket table, run

```sql
SELECT COUNT(*), COUNT(DISTINCT <business_key>) FROM <current_bucket_table>;
```

Same number → undated. Bigger first number → dated.

---

## 7. The things that go wrong

Five apply to every problem case. Three depend on the open question or on which tables are involved.

### Always

**1. Neither table's dates are enough.** Covered in §3.

**2. Yesterday's rows must be broken apart.** Covered in §4. This is the expensive one — and it does **not**
happen on the very first (history) load, because there is nothing there yet to break.

**3. One table starts before the other.** In §3 there is a period (9-Sep to 10-Sep) where Table 2 has a
value and Table 1 has nothing.

> **Open decision:** do we keep that row with a blank for Table 1, or drop it? The screenshot keeps it. The
> call discussed it and never decided. **This changes the output of every problem case** and needs an answer.
> The same question applies at the end, if one table's record is deleted while the other continues.

**4. Several versions arrive at once.** Multiple loads in a day, or a catch-up after being down for two
days, can deliver two versions with the same from-date. Rule from the call: take the latest one. This has to
happen *before* the dates are combined.

**5. A change we don't care about creates a split we don't need.** If Table 2 changes a column that never
reaches the target, it still produces a new from-date — and we'd split the target into two identical rows
for no reason. Nidhika's wording: *"maybe the non-key that you have to take to the target is still intact,
only some other values have changed — in this case it is not a real split."*

### Only if current-bucket tables turn out to be dated

**6. Quiet corrections.** The source decides an old value was wrong and fixes it — dates unchanged, value
changed. A history-bucket table keeps both the old and new claim, so you can see it happened. A current
bucket only ever shows the latest claim, so the only way to notice is to compare against what you already
loaded.

**7. Vanishing versions.** Worse. If the source *removes* a version — merges two periods, deletes a
correction — a current-bucket table just stops showing it. There is no record that it was ever there.

We find changed records by looking for rows whose timestamp has moved. **A row that no longer exists has no
timestamp to find.** So that key never gets picked up, the wrong target rows stay in place, and no future
run will ever notice.

This is the strongest reason to confirm Q1 rather than assume.

### Only with particular table types

**8. Two tables measuring time differently.** If Table 1's dates mean *"when it happened in the business"*
and Table 2's dates mean *"when we loaded it"*, combining them gives a timeline that is neither.

*Example:* the real change happened on 11-Sep, but we only loaded it on 18-Sep. The target will say the
value changed on 18-Sep. Ask "what did this look like on 12-Sep?" and you get the old value back — wrong,
and nothing in the output warns you which columns are business-timed and which are load-timed.

**This cannot be fixed later by any query.** The information simply isn't there. It needs a decision, not
code.

**9. Knock-on rebuilds.** If one of the tables we join is an already-built Zone2 target, then this load
can't run until that one is finished and correct. And if that table later gets its rows broken apart (§4),
everything built on top of it has to be rebuilt too.

---

## 8. The full picture

| Table 1 | Table 2 | Target | Problem? |
|---------|---------|--------|----------|
| Dated | Undated | Type 2 | **No** — today's pattern |
| Dated | Lookup | Type 2 | **No** — today's pattern |
| Undated | Undated | Type 2 | **No** — but where do the target's dates come from? Probably load date. Confirm this is already solved |
| **Dated** | **Dated** | Type 2 | **YES** |
| Dated | Dated | Type 1 | **No** — no history to keep, just take the latest |

Three or more dated tables: same problem, more dates to combine, every issue above gets worse.

---

## 9. Four decisions that would shrink the problem

Each of these removes cases rather than solving them. Worth putting to Nidhika before any build starts.

1. **Say that only history-bucket tables may set the target's dates.** Makes the Q1 answer stop mattering
   for design, and removes issues 6 and 7 completely.
2. **Say that all tables setting dates for one target must measure time the same way.** Removes issue 8.
3. **Treat load-timed tables as attributes only** — attach their values, but don't let them create dates.
   Stronger version of (2).
4. **Split `is_del` into two flags, or add a reason.** Right now the same flag means both "this row was
   replaced by a correction" and "this record was deleted at source". Downstream can't tell them apart.

**Option 1 is the most useful** — it makes the design safe whichever way Q1 turns out.

---

## 10. Questions still open

| # | Question | What it decides |
|---|----------|-----------------|
| Q1 | Is a current-bucket table dated or undated? | Whether current-bucket tables can cause the problem |
| Q2 | Keep or drop periods where one table has no value? | The output of **every** problem case |
| Q3 | Can a source *remove* a version, or only add and correct? | How serious issue 7 is |
| Q4 | Does Zone1 build history-bucket tables for sources that overwrite in place? | Whether issue 8 is real |
| Q5 | Is "undated + undated → Type 2 target" already a solved pattern? | Whether it stays in scope |
| Q6 | Are Type 1 and Type 2 the only target types? | Whether the list above is complete |
| Q7 | Do we need to handle a join that returns many rows per key per date? | Probably a separate problem |
| Q8 | Is joining to an already-built Zone2 table in scope? | Whether issue 9 needs designing |

**For the asset list**: deciding whether a table is "dated" for a *particular target* needs to know which
columns actually reach that target — which is per-mapping information, not something you can see from the
table itself. Worth telling Abhi before he builds the list.
