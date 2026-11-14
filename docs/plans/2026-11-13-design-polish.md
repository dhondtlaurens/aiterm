# Give the app a professional finish: a layered foundation, two-pane Settings and a wide board

Status: plan agreed on 2026-11-13. Part 1 is merged (merge 1) and ships in 0.47.0. On the same day,
after the release, the maintainer dropped part 2 (Settings keeps its tabs) and asked for part 3 to
be rethought: what the broadcast's sheet needs while a broadcast runs, with a live, trigger-started
broadcast in mind. On 2026-11-14 the maintainer picked one list of tasks, kept simple, one question at a time, and one
interface for every question, and asked for the proposal to be reworked first. The reworked proposal
was picked in full that day and is planned and built from `2026-11-14-broadcast-sheet.md`. The sections on parts 2 and 3 below describe what was
agreed before that and are not built.

## Goal

Ship the design picked on the Proposals tab of `docs/design/design-system.html` on 13 November 2026
(commit `9fc15b54`): proposal 2, Layered, as the foundation for the whole app, with two surfaces from
proposal 3, Workbench: two-pane Settings and the wide broadcast board. The picked frames on that tab
are the visual reference for every slice. Proposal 3's status-first sidebar, one-page New Task and
New Review, and one-scroll New Broadcast were not picked; those surfaces ship as proposal 2 draws them.

## Approach

The work is three parts, each built in slices that leave the app working, each gated with the full
suite and merged to `main` on its own. After the first merge the whole app wears the new foundation,
with Settings and the board still in today's layout until their own merges land.

The branch is 122 commits behind `main` (0.46.0, the second refactor round). Before any slice, `main`
is merged in and the code map below is checked again against it: the refactor added shared pieces
this plan builds on (`SteppedSheetFrame`, `TabShortcuts`, `QuietBadgeLine`, `SidebarRowContent`,
`ActivityPresentation`) and may have moved lines.

What the grilling decided:

- **Three merges**, not one branch merged at the end.
- **The terminal background follows the sidebar.** "Use dark terminal background" has the daemon paint
  the new sidebar ground instead of `#1E1E1E`, so the terminal and the sidebar stay one surface.
- **Increase Contrast is written by hand.** The palette's greys become literal values, so inks and
  hairlines get a stronger variant under Increase Contrast; grounds stay the same in both.
- **Every sidebar heading is sentence case, Operator included.** It reads "Operator" at rest and
  decodes into its row's line in that line's own case. The decode's timing and rules do not change.

### Part 1. Foundation (no behaviour change)

- **Grounds and inks.** `Palette` takes the graphite ramp as literal values: well, field, sidebar,
  sheet, card, popover and button grounds, three inks, and a soft and a firm hairline. The sidebar is
  no longer an alias of the sheet's ground. The opaque "solid" colours an avatar ring needs are
  composited from the new grounds, as they are today.
- **Selection goes neutral.** A new selected surface joins `Surface`: a lighter ground with resting
  inks, on which amber, green, the spinner and the done mark keep their own colours. Sidebar rows,
  Shelf rows and a dropdown's highlighted row use it. The accent surface stays for the primary
  button only; accent also stays on focus, switches, checkboxes and links.
- **Shape and type.** Radii move one step rounder (chip 5, control 7, group 10, panel 12). The sheet
  title becomes 17 semibold, a group's heading 13 semibold, and the sidebar heading 11 semibold in
  sentence case and the third ink.
- **One control shape.** A house button style in two weights replaces the native capsule buttons in
  sheets, cards and the empty state. `Select` keeps its native menu but is drawn in the same field
  chrome as `Input`, over a borderless popup. Fields are wells, darker than their ground; buttons are
  lighter than it. Switches, checkboxes and alerts stay native.
- **Mono is for code.** Branch names, commands, hashes, paths, tool calls and the prompt editor keep
  the monospaced face. Status words, counts, model names, telemetry labels, times, ticket keys and
  keycaps move to the system face with tabular figures.
