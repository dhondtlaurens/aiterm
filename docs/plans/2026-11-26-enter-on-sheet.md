# ↩ opens a list sheet row's menu

Branch `feat/enter-on-sheet`. No ticket: the prompt is the ticket.

## Goal

In the Archive and the Operator and Project signals sheets, ↑ ↓ already move the highlight from the search
field. A plain ↩ on the highlighted row now opens that row's gear menu, under the gear, as a click on the gear
does, with its first enabled item highlighted, so ↩ ↩ runs Edit Signal… or Restore. Today ↩ does nothing there.

## Approach

All three sheets are configurations of `ListSheet`, so the key lives there once: it takes
`insertNewline` from the search field before the sheet's own `command`, and with a highlighted row that has an
enabled command it asks that row's gear to open its menu; otherwise ↩ stays the field's (nothing happens, as
now). ⌘↩ (the footer's primary), ⌥↩ (another selector), ↑ ↓, ⌘⌫ and ⎋ are unchanged.

A SwiftUI `Menu` cannot be opened from code, so the gear stops being `AddMenu`: it becomes a row menu button
that draws exactly what `AddMenu` draws (`gearshape` in `Typography.label`, the surface's secondary ink, the
`trailingSlot` square, its help and disabled state) and pops an AppKit menu built by `NSHostingMenu` from the
same `RowCommandMenu` the context menu shows, so the items, separators, greying and destructive roles cannot
drift. A click and ↩ open the one menu from the same anchor below the gear; only ↩ highlights the first enabled
item, as a menu opened from the keyboard does. ⎋ in the open menu closes the menu and leaves the sheet open.

Decided in grilling: the menu opens under the gear, as a click opens it (the prompt); ↩ highlights the first
enabled item (picked over nothing highlighted). Not asked, defaults: a signals sheet whose highlight starts on
nothing does nothing on ↩ until ↑ ↓ have landed on a row; the Archive, whose highlight starts on its newest
row, opens that row's menu at once.

The menu pops a run-loop turn after the key, never inside the field editor's command or a SwiftUI update:
`popUp` tracks modally and runs the chosen item before it returns, and Remove… asks an `NSAlert`, which is not
allowed inside a key handler (`docs/workflow/verify.md`, the sidebar's ⌘⌫ in `SidebarView`).

How to highlight the first item is AppKit's to settle at implementation: `popUp(positioning:)` with that item,
else the open menu given a ↓ once it tracks (on `NSMenu.didBeginTrackingNotification`). Whichever works without
moving the menu off the gear's anchor stays; the menu must still open below the gear.

Not changed: the headings' + (`AddMenu`), each sheet's commands, the context menu, VoiceOver actions, what the
footer and the other keys do, how the gear looks.

## Files

- `app/Sources/AiTerm/Views/ListSheet.swift` (modify): ↩ handled before `command`; a per-sheet open request
  (the row's id and a count, so ↩ twice on one row opens it twice) handed to the highlighted row through the
  environment; `ListSheetRow` uses the row menu button instead of `AddMenu`; the doc comment lists ↩.
- `app/Sources/AiTerm/Views/RowMenuButton.swift` (create): the gear drawn as `AddMenu`'s +, its AppKit anchor,
  the `NSHostingMenu` of `RowCommandMenu`, the deferred pop below the anchor, the keyboard variant's first-item
  highlight; the pure choice of which item ↩ highlights (the first enabled one across groups).
- `app/Sources/AiTerm/Views/SidebarRows.swift` (modify): `AddMenu` loses its `symbol` parameter, which only the
  gear used.
- `app/Sources/AiTermUI/README.md`, `docs/design/ui-patterns.md` (modify): the list sheet's keys gain "↩ opens
  the row's menu, its first item highlighted". `docs/design/design-system.html` is synced only on request.

## Proof

- Tests (`AiTermTests`, keyboard and AppKit behaviour): ↩ through the search field's delegate with a highlighted
  row issues an open request for that row and is consumed; with no highlighted row, or a row whose commands are
  all greyed, it is not consumed and no request is made; ⌘↩'s path is untouched. The built menu has the
  `RowCommandMenu` items, separators and enabled states for a signals row and an archive row; the keyboard
  highlight picks the first enabled item, skipping a greyed one. Each fails before the change.
- Snapshots: `scripts/snapshots.sh` on `main` and on the branch; the list sheets' PNGs must be identical (the
  gear looks the same).
- Gate: `scripts/test.sh`, then the full suite proof before merging.
- Live check, the maintainer's (`scripts/run-dev.sh`): Archive: ↓, ↩ shows the menu under that row's gear with
  Restore highlighted, ↩ restores; ↩ then ↓ ↩ on Remove… asks its question whole; ⎋ closes the menu, the sheet
  stays, a second ⎋ closes it. Operator signals: ↩ before any ↓ does nothing; ↓ ↩ opens Edit Signal…
  highlighted. A click on the gear opens the same menu with nothing highlighted. Typing still searches.

## To-dos

- [ ] Row menu button: the gear drawn as today, a click pops the `NSHostingMenu` of `RowCommandMenu` below it,
      deferred a turn; `ListSheetRow` uses it, `AddMenu` loses `symbol`; snapshots identical; tests for the menu.
- [ ] ↩ in `ListSheet`: the open request to the highlighted row, its menu opened from the keyboard with the
      first enabled item highlighted; tests for the routing and the choice of item.
- [ ] Docs: `AiTermUI/README.md`, `ui-patterns.md`, the `ListSheet` comment; gate green; the live check listed
      for the maintainer.
