# Deck 1 — Premium CDE Monitoring

Source file: `reference docs/premium-cde-monitoring-deck.html` (7 slides, single self-contained HTML file, opens directly in a browser). Built for a Snowflake data-quality-monitoring design review — but the *structure* below is what to reuse, not the Snowflake-specific content.

Read the actual file before building — this document explains what's there and why so you recognize the pattern; it is not a substitute for copying the real CSS/JS.

---

## 1. Shell mechanics specific to this deck

Same fixed 1280×720 stage / `fitStage` / `fitContent` engine described in the main SKILL.md, with one deliberate refinement worth preserving in any deck that has a bottom-pinned synthesis element:

The build script that constructs `.slide-inner` explicitly skips elements with class `takeaway` or `slide-no` when moving a slide's children into the scalable wrapper:

```js
slides.forEach(function (sl) {
  var inner = document.createElement("div");
  inner.className = "slide-inner";
  Array.prototype.slice.call(sl.childNodes).forEach(function (node) {
    if (node.nodeType === 1 &&
        (node.classList.contains("takeaway") || node.classList.contains("slide-no"))) { return; }
    inner.appendChild(node);
  });
  sl.insertBefore(inner, sl.firstChild);
});
```

Effect: the takeaway bar and the slide-number footer stay at fixed absolute positions on the slide (`.takeaway` is `position:absolute; left/right/bottom`) and are **never** shrunk by `fitContent`, even when the rest of the slide's content is long enough to trigger a scale-down. Only the scrollable middle content shrinks. `fitContent` also explicitly no-ops on `.cover` slides — the cover is meant to be laid out by hand to fit exactly, not auto-shrunk.

`fitStage` here also subtracts a fixed 240px nav width from the available window width before computing the zoom factor, because the sidebar is fixed-position and doesn't get scaled with the stage.

## 2. Left sidebar navigation

Fixed 240px-wide `.sidenav`, not a horizontal top bar. Structure top to bottom:

1. **`.brandmark`** — the deck's short name plus a colored "." styled as a small dot/period (a minimal logo flourish, not an actual logo image). E.g. `CDE Monitoring<span class="dot">.</span>`.
2. **A vertical list of nav tabs, one per slide, interrupted by section-label dividers.** The dividers (`.navsec`) are uppercase, small, colored, letter-spaced text nodes — e.g. `<div class="navsec">Problem</div>` — placed directly in the tab list between certain `<button class="tab">` elements, **not** every tab gets one. Only the first slide of a new narrative phase gets a preceding label. In the reference deck: slide 1 has no label (it's the cover, sits outside any phase), slide 2 is preceded by "Problem", slide 3 by "Requirements", slide 4 by "Solution" (and slides 5–7 continue under "Solution" with no further label, because they're still part of that same phase).
   - This is the single biggest structural idea to carry forward: **decide the deck's narrative phases before laying out slides**, then group the sidebar (and the cover's agenda, see below) by those phases. A deck with no natural phases (a short catalog or single-topic walkthrough) may not need this grouping at all — don't force phases onto content that doesn't have them.
3. Each `.tab` shows a small 2-digit slide number (`.tnum`, mono-ish, dim, e.g. "01") above the slide's short title, which can wrap to two lines.
4. Selected tab gets: bold text, a tinted background, a left border accent stripe, and the tab-number turns the accent color.
5. Bottom of the sidebar: prev/next buttons plus a small "arrow keys" hint — same idea as the top-tab-bar decks, just relocated.

## 3. Slide-by-slide content placement

The specific topics below are from the Snowflake-monitoring source deck — treat them as *slot names* to fill with your own deck's equivalent content, not literal text to reuse.

### Slide 1 — Cover + agenda (not just a title slide)

Two-column layout, left column ~55% width (`cols c55`).

