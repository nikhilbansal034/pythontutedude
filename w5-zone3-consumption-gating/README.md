# POC07 — `Nikhil - 2`

Everything for this deliverable is in this one folder. Nothing it produces is written
anywhere else.

```
Nikhil - 2/
  tests/      the 12 SQL files under test        (00_setup, s01..s10, 99_teardown)
  scripts/    the harness that runs them
  evidence/   what came back: the deck, and one JSON per file
  CHANGES.md  every change made to the SQL, and why
  README.md   this file
```

---

## What this is

`NIkhil/` (the folder beside this one) holds the original SQL suite as received. **It is
untouched.** `Nikhil - 2/` is a corrected copy that has actually been executed, with the
results captured.

The suite tests the same thing as [`POC07_DESIGN.md`](../POC07_DESIGN.md) — publishing a
whole domain only when its batch is complete, by rebuilding into a staging schema and
swapping it with live — but it was written independently and uses its own object model
(`P7_POC`, seven `P7_*` roles) and its own case ids (`TC-01.1`...). The map between its
50 cases and the design's 42 tests is in
[`POC07_TEST_DESIGN.md`](../POC07_TEST_DESIGN.md) section 10, and is also a tab in the
deck.

---

## Start here

Open **`evidence/LM_Batch_Publishing_Evidence_POC07.html`** in a browser. It is
self-contained — no network, no CDN, no separate asset files — so it can be mailed or
copied anywhere and will still render. Five tabs:

| Tab | What is in it |
|-----|---------------|
| 1 In brief | The counts, per scenario and per case |
| 2 Findings | The two failures, what they mean, and the 12 cases that need a human reading |
| 3 Evidence | Every graded check: verbatim SQL, who ran it, what came back, the expectation, the verdict |
| 4 Traceability | Which of the design's 42 tests this run covers — and the 20 it does not |
| 5 Scope & limits | What this run does **not** prove. Read this before quoting the pass count |

`evidence/LM_Batch_Publishing_Evidence_POC07.md` is the same scorecard as plain text, for
pasting into a mail or a ticket.

---

## The result

Run end to end on **27 October 2026** against `pn56976-deloittena`, warehouse
`LM_PII_POC_WH`.

| | |
|---|---|
| Test cases | **50** |
| Passed | **33** |
| Failed | **2** — both genuine findings, not defects |
| Errored | **0** |
| Need a human reading | 12 |
| Not graded | 3 — they set up state a later case verifies |
| Statements captured | 1,674 across 11 files |

### The two failures are results, not breakage

- **`TC-04.3`** expected 2 tag rows and got **0**. The case before it does a *plain*
  `CREATE OR REPLACE`, which strips the tags; this one rebuilds with `COPY TAGS` and
  copies from that now-untagged table. This independently reproduces the design's central
  finding (`T40`): **`COPY TAGS` takes its tags from the table it replaces, so once they
  are gone a rebuild cannot bring them back** — only re-tagging can.
- **`TC-04.5`** expected no grants on a first build and found a `SELECT` from the **future
  grant**. The case's premise — that `COPY GRANTS` leaves a bootstrap gap — is
  contradicted by its own evidence. Support for the design's `D24`/`T41`.

Both are written up in `CHANGES.md` section 4 and in the deck's Findings tab.

---

## Re-running it

Needs Python with `snowflake-connector-python`, and a connection named
`pn56976_psingh` in `~/.snowflake/connections.toml`. Change `CONNECTION` in
`scripts/poc07_names.py` to use a different one.

```bash
cd scripts

python run_poc07_tests.py --list          # inventory only, no connection made
python run_poc07_tests.py --file 00_setup  # build the environment  (run once, first)
python run_poc07_tests.py --all            # the ten scenarios, in order
python capture_evidence.py                 # rebuild the deck from the JSONs
python run_poc07_tests.py --file 99_teardown   # remove everything
```

Order matters. `00_setup.sql` must run first. Each scenario then resets the swap pair and
the control tables back to day 1, so the ten are independent of each other — but **the
capture for one must be written before the next one truncates the control tables**, which
is why `--all` runs them in sequence rather than in parallel.

Expect `--all` to take about 25 minutes: ~1,700 statements at one session round trip each,
plus `s09`'s deliberate `SYSTEM$WAIT` loops.

### What the four scripts do

| File | Role |
|------|------|
| `poc07_names.py` | Every account-specific name, path and role in one place. Nothing else hardcodes one |
| `run_poc07_tests.py` | Executes a file statement by statement in **one session**, honours the inline `USE ROLE` switches, and records each result against its test case |
| `poc07_expect.py` | Turns each `/* EXPECT ... */` note in the SQL into a verdict. **`REVIEW` is the default** — it never guesses, and never defaults to a pass |
| `capture_evidence.py` | Renders the JSONs into the HTML deck. A pure renderer: it re-queries nothing |

Two things worth knowing about the harness:

1. **It injects two statements after every `USE ROLE`**, and records that it did.
   `USE SECONDARY ROLES NONE`, because this operator's account carries POC01's
   `LM_PII_TAG_ADMIN` and `LM_PII_POLICY_ADMIN` as *active* secondary roles — without it
   a privilege check could pass through a role other than the one under test, which is
   the flaw behind POC02's retracted `P2-F1`. And `USE WAREHOUSE`, because no scenario
   file issues one, so every query would otherwise fail on the wrong warehouse rather
   than on anything being tested.
2. **`capture_evidence.py` deliberately does not re-query Snowflake.** POC02's generator
   does, which is right for POC02. Here every scenario opens by resetting to day 1, so a
   re-querying generator would destroy the environment — and the earlier scenarios'
   evidence — each time it ran.

---

## Why the SQL needed changing first

The suite had never been run. **Eleven defects stopped it**, and nine were the same
mistake: *a statement left running under the wrong role*. Snowflake drops the database
context when you switch to a role with no `USAGE` on it, and a reader role deliberately
cannot see the published tables — so a check that follows a reader check, or a
`USE ROLE SECURITYADMIN`, fails on privileges rather than on anything being tested. None
of it is visible by reading unless you track the in-force role line by line.

The largest two:

- **58 unqualified grants** across all ten scenarios. These are what give
  `P7_VIEW_OWNER` access to the published tables, so the reader views could not be
  created and *every* reader check in *every* scenario failed.
- **44 tag checks that never filtered to the `PII` tag.** The reset sets a schema-level
  tag, Snowflake inherits it onto every column, and `TAG_REFERENCES_ALL_COLUMNS` reports
  inherited tags — so a six-column table returned 8 rows where 2 were expected. POC02 hit
  this same trap and left a comment about it that did not travel to this suite.

Every change is in `CHANGES.md` with the error text that justified it. Two apparent
failures turned out to be **the harness being wrong, not the SQL** — `s07` and `s08` put
their "EXPECTED TO FAIL" note *before* the statement, and the harness only read notes that
followed one. Those are recorded too.

---

## Before you quote the pass count

Read the deck's **Scope & limits** tab. The short version: no gate is actually enforced
anywhere in this suite — every gate is a `SELECT` a human is expected to read before
running the next statement by hand. There is no stored procedure, so the design's
owner's-rights questions cannot be answered here, and `T12` — graded the most important
test in the design — has no real counterpart. Identity is a role switch rather than a
service principal, masking is one `STRING` policy keyed on `CURRENT_ROLE()` rather than
POC01's proven three-policy model, and volume is 20 customers.

`33 of 50` is an accurate count of what was tested. It is not a statement that the
approach is proven.
