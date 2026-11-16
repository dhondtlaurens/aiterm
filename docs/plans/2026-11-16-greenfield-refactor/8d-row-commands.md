# 8d. Each row builds its commands once; Pause and Resume have one home

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 8c (`HeadingRow`, `SectionHeading`), 8b (row
values carry the menu's facts), 8a, and phases 1 to 5. Audit: SB F11, SB F16 (first item).

## Why

Every sidebar row writes what you can do with it twice: once as its context menu and once as its
VoiceOver actions, through a hand-kept enum per row (`TaskRowAccessibility.Action`,
`TerminalRowAccessibility`, `DividerRow.Action`) that re-derives which items are enabled. The
copies offer different things (VoiceOver gets Archive and Remove on a task, nothing on a heading),
and "Open in Finder / Open in VS Code" is written three times. Pausing the Operator lives in two
places under two wordings: "Pause Operator" in OPERATOR's "+" (an add button holding a
non-add command) and "Pause" in the Operator row's menu, which is absent whenever there is no
workload. The end state: each row builds one list of `RowCommand`s in its body, drawn as its
context menu and as its VoiceOver actions; Pause Operator and Resume Operator live on the OPERATOR
heading's context menu only; OPERATOR's "+" holds New Signal… alone; the Operator row has no
menu. Nothing a person sees in the sidebar changes except where Pause and Resume are found.

## Today

As the code stands after phases 1 to 5 and 8a to 8c.

- `TaskRowView` (`app/Sources/AiTerm/Views/SidebarRows.swift`): a context menu with Take Over (when
  `row.underOperator`; off while locked or removing), Rename…, Open in Finder, Open in VS Code
  (when installed), Open in Jira or Open in GitLab (when the row has a ticket URL), Archive <kind>,
  Remove <kind>… (destructive), in groups split by dividers. Its VoiceOver actions come from
  `TaskRowAccessibility.actions` (`app/Sources/AiTerm/SidebarRowValues.swift` after 8b): Archive and
  Remove only, none while removing or locked.
- `TerminalRowView`: menu Rename…, Open in Finder, Open in VS Code, Remove Terminal (destructive);
  VoiceOver from `TerminalRowAccessibility` (Rename, Remove Terminal; none while locked).
- `DividerRow` (`Views/DividerRow.swift`): menu Rename…, Move Up, Move Down, Remove Divider; its
  `Action` enum and `actions(enabled:canMove:)` give VoiceOver the enabled ones.
- `HeadingRow` (`Views/SidebarHeadings.swift`, from 8c): project kind has the "+" items (New
  Task…, New Review…, New Terminal…; the first two off for a plain folder), then Open in Finder,
  Open in VS Code, Edit Project…, the Pull item 2b left (it asks git for the default branch when
  the menu opens), Move Up, Move Down, Remove Project…; the same "+" items also fill its `AddMenu`.
  Signal kind: Edit Signal…, Switch Off or Switch On (with "(starts n)" from the heading's `.task`),
  Remove Signal…; a removed signal has none. No heading has VoiceOver actions.
- `SectionHeading` (from 8c): OPERATOR's "+" holds New Signal…, a divider, and Pause Operator or
  Resume Operator (enabled by `canPresentNewSignal`); no context menu. PROJECTS' "+" holds Add
  Project…, Add Divider…; no context menu.
- `SignalOperatorRow` (`Views/Operators/SignalRows.swift`): a context menu with "Pause" or "Resume"
  calling `controller.signalController.setPaused`, off while locked.
- VoiceOver rule today: an action cannot be greyed, so only enabled items are offered, spoken
  without the menu's ellipsis.
- Tests: `RowAccessibilityTests` (action lists for task, terminal, divider), `DividerRow` cases,
  `SidebarInteractionTests` (⌘⌫, Return), `LockedSidebarTests`.
- Docs that name the old homes: `docs/operators.md` ("Pause, switch off and take over": the "+"
  menu and "The row's context menu offers the same control."), `docs/keyboard.md` ("The Operator
  row has Pause/Resume."), `docs/design/ui-patterns.md` (OPERATOR "offers New Signal / Pause /
  Resume in its + menu"; the Operator row "with pause"), `app/Sources/AiTermUI/README.md` (App
  composition row for the section headings).

## Change

1. Add `RowCommand` (new file `app/Sources/AiTerm/Views/RowCommand.swift`): a title as the menu
   shows it, a role (normal or destructive), whether it is enabled, and its action. A row's
   commands are a list of groups; a divider is drawn between non-empty groups. Add two renderers
   over the same list: the context menu's items (each group's buttons, disabled ones greyed), and
   the VoiceOver actions (the enabled commands of every group, in order, each titled without a
   trailing "…"). Add one helper that returns the Open in Finder and, when VS Code is installed,
   Open in VS Code commands for a path.
2. Each row builds its list once in its body from the facts it already reads, through a function
   that tests can call (for example a static function on the view taking the row value, the
   per-row flags and the controller). Action closures fetch the current task, terminal, project or
   signal from `controller.state` when run, as the menus do today.
   - Task row: the groups as listed under **Today**, with today's enabling.
   - Terminal row: Rename…; the open commands for the project's path; Remove Terminal.
   - Divider: Rename…; Move Up, Move Down; Remove Divider. `DividerRow.Action` and
     `DividerRow.actions(enabled:canMove:)` go.
   - Project heading: the "+" group, the open commands, Edit Project…, Pull (when the project is on
     GitLab or GitHub), Move Up and Move Down, Remove Project…. The `AddMenu` draws the first group
     from the same list, so the two cannot drift.
   - Signal heading: Edit Signal… (enabled by `canPresentNewSignal`), Switch Off or Switch On (its
     title exactly as today, count included; 8e changes it), Remove Signal…; none when removed.
   - OPERATOR heading: one command, Pause Operator or Resume Operator by `rows.operatorPaused`,
     enabled while the workspace can change. Its "+" holds New Signal… only.
   - Operator row: no commands and no context menu.
