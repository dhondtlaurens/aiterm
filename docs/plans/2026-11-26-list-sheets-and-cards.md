# List sheets, floating cards and the signals glyph

Branch `feat/better-ui`. Drawn and picked on the design page's Proposals tab
(`docs/design/design-system.html`, `#p-list-sheet`, `#p-cards`, `#p-signal-glyph`), 26 Nov 2026.

## Goal

The Operator signals, Project signals and Archive sheets become one list sheet: two-line rows that cut
their text instead of wrapping, a state glyph in a centred column with its words in a `HoverChip`, a
settings button drawn as the + is, and a search field on every list. The signal card and the
background-work card get the picked layouts, with the capitalisation and truncation rules from the
page. One signals glyph, `dot.radiowaves.right`, replaces today's everywhere.

## Approach

`ListSheet` is a new app pattern in `AiTerm/Views` (app composition, not an `AiTermUI` primitive): the
title, a search field, optional group headings, a highlightable list with its keys, the empty and
no-match lines, and `SheetFooter`. `ListSheetRow` is `SidebarRowContent`'s grid: leading mark, the
title over one `Size.chip` line, an optional state column, and the trailing column a task row gives its
status mark. Both sheets become configurations of it. Existing parts are reused rather than redrawn:
`AddMenu` (taking a symbol) for the settings button, `HoverChip` (with a trailing alignment) for the
state's words, `SidebarHeading` for the Archive's date groups, `TaskBadges`, built from the archived task as
`ArchiveRow` builds them today, and `AvatarGroupView`'s column for the Archive's rows, `StatusMark` and `Hairline` in the signal card, `Badge`'s quiet chip look for a command.

Picked in grilling, round by round on the Proposals tab:

- **Rows (1B).** A signal's second line is its Start description, or its query in `Typography.mono`
  when it has none; one line, cut at the end. No words beside the title: no running count, no issue text.
- **State column.** `Size.slot` wide, centred on the row before the trailing column; both text lines are
  cut before it. Issue: `exclamationmark.circle.fill` in `amber` (`Notice`'s mark), its chip "Can’t read
  GitLab. AiTerm tries again at 12:05.": a failing read's gist, the source and the retry, never the server's
  error, which can run past the sheet; with more issues, "And N more."; every issue whole is the glyph's help
  and its VoiceOver value. Schedule: `clock` in `tertiary`,
  "Next run: 30 Nov 2026 09:00" (`SignalSummary.nextRun`'s words, as the heading's tooltip says it). Switched off: `pause.fill` in `tertiary`, the row at `Opacity.disabled`,
  "Switched off". An issue outranks the clock. The chip aligns its trailing edge with the glyph's.
- **Settings button (2A, glyph A).** Outline `gearshape`, drawn exactly as `AddMenu` draws the +
  (`Typography.label`, the surface's secondary ink, no ground, `Size.slot` square, `trailingInset`), always
  there; it opens the row's menu, the same groups as the context menu and VoiceOver actions.
- **One list sheet with search (3C).** Signals search name, description, query and source; the Archive
  keeps its search. ↑ ↓ move the highlight from the search field (passing over group headings), a
  double-click is the row's first command (a signals sheet's highlight starts on nothing, the Archive's on its
  newest row, as today) (Edit Signal…, Restore), ⌘↩ the footer's primary (Done on a
  signals sheet, Restore on the Archive), ⌘⌫ the row's Remove question, ⎋ clears the search then closes.
- **Archive.** Rows are the sidebar's task row (the task's agent mark in `AvatarGroupView`'s column, title,
  ticket and request badges, branch, then the project in the help ink; badges drop whole, the branch cuts in
  the middle). No diff: an archived task saves none (`ArchivedTask` is the `TaskItem` and `archivedAt`) and its
  worktree is gone, so the row shows none rather than reading a stale or missing one; the workspace format
  stays as it is), the gear where the status mark sits (Restore, Remove…). The date leaves the row for
  `SidebarHeading` groups: Today, Yesterday, This week, then each month, with the year when not this
  year. A search lists its matches best first, as `ArchiveSearch` ranks them, under no heading: grouping
  them by date would undo the ranking.
