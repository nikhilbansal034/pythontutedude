# How the prefix schemes actually work — mechanism first, numbers last

Written in response to Nidwika's feedback that the duplicate counts were quoted without the
rationale behind them. **She is right.** "198 duplicates" is evidence, not an explanation, and a
number without a mechanism cannot be argued with or trusted.

This document explains what each scheme *is*, how it works step by step, and **why** one of them
breaks. The measurements come at the end, as confirmation of something already reasoned through.

**Decision, taken 2026-11-04: Scheme B — fixed-width offset, sequence field width 15 (`D5`).**
§5 is the principle it rests on; §6 is the one derived requirement still worth confirming; the
head-to-head that drove the choice is slide 6 of `requirement_deck.html`, and
`SCHEME_A_AND_VARCHAR.md` covers why the "region codes never exceed 9" assumption does not change
the answer.

---

## 1. What the prefix is for

Each region runs its own Zone 2 with its own sequence, and **every one of those sequences starts at
1**. So North America issues employee 1, and EU also issues employee 1. Inside each region that is
fine — they are separate databases.

The problem appears at **consolidation**. §3 of the transcript describes regions being merged into a
global database. At that moment two different employees both claim identifier `1`.

The prefix exists to make the identifier **globally unique at the point it is created**, so nothing
has to be renumbered later. That is the whole design.

Two properties follow from that, and they are the two things any scheme has to deliver:

| | What it means | What breaks without it |
|---|---|---|
| **R12** | Every key is unique across **all** regions, for all time | Two employees share one primary key in the global database. A merge either rejects rows or silently conflates two people |
| **R13** | Given a key, you can tell **which region issued it**, without looking anything up | §3's stated reason for the whole change — tracing a bad record back — stops working. You would need the UUID or a lookup, which is exactly what Nidwika said she wanted to avoid |

**Neither R12 nor R13 is written in the transcript.** We derived them from §3's argument and wrote
them down so the schemes could be judged against something. That is why they need confirming — see
§6.

---

## 2. Scheme A — digit concatenation

### What it is

Treat both parts as **text**, and glue them together.

```
region code  "1"      sequence value  "42"
                  ->  "142"  ->  142
```

### How it works, step by step

1. Convert the region code to text: `1` → `"1"`
2. Convert the sequence value to text: `42` → `"42"`
3. Join them: `"1" || "42"` = `"142"`
4. Cast back to a number: `142`

To read the region back out, you take the **first character** and call it the region.

### Why it works today

Today there are three regions, with codes **1, 2, 3** — all single digits. The region therefore
always occupies **exactly one character**, so "take the first character" is always correct.

**It works by accident of the current data, not by design.**

### Where it breaks, and why

The moment a region code has **two digits**, the join point becomes ambiguous. Nothing in the key
records where the region ends and the sequence begins.

```
region 11, sequence 1    ->  "11" || "1"   ->  "111"
region  1, sequence 11   ->  "1"  || "11"  ->  "111"
                                                 ^^^ the same key
```

Two different employees, in two different regions, with one primary key. **R12 fails.**

And asked which region issued `111`, the first-character rule answers `1` — which is wrong half the
time. **R13 fails too.**

### The real reason, stated plainly

**The region field has no fixed width.** A key is a sequence of digits with no marker separating the
two parts, so the parts can only be separated if one of them has a known, constant length. Under
concatenation, neither does.

This is **not** a problem with using text. It is a problem with using a **variable-width** field.
See Scheme C.

---

## 3. Scheme B — fixed-width offset

### What it is

Reserve a **fixed number of digit positions** for the sequence value, and put the region code above
them using arithmetic.

```
region code 1,  sequence 42,  field width 15

        1 × 1,000,000,000,000,000  +  42
     =  1,000,000,000,000,042
        ^                  ^^
        region             sequence occupies the low 15 positions
```

### How it works, step by step

1. Multiply the region code by 10¹⁵ — this shifts it above every possible sequence value
2. Add the sequence value — it lands in the low 15 positions, which the multiplication left empty
3. Cast to the target type

To read it back:

```
region   = key ÷ 10¹⁵   (integer division)   ->  1
sequence = key mod 10¹⁵                      ->  42
```

### Why it does not break

The sequence **always** occupies exactly 15 positions — padded with implicit zeros when it is
small. The boundary is therefore at a known, constant place, and the region code can grow to two or
three digits without ever touching the sequence field.

The same case that broke Scheme A:

```
region 11, sequence 1   ->  11,000,000,000,000,001
region  1, sequence 11  ->   1,000,000,000,000,011
                                   different keys
```

**R12 holds.** And division recovers the region exactly, whatever its digit count — **R13 holds.**

### What it costs

- Keys are large: a region-1 key is 16 digits, a region-12 key is 17
- The field width **can never be changed** once keys are issued. Changing 15 to 16 renumbers every
  key ever created
- Each region can issue 10¹⁵ keys — a quadrillion — so the width is not a practical limit

