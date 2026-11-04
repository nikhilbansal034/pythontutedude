# C5 — **INFORMED, NOT DECIDED** — and the real risk is not the one we framed

**Run**: 2026-11-04 01:56 UTC. **Evidence**:
`../C5_10_c5_region_name_provenance_20261104-015658.json` — 25 statements.

The mechanism choice is an IDMC/orchestrator decision, outside what a SQL script can settle. What
this run **did** settle is the failure modes, and one of them changes how C5 should be framed.

## All three candidates work — the choice is about where a mistake can be made

| Candidate | Works | Keeps R2's signature | Caller can get it wrong |
|---|---|---|---|
| **A.** Literal argument | yes | **yes** | yes |
| **B.** Derived from deployment | yes | no | no |
| **C.** Config row per deployment | yes | no | no |

Candidate C is the only one that is **both** caller-proof **and** identical function text
everywhere — the combination R8 originally promised. But B and C both change the agreed signature
from `f(region_name, sequence_name)` to `f(sequence_name)`, which is Nidwika's call, not ours.

## The failure modes

| Input | Result | Error raised? |
|---|---|---|
| Typo — `'Noth America'` | `NULL` | **no** |
| Wrong case — `'NORTH AMERICA'` | `NULL` — **matching is case-sensitive** | **no** |
| `NULL` region name | `NULL` | **no** |
| **Valid name, wrong region — `'EU'` in the NA deployment** | **`2000000000000007`** | **no** |

A nullable key column accepted **10 rows with 10 NULL keys and reported success**. With `NOT NULL`:

```
DML operation to table TARGET_NOTNULL_V10 failed on column EMPLOYEE_ID
with error: NULL result in a non-nullable column
```

The whole statement rolled back — all-or-nothing, which matters for partial-failure cases.

## The finding that reframes C5 (F35)

> `2000000000000007` is **structurally perfect**. It is unique, it decodes cleanly to region 2, and
> it passes every test in this entire pack. **And it is wrong** — issued by the North America
> deployment because the caller supplied `'EU'`.

No `NOT NULL` catches it, because it is not NULL. **The traceability goal that motivated this whole
change is defeated precisely in the case where it would matter most** — someone tracing a record
back would be sent to the wrong region with complete confidence.

This makes C5 a **design question**, not a configuration detail.

## Two cheap controls close both holes, and they compose

1. **`NOT NULL` on the key column** — turns silent corruption into a failed load.
2. **A per-deployment guard** — the function verifies the requested region against a config row.
   Proven at T10.7: correct region yields a key; `'EU'` and the typo both yield `NULL`.

The guard turns *wrong* into *nothing*; `NOT NULL` turns *nothing* into *stop*.

**Adopt both regardless of which candidate is chosen** — which means the mechanism decision blocks
nothing.

## Also worth deciding deliberately (F36)

Region-name matching is **case-sensitive**. Options: `UPPER()` both sides inside the function, store
a normalised key, or make the exact strings part of the orchestrator contract. `NOT NULL` catches it
either way, so this is robustness rather than a correctness gap.
