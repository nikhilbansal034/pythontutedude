---
name: lm-html-deck
description: Design system and build process for self-contained HTML slide decks on the Liberty Mutual engagement (design reviews, POC walkthroughs, status decks). This is a living, growing skill — a new reference deck gets appended every time the user hands over one they like. ALWAYS consult this skill before creating, restyling, or extending ANY HTML slide deck for this project, even if the user just says "make a deck", "build a presentation", "turn this into slides", or pastes content and asks for a walkthrough — do not default to a generic slide layout or to Reveal.js/PowerPoint conventions. Also use this when asked to review, critique, or bring an existing project deck in line with "how we usually do it."
---

# LM HTML deck system

This project builds slide decks as single self-contained HTML files — fixed-resolution canvas, JS-driven one-slide-at-a-time navigation, no build step, no framework. Every deck so far shares the same underlying stage mechanics; what changes between decks is the navigation chrome, the visual identity, and which content-placement patterns get used. This skill exists so a new deck starts from an actual proven reference file instead of being invented from scratch each time.

**Read this whole file before writing any deck code.** Then open the specific reference file(s) named below directly — copy their CSS/JS verbatim rather than retyping from memory or from this file's prose. This file describes *what's there and why*; the reference `.html` files are the source of truth for *the exact values*. Prose summaries drift from real files over time — always re-verify against the file when precision matters (an exact hex code, a pixel value, a JS function body).

## Reference decks catalog

| # | File | Visual identity | Nav chrome | Best for |
|---|---|---|---|---|
| 1 | `reference docs/premium-cde-monitoring-deck.html` | Corporate brand palette (navy/teal/green), system fonts, light theme only | **Left sidebar** (white), grouped into named sections (Problem/Requirements/Solution) | Shorter design reviews (~7 slides) that argue from a problem through requirements to a solution, table/card-driven content, formal traceability (numbered requirements, decisions, open questions) |
| 2 | `reference docs/HISTORY-LOAD-DESIGN.html` | Same brand palette, dark-navy sidebar variant, one extra reserved accent (`--blue`) | **Left sidebar** (dark navy), grouped sections, internal-only slides flagged in-nav | Longer, architecture/mechanism-heavy decks (~30 slides) reconstructed from multiple/conflicting source documents — anything needing a real diagram vocabulary (swimlanes, flowcharts, timelines), source-provenance auditing, or a mix of client-facing and internal-only slides in one file |
| — | `POC/ABC framework/claude/abc_framework_deck.html` | Warm paper/ink ledger palette, IBM Plex Sans/Mono via Google Fonts, full light/dark theme support | **Top tab bar**, flat list | Reference/catalog-style decks (table catalogs, mechanism walkthroughs) — pre-dates this skill, kept for context, **not** the default going forward per the user's 2026-09-22 direction |

Deck **1** (`premium-cde-monitoring-deck.html`, breakdown in [`references/deck-01-premium-cde-monitoring.md`](references/deck-01-premium-cde-monitoring.md)) and deck **2** (`HISTORY-LOAD-DESIGN.html`, breakdown in [`references/deck-02-history-load-design.md`](references/deck-02-history-load-design.md)) are both current, both legitimate defaults — pick by fit (table above), not by recency. **Read the relevant breakdown file before building anything**; each documents its sidebar structure, slide-by-slide content-placement patterns, full component catalog, and exact color/font system. This SKILL.md only holds what's common across the whole family plus the workflow — the per-deck detail lives in `references/` so this file doesn't grow unbounded as more decks get appended.

**If the new deck is architecture/mechanism-heavy** (a pipeline, a data flow, a state machine, a decision procedure) **or is being built by reconciling multiple/conflicting source documents, start from deck 2** and its diagram vocabulary (`references/deck-02-history-load-design.md` §3) rather than inventing boxes-and-arrows from scratch — that vocabulary (swimlanes, decision flowcharts, timelines, rollup hierarchies, nested step zoom-ins) is reusable across almost any system-design deck this engagement will need.

If more than one reference deck is on file and it's not obvious which one this new deck should follow, **ask the user** which prior deck is closest in spirit rather than guessing or blending two visual identities.

## What's shared across every deck in this family

Regardless of which reference you're following, all of them are built on the same stage engine:

