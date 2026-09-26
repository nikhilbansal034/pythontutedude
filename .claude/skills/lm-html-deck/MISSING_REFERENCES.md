# The reference files this skill depends on are not in this repository

`SKILL.md` is written as a **pointer** to proven reference decks, and is explicit that the
prose is not the source of truth:

> Then open the specific reference file(s) named below directly — copy their CSS/JS verbatim
> rather than retyping from memory or from this file's prose. […] the reference `.html` files
> are the source of truth for *the exact values*.

None of those files is present here. Checked 2026-09-26:

| Referenced by SKILL.md | Present |
|---|---|
| `reference docs/premium-cde-monitoring-deck.html` | NO |
| `reference docs/HISTORY-LOAD-DESIGN.html` | NO |
| `POC/ABC framework/claude/abc_framework_deck.html` | NO |
| `references/deck-01-premium-cde-monitoring.md` | NO |
| `references/deck-02-history-load-design.md` | NO |

There are **zero** `.html` files anywhere in the repository.

## What this means

The skill cannot be followed as written. Its ship checklist requires
*"Colors used are the reference deck's actual token values (copied from its `:root`), not
approximated"* — which is unachievable without the files. Building a deck from the prose alone
would produce exactly the drift the skill was written to prevent, while appearing to comply.

## To resolve, either

1. **Add the reference files** to this repo at the paths above, or
2. Treat the next deck as a **new baseline**: build it, then document it as
   `references/deck-03-<name>.md` and add a catalog row, per SKILL.md's own
   "Extending this skill" workflow.

Until one of those happens, any deck built here is a new visual identity, not a continuation
of decks 1 or 2 — and should be described that way rather than implying it matches a house
style it was never able to read.