3. Where the two renderings attach: on a task, terminal or divider row both go where today's menu
   and actions are (the row is one combined accessibility element). On `HeadingRow` and
   `SectionHeading` the context menu stays on the whole heading and the VoiceOver actions go on the
   folding label's element (the one `FoldOnTap` combines), so VoiceOver finds them where it finds
   the heading.
4. Delete `TaskRowAccessibility.actions` and `title(of:)` (its label, hint and help stay),
   `TerminalRowAccessibility`, and `SignalOperatorRow`'s context menu.
5. Docs: rewrite the Pause sentences in `docs/operators.md` to "Use **Pause Operator** in the
   Operator heading's context menu to pause all signals, and **Resume Operator** there to resume,
   even when its chat row is absent." and delete "The row's context menu offers the same control.";
   `docs/keyboard.md`: "The Operator heading's menu has Pause Operator and Resume Operator.";
   fix the `docs/design/ui-patterns.md` sentences and the AiTermUI README row that place Pause and
   Resume in the "+" or on the row.

## Keep

- The menus' titles, order, groups, roles and enabling, item for item, except the moved Pause and
  Resume. The context menu is not in any snapshot, so a slip here is caught only by the tests below.
- 2b's way of naming the Pull item: its title is a plain string, "Pull " plus the name
  `ProjectActions` last read for the project, else "Pull Default Branch". The name is asked from
  git by a task on the heading row (when the row appears, and after a pull), not from inside the
  menu. Build the command's title from that stored name and leave the mechanism alone.
- `TaskRowAccessibility`'s label, hint and help; `SelectableRow`'s own default action (choosing the
  row), which is not a command.
- The project's Jira badge menu: it is a badge's menu, not the row's.
- ⌘⌫ (`AppController.removeSelection`) and Return: keyboard paths, not menu items.
- `AddMenu` as the "+" control.

## Decisions already taken

- VoiceOver now offers every enabled command of a row, not a hand-picked subset: Take Over,
  Rename, Open in Finder, Open in VS Code, Open in Jira, Archive and Remove on a task; the heading
  commands on a heading. That is the point of one list.
- A row being removed: the menu greys Take Over, Rename, Archive and Remove as today and leaves the
  open commands enabled, so VoiceOver offers the open commands only.
- Locked workspace: every command that changes the workspace is disabled, the open commands are
  not. The "+" stays disabled whole, as today.
- One wording: "Pause Operator" and "Resume Operator", everywhere they appear.
- The OPERATOR heading's context menu exists even with no signal and no row, so Resume is always
  reachable while paused.
- PROJECTS gets no context menu: it has no command that is not already its "+".

## Tests

- Replace the action-list tests in `RowAccessibilityTests` (`aTaskRowOffersRemoveAndNoReopen`,
  `archiveIsOfferedBesideRemoveAndNamedWithoutAnEllipsis`, `aTaskRowBeingRemovedOffersNothing`,
  `aLockedWorkspaceOffersNoTaskActions`, `aRowsActionsAreItsMenuItemsTitles`,
  `aTerminalRowOffersRenameAndRemoveWithOrWithoutItsWindow`, `aDividerOffersOnlyWhatItsMenuHasEnabled`)
  with command-list tests that check titles, groups, roles and enabling, and the VoiceOver titles,
  for: an ordinary task, a task under the Operator, a review (kind names), a task being removed, a
  locked workspace, a terminal, a divider at each end of the list, a project heading on GitLab and
  a plain folder, a live signal heading switched on and off, a removed signal heading, the OPERATOR
  heading paused and running, and the Operator row (no commands). Do not assume VS Code is
  installed: compare with `ExternalApps.vscode`.
- Add: OPERATOR's "+" holds New Signal… only.
- The label, hint and help tests in `RowAccessibilityTests` stay.

## Proof

- Before your first edit: `scripts/snapshots.sh build/8d-before`; after: `scripts/snapshots.sh
  build/8d-after`; list differences with
  `for f in build/8d-before/*.png; do cmp -s "$f" "build/8d-after/$(basename "$f")" || echo "$(basename "$f")"; done`.
  The list must be empty (menus are not drawn in snapshots; known GitLab artwork variants in
  `marks.png` and `signal-jira-reviewRequested-1.png` aside).
- While iterating: `scripts/test.sh swift -- --filter RowAccessibilityTests`,
  `SidebarInteractionTests`, `LockedSidebarTests`, `SidebarRowRedrawTests`, `KeyboardSettingsTests`.
- Then plain `scripts/test.sh`, in the background.

## Done when

- `grep -rn "accessibilityActions" app/Sources/AiTerm/Views` returns only the renderer in
  `RowCommand.swift`.
- `grep -rnw "TerminalRowAccessibility" app` and
  `grep -rn "enum Action" app/Sources/AiTerm/Views app/Sources/AiTerm/SidebarRowValues.swift`
  return nothing.
- `grep -rn "\"Pause\"\|\"Resume\"" app/Sources` returns nothing; "Pause Operator" appears only
  in the OPERATOR heading's command.
- `grep -rn "Open in Finder" app/Sources/AiTerm/Views` returns only the shared helper.
- Docs updated; snapshots identical; plain `scripts/test.sh` green.

## Not in this step

- "Switch On" without a count and the heading's source read (8e).
- The selection following its row (8e).
- A menu-bar item for Pause (not planned).