---

## 4. Scheme C — zero-padded concatenation *(new, for VARCHAR targets)*

Nidwika's Q3 point: the surrogate key column is **not always `NUMBER(38,0)`**. Another table's key
could be `VARCHAR`. The reference Q2 alone casts 27 columns to `VARCHAR`.

That matters here, because Scheme B is arithmetic and arithmetic needs a number. So for a `VARCHAR`
target there is a third option — **and it is Scheme B's principle expressed as text**.

### What it is

Pad **both** parts to a fixed width, then concatenate.

```
region code 1  -> "01"   (padded to 2)
sequence   42  -> "000000000000042"   (padded to 15)
                  "01000000000000042"
```

### Why it does not break

The padding is what Scheme A was missing. The region now **always** occupies exactly two characters:

```
region 11, sequence 1   ->  "11" || "000000000000001"  ->  "11000000000000001"
region  1, sequence 11  ->  "01" || "000000000000011"  ->  "01000000000000011"
                                                             different keys
```

Decoding is `LEFT(key, 2)` and `RIGHT(key, 15)` — fixed positions, so it always works.

---

## 5. The principle, which is the thing worth remembering

> **The schemes do not differ by arithmetic versus text. They differ by fixed width versus variable
> width.**

| Scheme | Region field | Safe? |
|---|---|---|
| **A.** Digit concatenation | **variable width** | **No** |
| **B.** Fixed-width offset (numeric) | fixed | Yes |
| **C.** Zero-padded concatenation (text) | fixed | Yes |

Scheme A is not bad because it uses strings. It is bad because the region code's length is allowed
to vary, which destroys the boundary between the two parts of the key. B and C are **the same idea
in two datatypes** — which is why Q3's variable target type does not force a different decision, it
just picks which expression of the same principle to use.

**Recommendation:** fixed width always. Use B where the target column is numeric, C where it is
text. Width 15 for the sequence field, 2 for the region field.

---

## 6. What R12 and R13 protect, and why we need them confirmed

These were **derived**, not stated. Before using them to eliminate a scheme, they should be agreed.

### R12 — global uniqueness

**What it protects:** the primary key of the consolidated global table.

**What failure looks like:** at consolidation, two regional rows carry identical `EMPLOYEE_ID`.
Either the load rejects them, or — if nothing enforces uniqueness — two different people are merged
into one record and nobody notices.

**Is it really required?** Almost certainly yes: a surrogate key that is not unique is not a key.
The question is only whether consolidation enforces it or relies on it.

### R13 — region recoverable from the key

**What it protects:** §3's stated motivation. Nidwika's own argument was that if the prefix is added
later, tracing a record back requires the UUID or prefix-stripping logic. R13 is that argument
written as a requirement.

**What failure looks like:** someone sees key `111` in the global database and cannot tell whether
to go and look in North America's system or Benelux's without joining to something else.

**Is it really required?** This is the genuine question. If a lookup is acceptable — if the global
database will always carry a region column alongside the key — then R13 is a convenience rather
than a requirement, and Scheme A's decode failure stops being disqualifying. **It would still fail
R12**, so the recommendation would not change — but the argument for it would rest on one leg
instead of two.

---

## 7. The measurements, now that the mechanism is clear

All three schemes over the **same** population: twelve regions, 400 keys each, 4,800 total. Region
codes 1–12, so three of them are two digits.

| | A. Concatenation | B. Fixed-width offset |
|---|---|---|
| Duplicate primary keys | **198** | **0** |
| Keys decoding to the right region | 3,600 of 4,800 | **4,800 of 4,800** |
| Key width | 2–5 chars, varies with the **value** | 16–17, varies only with the **region code** |

**What the 198 is.** Every pair where one region's code is a prefix of another's combines with
sequence values that make the concatenations identical. Codes 1 and 11 collide, codes 1 and 12
collide, and so on — 198 such pairs within 400 values per region.

**What the 1,200 is.** Exactly three regions × 400 keys. Every key belonging to a two-digit region
decodes to the wrong region under the first-character rule. It is not a sample or an estimate — it
is all of them.

A worked example from the run:

```
key 111  ->  Benelux       employee 1    (code 11, sequence 1)
             North America employee 11   (code 1,  sequence 11)
```

**And independently**, from the legacy-key run: under concatenation the smallest possible new key is
`11`, which is *itself* an existing legacy key — 999 collisions with rows already in the table. Two
unrelated failures, so eliminating Scheme A does not rest on a single test.

---

## 8. What this changes about the deck

The current deck leads with the duplicate counts. It should lead with **§2–§5 of this document** —
what each scheme is, worked through, and *why* one breaks — and present the numbers only as
confirmation.

The C3 slide should offer **three** options, not two, now that Q3 has established the target type
varies: concatenation (rejected, with the reason), numeric offset, and padded text. And it should
state the unifying principle rather than presenting them as unrelated alternatives.
