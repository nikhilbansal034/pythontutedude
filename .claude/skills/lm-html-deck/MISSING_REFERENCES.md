# Reference inventory

Checked 2026-09-26, after the two breakdown files were supplied.

| Referenced by SKILL.md | Present | Note |
|---|---|---|
| `references/deck-01-premium-cde-monitoring.md` | **YES** | Carries the exact `:root` palette and font stacks |
| `references/deck-02-history-load-design.md` | **YES** | Carries the full diagram vocabulary and slide archetypes |
| `reference docs/premium-cde-monitoring-deck.html` | NO | |
| `reference docs/HISTORY-LOAD-DESIGN.html` | NO | |
| `POC/ABC framework/claude/abc_framework_deck.html` | NO | Deck 3, already deprecated by the user's 2026-09-22 direction |

There are still **zero `.html` files** in the repository.

## Consequence, stated precisely

The breakdowns are enough to reproduce the **visual system** exactly: every colour token
is documented with its hex value, both font stacks are given verbatim, and deck 2's
diagram vocabulary is documented class by class.

They are **not** enough to satisfy SKILL.md's instruction to *"copy their CSS/JS verbatim
rather than retyping from memory or from this file's prose."* The stage engine exists here
only as prose, with approximate numbers (`fitStage()` "clamped roughly 0.2-1.35",
`fitContent()` "floor ~0.55").

A deck built from the breakdowns therefore has a **faithful visual system** and a
**reimplemented shell**. Both facts should be stated when the deck is handed over. See
`reference docs/README.md`.

To close the gap, add the two `.html` files to `reference docs/` — the paths already match.
