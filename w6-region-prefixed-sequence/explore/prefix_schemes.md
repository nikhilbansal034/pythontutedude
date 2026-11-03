# C3 — How should the region code combine with the sequence value?

Worked through so the choice can be made on evidence. Everything below is reproducible:

```bash
python3 explore/prefix_schemes.py
```

Simulated in DuckDB on `DECIMAL(38,0)`, which mirrors Snowflake's `NUMBER(38,0)` exactly — so the
arithmetic, the datatype behaviour, the decodability and the overflow limits all carry across.
It does **not** answer C1 or C2; those are Snowflake-specific and need an account.

---

## The two candidates

**Digit concatenation** — glue the digits together, cast back to a number.

```sql
CAST(CAST(region_code AS VARCHAR) || CAST(seq_value AS VARCHAR) AS NUMBER(38,0))
```

**Fixed-width offset** — multiply the region into its own high-order field, add the value.

```sql
CAST(region_code AS NUMBER(38,0)) * 1000000000000000000 + CAST(seq_value AS NUMBER(38,0))
```

Both put the region "in front". They behave very differently.

---

## 1. The datatype concern from §4 is real, and only one scheme has it

| region | seq | raw concatenation | type | fixed-width offset | type |
|---|---|---|---|---|---|
| 1 | 1 | `11` | **VARCHAR** | `1000000000000000001` | `DECIMAL(38,0)` |
| 1 | 123 | `1123` | **VARCHAR** | `1000000000000000123` | `DECIMAL(38,0)` |
| 2 | 123 | `2123` | **VARCHAR** | `2000000000000000123` | `DECIMAL(38,0)` |

This is exactly what Nidwika Vedanaparthi hit: concatenation leaves `VARCHAR` and needs an
explicit cast back to the key's type.

Worth noting where that leads. The datatype change was given in §4 as a *reason to centralise* the
logic. But under fixed-width offset the arithmetic never leaves the numeric domain, so **the
problem does not arise at all** rather than being centralised. The requirement's own motivation
partly dissolves if this scheme is chosen.

## 2. Key length is stable under one scheme and not the other

| region | seq | concatenation | fixed-width offset |
|---|---|---|---|
| 1 | 1 | `11` | `1000000000000000001` |
| 1 | 2 | `12` | `1000000000000000002` |
| 1 | 11 | `111` | `1000000000000000011` |
| 1 | 12 | `112` | `1000000000000000012` |
| 1 | 123 | `1123` | `1000000000000000123` |
| 1 | 999999 | `1999999` | `1000000000000999999` |

Under concatenation the key's magnitude tracks the *number of digits* in the sequence value, so
region 1's keys grow into ranges that overlap other regions'. Under fixed-width offset every
region owns a disjoint numeric band permanently.

## 3. Only one scheme is fully decodable — R13

| true region | true seq | concat → region | offset → region | offset → seq |
|---|---|---|---|---|
| 1 | 1 | 1 | 1 | 1 |
| 1 | 123 | 1 | 1 | 123 |
| 3 | 123 | 3 | 3 | 123 |

Both recover the region today. But concatenation recovers it only by taking the **first
character**, which works solely because every region code happens to be one digit — and it cannot
recover the original sequence value at all, because it cannot know where the region ends.

Fixed-width offset decodes both halves with division and modulo, assuming nothing about digit
counts:

```sql
region_code = key / 1000000000000000000     -- integer division
seq_value    = key % 1000000000000000000
```

## 4. Concatenation has a latent duplicate-key defect — R12

The decisive result. Re-run with **eleven** regions, so codes reach 10 and 12:

```
population tested          4,389 keys (11 regions x 399 values)
CONCAT duplicate keys      99
OFFSET duplicate keys      0
```

| key | rows sharing it | colliding |
|---|---|---|
| `121` | 2 | North America seq=21 \| Benelux seq=1 |
| `122` | 2 | North America seq=22 \| Benelux seq=2 |
| `123` | 2 | North America seq=23 \| Benelux seq=3 |

`concat(1, 23)` and `concat(12, 3)` are both `123`. Two different employees, in two different
regions, sharing one primary key in the global database.

**This is not a theoretical objection.** Concatenation is collision-free *today* only because
there are exactly three regions with single-digit codes. It fails silently the day a tenth region
is onboarded — no error, no constraint violation, just two identities merging. R11 explicitly
requires the mapping to accommodate further regions.

A zero-padded region code (`01`, `02`, …) removes the collision, but then the padding width
becomes the thing that must never change, which is the fixed-width scheme wearing a disguise — and
still as `VARCHAR`.

## 5. Headroom, and the one constraint to pin down

| max region code | largest key | fits `NUMBER(38,0)`? |
|---|---|---|
| 9 | 19 digits | yes |
| 99 | 20 digits | yes |
| 999 | 21 digits | yes |

At an 18-digit field: 999,999,999,999,999,999 sequence values per region, against a 38-digit
ceiling. Ample.

The constraint is `max_region_code × 10^WIDTH < 10^38`, which leaves room for a 19-digit region
code — so headroom is not the risk. The risk is that **WIDTH must be fixed once and never
changed**, because changing it renumbers every key ever issued. It belongs in `requirement.md`,
not in code.

One caveat found the hard way: an earlier draft of the script used `BIGINT` and overflowed at
region code 10, since `10 × 10^18` exceeds `9.22e18`. Snowflake `NUMBER(38,0)` is fine, but any
downstream `BIGINT`/`long` column consuming `EMPLOYEE_ID` would not be. **Check what consumes
`EMPLOYEE_ID` before fixing WIDTH** — a Java or Python consumer, a BI tool, or an export, may
quietly cap at 64-bit.

---

## Summary

| | digit concatenation | fixed-width offset |
|---|---|---|
| Needs a cast back (§4) | **yes — `VARCHAR`** | no, stays numeric |
| Key length stable | no | yes |
| Region recoverable (R13) | only while codes are 1 digit | yes, by division |
| Sequence value recoverable | **no** | yes, by modulo |
| Unique at 3 regions (R12) | yes | yes |
| Unique at 11 regions (R12) | **no — 99 duplicates** | yes |
| Survives a new region | **no, fails silently** | yes |
| Fragile parameter | implicit digit counts | WIDTH, explicit and pinnable |
| Resembles what §1 described | closer — literally a "prefix" | a prefix in a fixed field |

**Recommendation: fixed-width offset.** It is the only one of the two that satisfies R12 and R13
unconditionally, and it removes §4's datatype problem rather than centralising it. Concatenation's
only advantage is that it reads more literally as "prefix the region code", and it carries a
defect that appears silently years later, when the fix is expensive because keys are already in
use downstream.

**Caveat on both.** If C1 resolves such that the key must be minted by a stored procedure
reserving ranges, the arithmetic above is unchanged — the scheme choice is independent of C1, which
is why it can be decided now.