**Left column:**
- Eyebrow (small caps label naming the domain/category)
- H1 — the deck's thesis phrased as a *claim*, not a topic name (e.g. "Catching unreasonable premium values — not just missing or lost ones", not "Premium Data Quality Overview")
- A short accent-colored rule/divider
- A lede paragraph — the one-paragraph summary of the whole deck's argument, bolding the 2-3 key terms the rest of the deck will build on
- A compact metadata block: bold label + short value pairs, stacked with generous line-height (`Basis` / `Audience` / `Status` in the reference deck — pick whatever 2-4 facts orient a reader before they've seen slide 2)

**Right column — the Agenda panel:**
A bordered box, top-accented, containing:
- A bold "AGENDA" title
- The **same section groupings as the sidebar** (uppercase mini-headers matching the `.navsec` labels), each followed by its slide(s) as numbered items — a small filled square/box holding the slide number, then the slide's one-line topic in bold.

The point of this panel: the sidebar lets a reader navigate the deck's shape by clicking, and the agenda panel lets them read that same shape linearly in one glance before diving in. Building both from the same phase/section decision (not as two independently-invented lists) is what keeps them in sync.

### Slide 2 — Problem statement

Two-column, even split.

**Left:** "today's state" — a small comparison table (e.g. columns: what exists today / what it does / what it misses), followed by a callout-styled statement box naming the actual problem to solve in one or two sentences.

**Right:** a concrete worked example proving the gap, as two stacked "scenario cards" — a good/pass case and a bad/fail case. Each card shows a small row of labeled big-number stats (e.g. "Source sent: 1,000 / Loaded: 1,000") and a verdict-chip row underneath. Below both cards, a callout contrasting what the *old* check actually verifies vs. what's *actually needed* — this is the sentence that reframes the problem.

Takeaway bar: names why both scenarios technically pass today's check even though only one of them is actually fine — the punchline that motivates everything after this slide.

### Slide 3 — Requirements + open decisions

Two-column, asymmetric (`cols c60` — wider left).

**Left (requirements):** one table row per requirement, each with a short bold stable ID (R1, R2, …) in its own narrow column and a plain-language description. Some rows carry a small inline chip flagging that particular requirement as an inference/unconfirmed reading rather than something stated outright.

**Right (open decisions):** a parallel, narrower table of decisions still to be made (D1, D2, …) — same ID-column pattern. Followed by:
- A callout noting sequencing dependency between the two lists if one exists (e.g. "agree D1–D3 first, D4 depends on those")
- A small caption explaining what the "unconfirmed" chip means, so a reader who hasn't seen it before understands it without asking

Every ID minted here gets referenced again on later slides via small pill tags — this slide is the deck's "definitions" slide even though it isn't labeled as one.

### Slide 4 — Options considered

A single wide table, one row per option:
- **Option label** — small "Option N" eyebrow above a bold option name
- **What it is** — plain description
- **Verdict** — a colored status chip (Preferred / Least attractive / Set aside / etc.) plus small pill tags citing which requirement IDs the option satisfies or fails
- **Why** — short justification

Include one extra row for an alternative that was raised but set aside, visually distinguished from the "real" options (e.g. a dimmer label, an "also discussed" eyebrow instead of "Option N"). This keeps a reader from wondering "why isn't this counted as Option 4" — the visual distinction answers that before they ask.

Below the table: a small muted source-citation line, ideally down to line ranges in the source notes/transcript, one clause per option (e.g. "Option 1: lines 146–156 · Option 2: 158–177").

Then a second H3 introduces a horizontal flow strip of process-step cards (STEP 1..N): each a small bordered card with a step name, a one-line description, and a bold "mechanism" line naming the specific tool/feature that actually does that step. This is where the option chosen above gets shown as an actual runnable sequence, not just described abstractly.

### Slide 5 — Capability / feature inventory

Opens with a small horizontal "category strip": several category boxes side by side, with a labeled box on the left naming what the strip represents, and 1-2 of the category boxes visually highlighted/activated to show which subset of a larger taxonomy this deck actually draws on.

Below that: a dense grid (4 columns in the reference deck) of small feature cards. Each card:
- Name, with an optional small inline status chip (e.g. "Preview", "To check")
- A one-line generic description of what the feature does
- A visual divider
- A "For [our use case]:" line in a different tone/color, applying the generic feature specifically to the problem at hand
- A small requirement-ID pill tag at the bottom, tying the card back to slide 3's IDs

One card in the grid gets a distinct accent color/tint to flag it as the most novel or important one — the one about to get its own dedicated deep-dive slide next. This is the same "flag the odd one out visually" discipline applied to a grid instead of a table row.

Below the grid: a small muted caveats line (licensing, edition, prerequisites) with an inline "to check" chip where something is genuinely unverified.

Takeaway bar closes the slide.

### Slide 6 — Deep dive on one capability

Two-column, even split.

**Left:** a numbered ordered-step list explaining the mechanism step by step, using a visually distinct numbered-badge style (a filled square/circle with the number, not the same styling as the requirement table's ID column) — this is deliberately a different visual language from slide 3's tables, because this is "how it works" not "what we require."

**Right:** a callout box with a bullet list of hard constraints/gotchas — minimum data volumes, retraining limits, things it explicitly can't do. Framed as "know before you go," i.e. things that would bite someone who skipped straight to using the feature.

Below both columns: a second H3 introduces a decision-routing table — not another feature list, but a mapping from distinct sub-problems/jobs to "best tool for that job," each row also citing which requirement IDs it satisfies and what prerequisite it needs. This is the slide that answers "given everything above, which tool do I actually reach for, when."

### Slide 7 — Closing: answers + next steps

A table directly answering the open questions raised earlier in the deck (tie each row back to a requirement ID), where the answer cell itself often opens with an inline verdict chip (Yes / Mostly / etc.) before the explanation — so a skimmer gets the verdict without reading the sentence.

Below that, two columns:
- **Left:** a numbered action-item list — what to actually do next
- **Right:** a parallel numbered list of things still needing verification before those actions can complete, visually flagged (e.g. the numbered-badge color itself signals "to check" rather than "to do")

Final takeaway bar: the single bottom-line sentence of the whole deck.

## 4. Component catalog

- **`.chip`** — five semantic states: `ok` (green, resolved/good), `warn` (orange, caution), `no` (red, failed/no), `part` (tinted neutral, partial), `chk` (outlined, needs verification). This is richer than the 4-state `ok/warn/bad/neutral` set used in the older top-tab-bar deck family — prefer this 5-state set going forward since "needs verification" and "partial" are genuinely different signals from "warning."
- **`.rtag`** — a small bordered pill citing a requirement/decision ID, used anywhere a later slide needs to point back at an ID minted earlier without re-explaining it.
- **`.callout`** (plus `.callout.teal` variant) — a left-accented tinted box for a single important aside or constraint list.
- **`.stmt`** — a plainer left-accented box (navy accent) for stating the core problem/thesis in one sentence, visually calmer than `.callout`.
- **`.scen` / `.scen.bad`** — a scenario card for before/after or good/bad contrast: a header label, a row of big-number stats (`.nb .v` at ~32px), and a result line with chips.
- **`.hz`** — a horizontal "category strip": a labeled box on the left, then a row of category boxes, some tagged `.on` to show they're the ones in play.
- **`.fgrid` / `.fcard`** (and `.fcard.ml` variant) — the 4-column feature-card grid described under slide 5.
- **`ol.steps`** (plus `.teal` and `.chk` variants) — a numbered list with a filled colored badge per item, used for step-by-step mechanisms and for action-item / to-check lists, distinguished by badge color.
- **`.flow` / `.step`** — the horizontal process-step strip described under slide 4.
- **`table.req`** (plus `.snug` / `.tight` size variants and a narrow `.id` column) — the ID-tagged requirement/decision/option table style used throughout.
- **`.takeaway`** — see shell mechanics above; one per slide, bottom-pinned, excluded from `fitContent` scaling.
- **`.cols`, `.cols.c55`, `.cols.c60`** — two-column flex layout, defaulting to even split, switchable to 55/45 or 60/40 for narrative-vs-dense-content asymmetry.

## 5. Visual system

**Colors** (from the file's `:root`):

| Token | Hex | Role |
|---|---|---|
| `--navy` | `#012169` | Headings, emphasis, primary ink for structural text |
| `--teal` | `#0097A9` | Primary accent — active nav state, borders, section labels |
| `--teal-dk` | `#007680` | Darker accent variant |
| `--teal-dp` | `#004F59` | Deepest accent variant (callout text on tint) |
| `--teal-1` | `#DDEFE8` | Lightest teal tint (backgrounds) |
| `--teal-2` | `#9DD4CF` | Mid teal tint (borders on tinted panels) |
| `--green` | `#86BC25` | Decorative brand accent (the brandmark dot) |
| `--green-ac` | `#26890D` | "ok" chip semantic |
| `--orange` | `#ED8B00` | "warn" / "to check" semantic |
| `--red` | `#DA291C` | "no" / failed semantic |
| `--g1` … `--g11` | `#F2F2F2` → `#53565A` | Named grayscale ramp (g1 lightest, g11 darkest) |
| `--white` / `--ink` | `#FFFFFF` / `#1A1A1A` | Page background / body text |

This reads as a real corporate brand system — the navy/teal/green combination plus the `g1/g2/g6/g9/g11` naming convention specifically looks Deloitte-brand-flavored. **Treat this as a fixed brand palette to copy exactly, not a starting point to retint per deck**, unless the user asks for a different brand.

**Fonts:** system stack only — `"Open Sans","Segoe UI",Calibri,Arial,sans-serif` for all body/UI text, `Consolas,"Courier New",monospace` for the handful of mono accents (feature-name labels). **No Google Fonts or any external font `<link>`** — this is deliberate, keeping the deck dependency-free and guaranteed to render identically offline. This is a real difference from the older top-tab-bar deck family (which loads IBM Plex Sans/Mono from Google Fonts) — don't merge the two conventions; pick one deck's font strategy and stay consistent within that deck.

**Theming:** single fixed light theme — no `prefers-color-scheme` handling, no dark-mode tokens at all. Note this as this deck's current state rather than a hard rule; a later appended reference deck may introduce dark-mode support, at which point add a note here about how to reconcile it.

**Base body font size:** 17px (larger than a typical dense document), `line-height:1.45`. Headings: h1 44px/700, h2 30px/700, h3 14px/700 uppercase letter-spaced. Table body text ~16px, table headers ~15px. This deck reads as noticeably larger and more confident than a dense corporate doc — content is written *tight* (short phrases, ID tags, chips) precisely so the larger type doesn't force the deck to sprawl.
