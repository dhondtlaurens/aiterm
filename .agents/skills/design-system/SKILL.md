---
name: design-system
description: Use when asked to update, sync or publish AiTerm's design system artifact, to show a proposal for a visual change on it, or after a change to Palette.swift, Metrics.swift or any component in app/Sources/AiTermUI. Syncs the published page to the Swift, which is the source of truth.
---

# Syncing the design system artifact

The artifact is a human view of `app/Sources/AiTermUI/`. The Swift is the source of truth; this
page catches up to it on request. It is not a gate — nobody needs it to write correct Swift.

**Artifact:** `https://claude.ai/artifact/SSWnecBHS2aHZrfKECCPM3`
**Source:** `docs/design/design-system.html` (one self-contained file, no supporting files)

## The loop

1. **Read the Swift.** `app/Sources/AiTermUI/Palette.swift` and `Metrics.swift` for every value;
   `ls app/Sources/AiTermUI app/Sources/AiTerm/Views` for the inventory.
2. **Reconcile the page against it.** Every swatch's hex and usage line, every scale value, every
   type specimen, every component card. A name on the page that is not a type under `app/Sources/`
   is a bug in the page — delete it or fix it.
3. **Update `app/Sources/AiTermUI/README.md`'s inventory too** if a component was added, removed or
   renamed. That file is what agents without artifact access read, so it matters more than the page.
4. **Publish.**

   ```
   Artifact(action: "publish", url: "https://claude.ai/artifact/SSWnecBHS2aHZrfKECCPM3", file_path: "docs/design/design-system.html")
   ```

5. **Commit** the HTML.

## The Proposals tab

The page has three tabs. Foundations and Components are the sync above. **Proposals** is always
present and holds only what is not in the code yet.

- **To propose:** add a `.section` to `#proposals` under its "How this tab works" intro — an amber
  `proposal-flag` eyebrow (`Proposal · <topic> · <date>`), what is wrong today, and each decision's
  options as `.option` cards drawn at 1 CSS px = 1 pt from the page's tokens, the recommended one
  marked `pick`. Publish, then **stop and wait for a pick** — the tab is where the choice is made,
  so no Swift is written before it.
- **Once a proposal ships:** delete its sections from `#proposals`, then run the loop above so
  Foundations and Components match the new Swift. Leave the tab button, the panel and its intro in
  place, and add `<p class="no-proposals">No open proposals.</p>` under the intro when it is empty.

## Rules

- **Never send `type_url`.** The artifact exists; `type_url` would create a second one.
- **Never invent a value.** Every number and colour on the page is transcribed from the Swift. If
  you cannot find it in `Palette` or `Metrics`, that is a conformance bug in the app — report it
  rather than drawing around it.
- **Never edit the page to change the design.** Change `Palette`/`Metrics`, then sync. The one
  place the page runs ahead of the code is the Proposals tab, and only as a menu to pick from.
- **Never remove the Proposals tab.** Only the proposals on it come and go.
- The page is one file. There is no index, no board coordinates, no staging and no supporting files.
