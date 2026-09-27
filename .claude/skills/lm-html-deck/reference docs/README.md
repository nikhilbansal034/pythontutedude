# The reference `.html` decks belong here

`SKILL.md` names three files in this folder and instructs Claude to open them directly:

| Expected file | Present |
|---|---|
| `premium-cde-monitoring-deck.html` | **NO** |
| `HISTORY-LOAD-DESIGN.html` | **NO** |
| `../POC/ABC framework/claude/abc_framework_deck.html` (deck 3, deprecated) | **NO** |

Drop them in and nothing else needs changing — the paths already match.

## What is available without them

The two breakdown files in `../references/` carry enough to build a faithful deck:

- **Exact colour tokens.** `deck-01-premium-cde-monitoring.md` §5 lists every `:root`
  value (`--navy #012169`, `--teal #0097A9`, the `--g1…--g11` ramp, the semantic
  chip colours). Copy those; do not approximate.
- **Exact font stacks.** `"Open Sans","Segoe UI",Calibri,Arial,sans-serif` for text,
  `Consolas,"Courier New",monospace` for mono. No external font links, deliberately.
- **The full diagram vocabulary.** `deck-02-history-load-design.md` §3 documents every
  class (`.box`/`.box.alt`/`.box.grey`/`.box.warnb`, `.band`, `.arw`/`.arw.d`, `.nb`/`.nt`,
  `.brk`) and eleven diagram archetypes with the situation each suits.
- **Slide archetypes and disciplines**, per deck and shared.

## What is NOT available, and what that means

The literal CSS and JavaScript bodies. `SKILL.md` gives the stage engine only in prose
and to approximate precision — `fitStage()` "clamped roughly 0.2–1.35", `fitContent()`
"floor ~0.55". Those are descriptions, not code.

So a deck built from the breakdowns alone will match the documented **visual system**
exactly (colours, type, component semantics, diagram vocabulary) while its **shell
mechanics are a reimplementation**, not the reference file's code copied verbatim.
That distinction matters because `SKILL.md` asks for verbatim copying specifically to
stop prose-to-code drift. Say which of the two you did when handing a deck over; do not
claim verbatim fidelity to a file that was never read.
