# Reference inventory

Checked 2026-09-26. **Complete — nothing missing.**

| Referenced by SKILL.md | Present |
|---|---|
| `reference docs/premium-cde-monitoring-deck.html` | **YES** (37 KB) |
| `reference docs/HISTORY-LOAD-DESIGN.html` | **YES** (515 KB) |
| `references/deck-01-premium-cde-monitoring.md` | **YES** |
| `references/deck-02-history-load-design.md` | **YES** |
| `POC/ABC framework/claude/abc_framework_deck.html` | NO — deck 3, already deprecated by the user's 2026-09-22 direction |

Both reference decks carry the real `fitStage()` / `fitContent()` / `.slide-inner` shell code
and their full `:root` token sets (20 and 22 tokens), so SKILL.md's instruction to *"copy
their CSS/JS verbatim rather than retyping from memory or from this file's prose"* can be
followed literally. Do that — the breakdowns in `references/` describe what is there and why;
these two files are the source of truth for the exact values.

## One reading caution

`HISTORY-LOAD-DESIGN.html` has a longest line of ~168,000 characters: embedded base64
screenshots. Strip lines over a few thousand characters before reading it with a text tool,
as `references/deck-02-history-load-design.md` notes at its top. The images carry no
information a prose summary cannot, and they will consume a large amount of context.