- **Sheet chrome.** The stepper moves into the title row (numbers, the current step named, earlier
  steps ticked). Tab bars become underline tabs on the header's rule, keeping the arrow keys and the
  command-number keys. The footer sits on the sheet's own ground under a hairline. A single-step
  sheet is as tall as its content; a stepped flow takes one named height, so its steps do not jump.
- **Sidebar details.** Vendor marks on a task's badge line take secondary ink (diff counts keep green
  and red) unless Settings › Interface › Sidebar badges turns Brand colours on, the divider's label
  joins the heading grid, and the footer keeps its short labels (`ctx`, `wk`, `5h`, `cpu`, `ram`,
  `bat`) in the system face on its own darker ground. The maintainer asked for both after trying the
  dev build: the proposal drew words in the footer and no switch.

`Select` over a borderless popup is the one known risk: the README and four code comments call the
native bezel deliberate. It is built first in this part. If AppKit will not behave, `Select` keeps
its bezel and that is reported, not worked around.

### Part 2. Two-pane Settings

- A sheet's width becomes its own, clamped to the screen as its height already is. What reads the
  fixed sheet width today (the prompt step's completion popup, the Instructions editor's, the
  waiting-on-you list and the board's placeholder) reads the sheet's width from the environment
  instead.
- Settings is 780 wide: a navigation rail on the left and plain rows on the right (label left,
  control right) in place of cards. A harness or a service is one group: its mark, checks and status
  in the first row, its settings under it.
- Keyboard becomes a fifth pane, split out of Interface, and the panes answer to ⌘1 to ⌘5.
- Opening Settings on a pane or at an agent, scrolling to that agent, Save and Cancel across panes,
  and the Instructions editor's completion popup keep working as they do now. The rail does not
  scroll with the content.

### Part 3. Wide board

- The board's sheet is 980 by 640: the title row carries the status, a progress bar by task state,
  the count and the tabs; Asked, Goal and Each task share one line under it.
- Board: the questions waiting on the person run across the top, and the columns are whole and
  equal. The projection decides how many there are, as it does today: four, or three when the
  broadcast has no review step. The board still scrolls as one.
- Activity: the list keeps its rows and the picked entry opens in an inspector beside it, showing
  what the open row shows today. The picked entry is the sheet's state, not the list's.
- Summary: the text at a reading measure, with the goal's outcome beside it from what the board
  already holds. No new Operator data.
- When this part ships, the proposal leaves the design page and the tab says "No open proposals."

### Out of scope

- The status-first sidebar, the one-page New Task and New Review, and the one-scroll New Broadcast.
- Scaling sheets with the sidebar's zoom. Sheets stay at standard scale.
- The frozen Operator contracts and their wording, including "Settings › Integrations" and
  "Waiting on you". No contract golden is regenerated.
- The README picture: `scripts/release.sh` redraws it at the next release.

## Files

Part 1:

- `app/Sources/AiTermUI/Palette.swift` (modify): the ramp, the third ink, both hairlines, the
  Increase Contrast variants, the selected and button grounds, recomposited solids.
- `app/Sources/AiTermUI/Surface.swift` (modify): the neutral selected surface.
- `app/Sources/AiTermUI/Metrics.swift` (modify): radii, the new type styles, sheet heights per flow.
- `app/Sources/AiTermUI/ControlChrome.swift` (modify): wells, card and popover grounds, the neutral
  menu highlight, the house button style's chrome.
- `app/Sources/AiTermUI/Select.swift`, `Input.swift`, `SegmentedControl.swift`, `Kbd.swift`,
  `Badge.swift`, `SidebarHeading.swift` (modify): one shape, new grounds, words out of mono.
- `app/Sources/AiTermUI/` (create): a button style and an underline tab bar, each with its state
  matrix, a README inventory line and a test, as the README's rule for a new primitive asks.
- `app/Sources/AiTerm/Views/SheetChrome.swift`, `SteppedSheetFrame.swift`, `TabShortcuts.swift`
  (modify): the title-row stepper, underline tabs, footer ground, fitted heights.
- `app/Sources/AiTerm/Views/SidebarRows.swift`, `SidebarRowContent.swift`, `QuietBadgeLine.swift`,
  `StatusMark.swift`, `AvatarGroupView.swift`, `OperatorBadge.swift`, `DividerRow.swift`,
  `SidebarFooter.swift`, `Operators/OperatorHeading.swift`, `ArchiveSheet.swift`, `Dropdown.swift`
  (modify): the selected surface, marks that keep their colour, sentence-case headings, footer words.
- The views that set words in mono or choose a native button (modify): `SettingsCard.swift`,
  `HarnessSettingsPane.swift`, `MacSettingsCard.swift`, `BackpackSheet.swift`, `SearchPicker.swift`,
  `SidebarEmptyState.swift`, `StatusCountChips.swift`, `InterfaceSettingsPane.swift`,
  `Operators/BroadcastBoardSheet.swift`, `Operators/BroadcastActivityView.swift`,
  `Operators/WaitingOnYouList.swift`.
- `daemon/aitermd/iterm_bridge.py`, `docs/daemon-protocol.md`,
  `app/Sources/AiTerm/Snapshots/ReadmeDesktop.swift` (modify): the terminal background value.
- `app/Sources/AiTermUI/README.md`, `docs/design/ui-patterns.md`, `docs/design/design-system.html`
  (modify): the rules, the patterns, and the page's Foundations and Components synced to the Swift.

Part 2:

- `app/Sources/AiTermUI/Metrics.swift`, `app/Sources/AiTerm/Views/SheetChrome.swift` (modify):
  per-sheet width, clamped; the width in the environment.
- `app/Sources/AiTerm/Views/SettingsView.swift`, `SettingsCard.swift`, `HarnessSettingsPane.swift`,
  `OperatorSettingsPane.swift`, `InterfaceSettingsPane.swift`, `KeyboardSettingsPane.swift`,
  `ItermSettingsCard.swift`, `MacSettingsCard.swift` (modify): the rail, rows in place of cards, the
  Keyboard pane, ⌘1 to ⌘5.
- `app/Sources/AiTerm/Views/Steps/PromptStep.swift`, `Views/OperatorSettingsPane.swift`,
  `Views/Operators/WaitingOnYouList.swift` and `app/Sources/AiTerm/Operators/BroadcastBoardHost.swift`
  (modify): read the sheet's width instead of the constant.
- `app/Sources/AiTerm/Snapshots/SettingsSnapshots.swift` (modify): the Keyboard pane's image,
  appended at the end of the regression set.
- `docs/keyboard.md`, `docs/configuration.md`, `docs/design/ui-patterns.md`,
  `docs/design/design-system.html` (modify).

Part 3:

- `app/Sources/AiTermUI/Metrics.swift` (modify): the board's width and height; the column width goes.
- `app/Sources/AiTerm/Views/Operators/BroadcastBoardSheet.swift`, `BroadcastActivityView.swift`,
  `ActivityPresentation.swift`, `BroadcastSummaryView.swift`, `WaitingOnYouList.swift`, and
  `app/Sources/AiTerm/Operators/BroadcastBoardHost.swift` (modify): the wide layout, the inspector,
  the summary's side.
- `app/Sources/AiTerm/Snapshots/OperatorSnapshots.swift` (modify): frames at the new size.
- `docs/keyboard.md`, `docs/operators.md` where it describes the board, `docs/design/ui-patterns.md`,
  `docs/design/design-system.html` (modify): the last also loses the proposal.

`AiTermCore`'s `BroadcastBoard` projection is read, not changed, unless the progress bar needs a
count per task state it does not already expose; then that count is added there with its test.

## Proof

- **Gate.** `scripts/test.sh` before each commit, `scripts/test.sh all` before each of the three
  merges. Both must end green.
- **Tests that pin what changes** are updated with the change, each for the reason it exists:
  `PaletteDistinctionTests` (manifest, the alias list, solids equal to their composite),
  `PaletteTests`, `SurfaceTests` (the new case in every loop, each occluding ground), `StatusMarkTests`,
  `BadgeTests`, `KbdTests`, `OperatorBadgeTests` and `PickerResultRowTests` (ink on the selected
  surface), `SegmentedControlTests`, `ControlChromeTests`, `HairlineTests`, `MetricsTests`,
  `SidebarRowGeometryTests`, `SelectTests`, `NewTerminalSheetGeometryTests` (fitted height),
  `HarnessSettingsLayoutTests` and `KeyboardSettingsTests` (five panes, ⌘1 to ⌘5),
  `SheetPreparationTests`, `OperatorInstructionsPopupTests`, `SettingsToggleLayoutTests`,
  `BroadcastBoardSheetTests` (width, three and four columns, the redraw counter with the lifted
  selection),
  `OperatorSnapshotTests` and the daemon's test of the painted background.
- **New tests.** Both Increase Contrast variants resolve and differ where they should; the selected
  surface keeps a mark's colour; the button style and the tab bar in each state, with the tab bar's
  arrow and command-number keys; a sheet's width never exceeds the screen; the Keyboard pane lists
  what Interface listed; the inspector shows the picked entry and survives a redraw of the list.
- **Seen.** After each slice, `scripts/snapshots.sh build/<folder>` and the images read against the
  picked frames and the README's rules. A real flow in the running app only through
  `scripts/run-dev.sh`, on the maintainer's go.

## To-dos

- [x] Merge `main` into `feat/design-polish`; run the gate; re-check this plan's files and the
      proposal frames against 0.46 and correct the plan where the refactor moved something.

Part 1, foundation:

- [x] `Select` in field chrome over a borderless popup, with its tests. Decide here whether the
      one-shape rule holds for `Select` or it keeps its bezel.
- [x] The ramp, inks and hairlines in `Palette` with their Increase Contrast variants; the sidebar
      distinct from the sheet; solids recomposited; palette tests updated.
- [x] The terminal background follows the sidebar: daemon, protocol doc, settings swatch.
- [x] The neutral selected surface on sidebar rows, Shelf rows and dropdown highlights; marks keep
      their colours; surface and mark tests updated.
- [x] Radii and the new type styles; sentence-case headings, Operator's decode included.
- [x] The house button style everywhere a native push button stands in a sheet, a card or the empty
      state; fields as wells; cards and groups on the card ground.
- [x] Words out of mono, view by view, from the code map.
- [x] Sheet chrome: the title-row stepper, the underline tab bar on Settings and the board, the
      footer's ground, fitted heights.
- [x] Sidebar details: badge-line marks, divider label, footer words and ground.
- [x] README, patterns doc and the design page's Foundations and Components synced; publish.
- [x] Snapshots read after every slice; the gate green on the whole part.
- [x] Review, one commit, `scripts/test.sh all`, merge 1.

Part 2, Settings (dropped on 2026-11-13, not built):

- [ ] Per-sheet width, clamped, in the environment; its four readers moved off the constant.
- [ ] The rail and the pane frame at 780, with today's panes inside it unchanged.
- [ ] Rows in place of cards: Agents, then Operator, then Integrations, then Interface.
- [ ] The Keyboard pane and ⌘1 to ⌘5; deep links, scroll to an agent and the popup still land.
- [ ] Docs and the design page; snapshots read; `scripts/test.sh all`; merge 2.

Part 3, board (superseded on 2026-11-13 by the proposal on the design page, not built):

- [ ] The sheet at 980 by 640 with the title row and the one-line brief.
- [ ] Questions across the top and whole, equal columns, with and without a review step.
- [ ] The Activity inspector, with the picked entry held by the sheet.
- [ ] Summary at a reading measure with the goal's outcome beside it.
- [ ] Docs; the proposal removed from the design page and the page published; snapshots read;
      `scripts/test.sh all`; merge 3.