- **Fixed 1280×720 canvas per slide.** Content is authored at that resolution, not fluid/responsive — this is a presentation artifact, not a webpage.
- **A synthesized `.slide-inner` wrapper.** A script at the end of `<body>` walks every `.slide`, moves its children into a new `.slide-inner` div, wraps all slides in a `.stage`, then drives two scale functions:
  - `fitStage()` — scales the whole `.stage` to fit the browser window (minus nav width), clamped roughly 0.2–1.35. This is what makes the deck usable at any window size.
  - `fitContent(slide)` — if one slide's content is taller than the space available, scales *that slide's* content down (never up, floor ~0.55). This is a safety net for when a slide runs long, not a layout strategy — **do not rely on it to make a sparse slide "fill the space."** Author each slide's font sizes and spacing to look intentional at 100% scale; let `fitContent` stay a no-op on a well-built slide.
  - `show(i)` toggles the active slide and its nav tab, updates prev/next button disabled state, and pushes the slide id to the URL hash.
  - Keyboard: arrow keys / PageUp/PageDown to step, Home/End to jump to first/last, digit keys to jump directly to a slide.
  - A print stylesheet forces one slide per A4-landscape page and disables the JS transform.
- **A `.slide-no` footer** ("3 / 7") pinned to a fixed corner of every slide.

What differs between decks is everything layered on top of this: the nav chrome (sidebar vs. top tabs), the color/type system, and the component vocabulary (chips, callouts, cards) used to place content. Both decks 1 and 2 have a notable refinement worth carrying into every future deck regardless of which visual identity is chosen: they explicitly exclude any bottom-pinned "takeaway" element and the slide-number footer (and, in deck 2, an `.intflag` internal-slide badge too) from the part of the slide that `fitContent` can shrink, so those stay fixed and legible even on a slide whose main content had to scale down. Check whether your chosen reference does this, preserve it, and add any new fixed-position per-slide badge your deck introduces to that same exclusion list.

**A well-built deck should also be readable with JavaScript disabled** (deck 2 makes this explicit): without the script, `.slide` elements are ordinary block boxes that stack and let the page scroll — only the script's `display:none` on inactive slides creates the one-at-a-time paginated mode. Don't build a slide whose *content* depends on the JS running; the JS should only control *pagination*, not visibility of information.

## Non-negotiable disciplines

These aren't visual style — they're what makes a deck in this family read as rigorous rather than as a list of paragraphs with nice fonts. Carry them into every new deck no matter which reference's visual identity you're following:

1. **A one-sentence takeaway per slide, if the reference deck you're following uses one.** Bottom-pinned, high-contrast, phrased as the *so-what* a skimmer should walk away with — never a recap of the slide's own bullets. If you catch yourself writing "This slide covered X, Y, Z" as a takeaway, that's the tell you've restated instead of synthesized.
2. **Stable IDs for anything the deck will refer back to** — requirements, decisions, options, questions (`R1`, `D1`, `Q1`, whatever the domain calls for). Assign the ID the first time the thing is introduced, then reference that same ID via a small pill/tag on later slides instead of re-explaining it. This is what lets a reader trust that "R3" on slide 6 is the same R3 from slide 3, not a fresh claim.
3. **Cite your source.** When a slide's content comes from a specific meeting, transcript, or document, say so in a small muted line — down to a line range or timestamp if you have one. A claim a reviewer can't trace back to where it came from is a claim they'll (rightly) push back on.
4. **Flag the odd one out visually, not just in prose.** When one row in a table or one card in a grid is the exception, the one to set aside, or the one getting its own deep-dive slide next, give it a distinct border/tint rather than only calling it out in the surrounding text. A reader scanning quickly should be able to spot it without reading every word.
5. **Match column-width asymmetry to content asymmetry.** A two-column layout defaults to an even split, but shifts to 55/45 or 60/40 when one side is a short narrative block and the other is a denser table or card grid — don't force equal columns onto unequal content.
6. **Pair every non-trivial diagram with a companion table.** A diagram shows the *shape* of a mechanism; a table with one row per numbered step/arrow gives each step the sentence it needs. Neither substitutes for the other once a diagram has more than 2-3 steps — a reader shouldn't have to guess what an unlabeled arrow means. See deck 2's diagram vocabulary (`references/deck-02-history-load-design.md` §3) for the reusable box/arrow/lane primitives this pairs with.
7. **Treat chip classes as semantic states, not fixed vocabulary.** `ok`/`warn`/`no`/`part` (and `chk` where a reference deck defines it) are colors for *good/caution/bad/partial/needs-verification* — fill each with whatever specific word the claim needs ("Chosen", "Done", "Preferred" are all `ok`; "Blocking", "To confirm" are both `warn`). Don't feel bound to reuse the exact label text a prior deck happened to use.
8. **State how completely a source covers a claim, not just which source it came from.** "Confirmed twice in the recording" and "mentioned once, never discussed further" are different confidence levels a reviewer needs — say which one applies when it isn't obvious.
9. **Document deliberate scope exclusions as their own content, not silence.** If something a reader might expect was consciously left out, say so and say why — don't let the absence speak for itself and invite "why doesn't this handle X."