- **Signal card (A).** No heading. Each signal that ran the task on a `Size.chip` line, oldest first,
  name cut at the end and its time never, the current one in `text`, earlier ones `muted`; a `Hairline`;
  then the work beside a `StatusMark` at `Size.statusMark` in the secondary ink, sentence case ("Waiting
  for its worker to be idle"), cut at the end with the whole sentence as its help.
- **Background-work card (C).** The mark `Space.inset` from its words, as in the footer. A native
  description in `Typography.help`, its first letter raised, cut at the end with the whole line as help.
  A raw command (`BackgroundJob.isCommand`) says "Shell" and its command follows in a quiet chip
  (`Typography.monoChip`, secondary ink, `badge` wash, `Radius.chip`, `Size.chip`, `Space.tight` inside)
  that shrinks and cuts at the end; the command is never recased; the whole command is the line's help.
- **Signals glyph (B).** `dot.radiowaves.right` for the heading's signals button and the avatar disc, from
  one constant (`AvatarGroupView.signalGlyph`, which the heading reads instead of its literal). The disc
  stays `Size.cornerBadge`, the same as a badge's check.

Not changed: the saved workspace format, the Signal contracts, the commands in each menu, what the
signals sheets' and the Archive's actions do.

## Files

- `app/Sources/AiTerm/Views/ListSheet.swift` (create): `ListSheet`, `ListSheetRow`, the state column and
  its `HoverChip`, the group heading row, the list's keys and highlight.
- `app/Sources/AiTerm/Views/SidebarRows.swift` (modify): `AddMenu` takes a symbol, `plus` by default.
- `app/Sources/AiTermUI/HoverChip.swift` (modify): `raisingHoverChip` takes an alignment, centred by
  default, trailing for the state column.
- `app/Sources/AiTermUI/Hairline.swift` (modify): `Hairline.thickness`, which the signal card's height reads.
- `app/Sources/AiTerm/Views/BackgroundCardPresenter.swift` (modify): the signal card's new height.
- `app/Sources/AiTerm/SignalsSheetModel.swift` (modify): `Row` carries description (or query), a state
  (issue words, next run, switched off) instead of the Starts/Next run/Done lines and the issue list;
  a query, the filtered rows and the highlight.
- `app/Sources/AiTerm/Views/SignalsSheet.swift` (modify): a `ListSheet` configuration; `SignalsSheetRow`
  stays, as the signal's `ListSheetRow`.
- `app/Sources/AiTerm/ArchiveSheetModel.swift` (modify): grouped rows, highlight across groups.
- `app/Sources/AiTerm/Views/ArchiveSheet.swift` (modify): a `ListSheet` configuration; `ArchiveRow`
  becomes the task row with the gear.
- `app/Sources/AiTermCore/Tasks/ArchiveDate.swift` (modify): the group a date falls in and its heading.
- `app/Sources/AiTerm/Views/SignalCard.swift` (modify): layout A; the card drops its heading and carries the row's
  mark; the waiting sentences in sentence case (`docs/operators.md` says them).
- `app/Sources/AiTerm/Views/BackgroundCard.swift` (modify): layout C, spacing, capitalisation, help tags.
- `app/Sources/AiTerm/Views/AvatarGroupView.swift`, `app/Sources/AiTerm/Views/SidebarHeadings.swift`
  (modify): the glyph from one constant.
- `app/Sources/AiTerm/Snapshots/SheetSnapshots.swift` and the sidebar snapshot fixtures (modify): the
  new states and the edge cases drawn on the page (long names, long commands, lowercase descriptions,
  an issue, a schedule, switched off, a grouped archive, a search with no match).
- `app/Sources/AiTermUI/README.md`, `docs/design/ui-patterns.md`, `docs/keyboard.md` (modify): the
  inventory, the pattern, the signals sheets' keys.
- `docs/design/design-system.html` (modify): once shipped, the three proposals come off and
  Foundations and Components are synced (`design-system` skill).

## Proof

- `SignalsSheetModelTests`: rows carry description or query, the state and its words, the issue over the
  clock; search by name, description, query and source; highlight and its moves.
- `ArchiveSheetModelTests` and `ArchiveSearchTests`: groups in order, empty groups left out under a search,
  ↑ ↓ passing over headings, Restore and Remove from the row's menu; a row with a merge request and no
  worktree draws its badges and no diff.
- An `ArchiveDate` test in `AiTermCoreTests`: Today, Yesterday, This week, a month, a month of another year,
  on a fixed calendar.
- `BackgroundCardTests`: the kind word and chip for a command, the first letter raised for a description
  and never for a command, the help tags.
- A signal-card test: no heading, the steps' order and ink, the work's sentence case and its help.
- `HoverChipTests`: the trailing alignment keeps the chip inside the glyph's trailing edge.
- `DesignRulesTests` stays green: every value from `Palette` and `Metrics`.
- Hosted native snapshots (`AITERM_SNAPSHOT_HOSTED=1 AITERM_SNAPSHOT_NATIVE_CAPTURE=1 scripts/snapshots.sh`)
  compared with the drawings on the Proposals tab. Agents never run the app (`docs/workflow/verify.md`): the
  live check is the maintainer's: open each sheet, search, move with ↑ ↓, hover a state glyph and a gear,
  open both cards.
- The gate, `scripts/test.sh`.

## To-dos

- [x] `AddMenu` takes a symbol; `raisingHoverChip` takes an alignment; their tests.
- [x] The signals glyph from one constant, `dot.radiowaves.right`; the sidebar snapshots.
- [x] `ListSheet` and `ListSheetRow`, with the state column, keys and highlight.
- [x] Operator and Project signals on `ListSheet`: model rows, search, the gear menu; tests and snapshots.
- [x] The Archive on `ListSheet`: task rows, date groups, the gear menu; tests and snapshots.
- [x] The signal card, layout A; test and snapshots.
- [x] The background-work card, layout C; tests and snapshots.
- [x] README inventory, `ui-patterns.md`, `keyboard.md`; the design page synced and the proposals removed.
