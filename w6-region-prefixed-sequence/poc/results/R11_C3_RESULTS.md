# R11 + C3 — **R11 PROVEN. C3 SETTLED BY DATA.**

**Run**: 2026-11-04 01:41 UTC. **Evidence**: `../R11C3_08_r11_c3_region_growth_20261104-014124.json`
— 25 statements, no deviations, two sensitivity gates opened.

| Test | Result | Verdict |
|---|---|---|
| T8.1 | 4th region resolved; function `CREATED` = `LAST_ALTERED` **to the millisecond** | **R11 PROVEN** |
| T8.2 | 12 regions, 3 two-digit codes; 4800 rows, 400 distinct, **4400 collisions** | **GATES OPEN** |
| T8.3 | Offset: 4800 / 4800 / **0 duplicates**, widths 16–17 | **PASS** |
| T8.4 | Concat: 4800 / 4602 / **198 duplicates**, widths 2–5 | **FAILS, by design** |
| T8.5 | Offset decodes 4800/4800; concat **3600/4800** | offset **PASS**, concat **FAIL** |
| T8.6 | `NUMBER(38,0)` never binding; 64-bit consumer is | **width 15** |

## R11 — proven objectively, not just plausibly

Growing from 3 to 12 regions took **twelve rows of data and zero lines of code**. The decisive
evidence is not that the new region resolved — it is that `INFORMATION_SCHEMA.FUNCTIONS` reports
`CREATED` and `LAST_ALTERED` **identical to the millisecond**, so the code is provably unchanged.

That query is worth lifting into a release check, alongside R10's volatility check.

## C3 — concatenation produces duplicate primary keys

198 duplicates from the same 4,800 rows that offset handled with zero:

```
key 111  ->  Benelux       employee 1    (concat(11, 1))
             North America employee 11   (concat(1, 11))
```

And it misdecodes **1,200 of 4,800** keys — exactly the three two-digit regions × 400 rows. So R13
only holds under offset once codes reach two digits.

**Two independent failures.** Concatenation fails on region growth here *and* on legacy coexistence
in the C6 run (999 collisions). Eliminating it does not rest on one test.

Note the asymmetry in "variable width": offset's 16→17 varies with the **region code** and is
positional, so it stays decodable. Concatenation's 2→5 varies with the **value**, which is what
destroys the boundary.

## Field width — the binding constraint is not what we assumed

`NUMBER(38,0)` fits every width from 12 to 19. What actually bites:

| Width | Keys/region | 64-bit downstream |
|---|---|---|
| **15** | 10¹⁵ | **safe** — region-12 key is 1.3% of the ceiling |
| 18 | 10¹⁸ | **overflows a Java `long`** at a two-digit code |
| 19 | — | exceeds the 64-bit **sequence** ceiling |

**Recommendation: width 15**, pinned now.

## Script defect (F29)

T8.6's `largest_key_digits` column is unreliable at widths ≥ 15 — `POWER()` returns a float and the
string length is wrong. **No effect on the conclusion**: the two columns that matter use numeric
comparisons. The digit counts in that one column should not be quoted.