## Building a new deck — workflow

1. Confirm which reference deck to follow (see catalog above; ask if ambiguous).
2. Read that reference deck's full breakdown in `references/`, then **open the actual `.html` file** and copy its `<style>` block and the navigation/stage `<script>` verbatim as your starting point — don't retype the CSS from memory or from this skill's prose.
3. Draft the deck's narrative shape first: what are the sections (the sidebar/tab groupings), what's the one thesis sentence for the cover, what IDs will this deck need (requirements? decisions? options?). Get this right before touching layout — the structure in the nav and the agenda both need to mirror it.
4. Build slide by slide, matching each slide's content to the closest analogous slide type documented in the reference breakdown rather than inventing a new layout per slide — deck 1 has cover+agenda, problem statement, requirements+decisions, options comparison, feature inventory, capability deep-dive, closing answers+next-steps; deck 2 adds source-inventory, causal-reasons grid, negative-scope, screenshot-as-evidence, applicability matrix, data-dictionary, decisions-log capstone, and source-conflicts audit, plus a full diagram vocabulary for anything mechanism-shaped. Reuse the component vocabulary (chips, callouts, cards, diagram primitives) the reference deck already defines instead of adding new one-off CSS.
5. Apply the non-negotiable disciplines above regardless of which visual identity you followed.
6. Render it in a browser and check the ship checklist below before calling it done.

## Ship checklist

*(Append to this list — don't replace it — whenever a new reference deck teaches something worth checking on every future deck.)*

- [ ] Every slide's font sizes/spacing look intentional at 100% scale — not relying on `fitContent` to "fill the slide"
- [ ] The nav chrome's section grouping matches the deck's actual narrative arc, and the cover's agenda panel mirrors that same grouping
- [ ] Every requirement/decision/option introduced has a stable ID, assigned once, referenced (not re-explained) later
- [ ] Every slide that should end with a takeaway bar has one, and it's a synthesis sentence, not a recap
- [ ] Claims traceable to a source document/meeting are cited (line range or similarly specific)
- [ ] The one exception/most-important item in any table or card grid is visually distinguished, not just called out in prose
- [ ] Colors used are the reference deck's actual token values (copied from its `:root`), not approximated
- [ ] No content was invented to fill space — a genuinely short slide stays short and looks deliberate, per the reference deck's own density
- [ ] Every diagram with more than 2-3 steps has a companion table or numbered list walking through it step by step (deck 2 §3)
- [ ] The deck is still readable with JavaScript disabled — content isn't hidden by anything other than the pagination script (deck 2 §1)
- [ ] Any diagram whose layout could be mistaken for a scaled quantity (timeline widths, relative sizes) is captioned "illustrative, not to scale" if it isn't actually to scale
- [ ] If the deck mixes client-facing and internal-only content, internal slides are visually flagged (accent color + badge), not just mentally set aside

## Extending this skill

When the user hands over a new reference deck to fold in:

1. Read it fully and render it in a browser, the same way decks 1 and 2 were analyzed. If the file embeds any very long lines (base64 images, minified data), strip those lines before reading with a text tool — they can blow a context budget without adding information a prose summary can't capture (deck 2's file has three such lines from embedded screenshots — see the note at the top of `references/deck-02-history-load-design.md`).
2. Add a new row to the catalog table above.
3. Write a new `references/deck-NN-<short-name>.md` file documenting it the same way `deck-01-premium-cde-monitoring.md` and `deck-02-history-load-design.md` do — shell quirks (if any differ from the shared baseline), nav chrome, slide-by-slide content placement, component catalog, visual system, and **what's different from the prior decks** (don't re-document what's already common baseline).
4. If it introduces a discipline not yet listed under "Non-negotiable disciplines," add it there.
5. Update the ship checklist if it surfaces a new easy-to-miss failure mode.
6. Don't delete or rewrite the previous deck's reference file — each one stays as a distinct, selectable baseline. This file's job is to help choose between them and apply whichever is chosen correctly, not to converge them into one house style by force.
