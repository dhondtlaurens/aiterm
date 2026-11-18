# Backpack Mode on the System heading

## Goal

Backpack Mode's status hangs under the Mac's readings in the sidebar footer on a row of its own:
an empty mark column, then `○ backpack mode`. It belongs to no mark, and the footer grows by a
`Size.menuRow` when the mode turns on and shrinks when it turns off, so the list above jumps.
Move the status onto the System heading's own line, `System · backpack mode`, so the footer keeps
one height in every mode, and make that the footer's standard: a group heading may carry one
status, which Usage can adopt later.

## Approach

Picked on the design page's Proposals tab ("Backpack Mode on the System heading", 18 Nov 2026):
decision 1 **B**, the status joined to the heading's words; decision 2 **A**, footer groups only.

`SidebarFooter`'s group heading takes an optional status. With one, the heading's line is
`SidebarHeading(title)` followed by ` · <words>` in the heading's face (`SidebarHeading.style`,
`Typography.section`), separator and words in the status's `SettingsTone` colour (ready green,
attention amber, idle muted), one line. No `ToneRing`, as drawn in the picked option. System passes
the Mac's mode: its words and tone are `MacMode.words` and `MacMode.tone`, unchanged
(`backpack mode`, `backpack mode · needs you`, `packing up…`, `unpacking…`); at the desk there is no
status and the heading is its word alone, as today.

The added words, not the heading's word, are the Mac's control: wrapped in the same `macControl` as
the readings row, so a click is ⌘B, a right-click offers Mac Settings…, and the tooltip and the
VoiceOver label are `mac.help`, with the button trait. The second Mac row and the footer's
`Column.mode` case go. The status stays in `SidebarFooter` beside `SettingsTone` and `ToneRing`: the
reuse ladder in `AiTermUI/README.md` promotes a pattern once a second file needs it, so
`SidebarHeading` in AiTermUI does not change. Usage gets no status in this change.

The design page's live copy is ahead of `main` (another branch published to it). Publishing merges
onto the live copy from a scratch file; the repo's `design-system.html` gets only this branch's
changes.

## Files

- `app/Sources/AiTerm/Views/SidebarFooter.swift` — modify: the group heading's optional status;
  System passes the Mac's mode wrapped in `macControl`; remove the mode's row from `macRows` and
  the `Column.mode` case; rewrite the type's doc comment where it describes the mode's line.
- `app/Sources/AiTerm/Views/MacModeRow.swift` — modify, comments only: "line" becomes the System
  heading's status.
- `app/Sources/AiTerm/Views/ToneRing.swift` — modify, comment only: the footer no longer draws one.
- `app/Sources/AiTerm/Views/BackpackSheet.swift` — modify, comment only: a lid-close during a connect
  shows its end on the System heading, not on a footer line (found while building).
- `app/Sources/AiTermUI/Metrics.swift` — modify, comment only: `statusMarkSmall` no longer leads the
  footer's Backpack Mode line.
- `app/Sources/AiTerm/Snapshots/SidebarSnapshots.swift` — modify, comment only:
  `sidebar-footer-mac.png` still draws every mode, now on the heading.
- `app/Tests/AiTermTests/SidebarFooterGeometryTests.swift` — modify: `theBackpackLineAddsOneRow`
  becomes a test that every mode keeps the desk's height; `theBatteryJoinsTheReadingsRow` expects
  one Mac row in every mode.
- `docs/design/design-system.html` — modify: delete the proposal and restore "No open proposals.";
  sync the Sidebar footer component card (its prose and the "on battery with Backpack Mode on"
  figure), the `ToneRing` and `Size.statusMarkSmall` usage lines, and the `SymbolMark` card's "Not
  for" note, which says the footer draws Backpack Mode's `ToneRing` on a row of its own; publish,
  merged onto the live copy.

## Proof

- `scripts/test.sh swift -- --filter SidebarFooterGeometryTests` and `--filter MacModeTests` while
  iterating; both must run tests.
- `scripts/snapshots.sh build/before` on this branch's base and `build/after` on the change; read
  `sidebar-footer-mac.png` against `AiTermUI/README.md`: each switching or backpack mode on the
  System heading in its tone, nothing at the desk, every mode's footer the same height, the readings
  row unchanged.
- `scripts/test.sh` before the commit; `scripts/test.sh all` once before merging to `main`.

## To-dos

- [x] The status moves onto the System heading: `SidebarFooter` change, the geometry tests updated,
      before/after snapshots read.
- [x] The comments in `MacModeRow`, `ToneRing`, `Metrics` and `SidebarSnapshots` describe the
      heading, not a row.
- [x] The design page drops the proposal, its footer card and usage lines match the Swift, and it is
      published onto the live copy and committed.
