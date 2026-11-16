# 8c. One heading module, one section heading module

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 8b (row values beside the projection), 8a,
and through them phases 1 to 5 (3c gave the Operator row one id and `.operatorChat`; 2b made the
project menu's Pull item read a default branch name that `ProjectActions` asks git for when the
heading row appears). Audit: SB F5, SB F15.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

- The design notes sketch `HeadingRow(value:trailing:menu:)` and `SectionHeading(title:fold:menu:)`
  with the per-kind parts passed in. This brief keeps the names but gives `HeadingRow` the value
  and the controller and lets the value's kind pick the title accessory, trailing slot and menu,
  and gives `SectionHeading` the controller and a kind. Reason: the signal heading is skipped by
  `.equatable()` when its value is unchanged, so every input must be in the value (closures
  cannot be compared), and each section heading must read its own fold value in its own body or
  `theSectionHeadingsDoNotRedrawForAStatusTheyDoNotDraw` fails.
- Where a removed signal's fold lives is not decided by the plan ("not written into task
  records"). This brief keeps it in memory in the projection, open by default, lost on relaunch.

## Why

A signal heading is meant to be drawn exactly like a project heading, and OPERATOR exactly like
PROJECTS. Today each pair is two hand-composed copies of the same parts, and the copies already
behave differently: Return on an empty project heading opens its context menu through a
synthesized right-click (`RowMenuAnchor`, an AppKit event hack built for one rare keystroke) while
Return on an empty signal heading does nothing; a locked workspace greys a project's menu item by
item but disables a signal heading whole; each maps its own source mark. Two defects ride along: a
removed signal's heading wears the pause glyph although its tasks keep running, and folding it
writes `collapsed` into every one of its tasks' saved records. The end state is one `HeadingRow`
drawing one `HeadingValue` for projects and signals, one `SectionHeading` for OPERATOR and
PROJECTS, Return on an empty heading running that heading's main command, no `RowMenuAnchor`, a
removed signal's heading without a pause mark, and its fold kept out of task records. Pixels stay
identical except the one listed difference below.

## Today

As the code stands after phases 1 to 5, 8a and 8b.

- `ProjectHeaderRow` (`app/Sources/AiTerm/Views/SidebarRows.swift`, about lines 141 to 234 today):
  takes a `ProjectSection`, builds `ProjectHeadingValue` (Core,
  `app/Sources/AiTermCore/Sidebar/HeadingValues.swift`: project, empty, collapsed, can move up or
  down, counts). Draws `HeaderChevron` (hidden when empty), `ProviderIcon(provider:)`, the title and
  `ProjectJiraBadgeView` in an inner stack `Space.gap` apart, a spacer, `StatusCountChips` when
  collapsed, all under `FoldOnTap` (enabled when not empty and the workspace can change, calling
  `controller.projects.toggleCollapsed`), then `AddMenu` (New Task…, New Review…, New Terminal…,
  the first two off for a plain folder; the whole "+" off while locked). Height `Size.projectRow`,
  `SidebarHeadingInset`, `RowPill`, `.background(RowMenuAnchor(id:))`, and a context menu: the "+"
  items greyed while locked, Open in Finder, Open in VS Code, Edit Project…, Pull, Move Up, Move
  Down, Remove Project…. `collapses` is read by `RowAccessibilityTests`. Tagged by `SidebarView`.
  Not `.equatable()`.
- `SignalHeader` (`Views/Operators/SignalRows.swift`): `Equatable` on its `SignalHeadingValue`
  (`app/Sources/AiTerm/SignalHeadingValue.swift`: id, name, source, enabled, collapsed, empty,
  removed, counts, help) and controller identity; used with `.equatable()`. Same geometry, its
  mark from a private switch over the source (`mark`), its title alone, a trailing slot with a
  `pause.fill` glyph while not enabled, `.tag` and `.help` inside the view, a context menu (Edit
  Signal…, Switch Off or Switch On, Remove Signal…; nothing for a removed signal), `.disabled` on
  the whole heading while locked, and a `.task` that reads the source of a switched-off signal to
  title "Switch On (starts n)".
- `SignalSidebar.init` (`app/Sources/AiTerm/SignalSidebar.swift`) appends a removed signal's saved
  configuration with `enabled = false`, which is why its heading shows the pause glyph.
  `SignalSection.collapsed` is the signal's `collapsed` or no tasks.
- `AppController.toggleCollapsed(_ signal:)` (`AppController+Signals.swift`): for a live signal it
  flips `signals[i].collapsed`; for a removed one it writes `configuration.collapsed` into every
  task's record. `AppController.reveal(_:)` opens a live signal's fold only.
- `AppController.activateSelection()` (`AppController.swift`): on a signal heading it folds or
  opens when it has tasks, else nothing; on a project heading it folds or opens when
  `projects.hasRows`, else it asks `openRowMenu` (default `RowMenuAnchor.openMenu(for:)`) on the
  next run-loop turn.
- `RowMenuAnchor` (`Views/RowMenuAnchor.swift`, 86 lines): weak anchor map, a synthesized
  right-mouse-down and a queued ↓. Callers: `ProjectHeaderRow` and `AppController.openRowMenu`
  only (`grep -rn "RowMenuAnchor\|openRowMenu" app`). Tests: `RowMenuAnchorTests`, and
  `SidebarInteractionTests.returnOnAnEmptyHeaderOpensItsMenu`.
- `SidebarHeader` (PROJECTS, `Views/SidebarRows.swift`) and `SignalOperatorHeading` (OPERATOR,
  `Views/Operators/SignalRows.swift`): the same twenty lines. Each reads its own fold value
  (`rows.projectsHeading` or `rows.operatorHeading`) in its own body, draws `SectionFoldLabel` and
  an `AddMenu`, is `Size.menuRow` high with `Space.base` above and `Space.tight` below, and counts
  its body under "projects" or "operator" for the redraw budget. OPERATOR's title adds " · paused"
  from `rows.operatorPaused`; its "+" is enabled by `canPresentNewSignal` and holds New Signal…, a
  divider, Pause Operator or Resume Operator. PROJECTS' "+" is enabled by `canChangeWorkspace` and
  holds Add Project…, Add Divider….
- Users of these types: `SidebarView.rows(of:in:controller:)`, `operatorRows`, `projectRows`;
  snapshots (`SidebarSnapshots`: `SidebarHeader(controller:)` twice); tests
  (`grep -rln "ProjectHeaderRow\|SignalHeader\|SignalHeadingValue\|ProjectHeadingValue\|SidebarHeader\|SignalOperatorHeading" app`).

## Behaviours that differ between the two headings today, and which one wins

1. Return on an empty heading: the project opens its context menu, the signal does nothing.
   Neither wins: both run their main command (project: New Task…, else New Terminal… for a plain
   folder; signal: Edit Signal…).
2. Locked workspace: the project greys menu items one by one; the signal disables the whole
   heading. The project wins: per-item enabling, no `.disabled` on the heading.
3. Mark: the project uses `ProviderIcon.source(of:)`, the signal a private switch. One mapping wins:
   a second `ProviderIcon.source(of:)` for a `SignalSource`, beside the provider one, with the
   signal's current marks.
4. Tag: the project is tagged by `SidebarView`, the signal tags itself. `SidebarView` tags both.
5. Equatable: the signal heading is `.equatable()`, the project's is not. Both are.
6. Tooltip: only the signal has one. The value carries a help text; an empty one adds no `.help`.
7. Fold of a removed signal writes into task records; a project writes its own record. Neither
   pattern for removed signals: their fold is runtime only (below).
8. Trailing slot and title accessory stay per kind: a project has its "+" and its Jira badge; a
   signal has its pause glyph slot and no accessory.

## Change

1. Add `HeadingValue` in the app target (new file `app/Sources/AiTerm/HeadingValue.swift`, replacing
   `SignalHeadingValue.swift`): `Equatable`, with id, mark (an `IconSource`), title, collapsed,
   empty, counts (only while collapsed, as today), help, and a kind: a project (the `Project`, can
   move up, can move down) or a signal (its source, removed, and paused, which is true only for a
   live signal that is switched off). Two initialisers, from a `ProjectSection` and from a
   `SignalSection`, computing what `ProjectHeadingValue` and `SignalHeadingValue` compute today
   (the signal help text byte for byte). Delete `ProjectHeadingValue` and its Core file.
2. Add `HeadingRow` (new file `app/Sources/AiTerm/Views/SidebarHeadings.swift`): a view taking a
   `HeadingValue` and the controller, `Equatable` on the value and controller identity like
   `SignalHeader` today. It draws the shared shape once (chevron, mark, title area, spacer, counts
   when collapsed, under `FoldOnTap`; trailing slot; height, inset, `RowPill`, help, context menu)
   and switches on the kind only for the title area, the trailing slot, the fold action and the
   menu, each drawn exactly as today's view draws it. Do not wrap the signal's title in the
   project's inner stack. Keep `collapses` (not empty and the workspace can change) as a property.
   Move `SectionFoldLabel`, `SectionFoldChevron`, `HeaderChevron`, `HeaderTitle`, `ProviderIcon`
   and `ProjectJiraBadgeView` into the same file. The signal kind keeps today's `.task` that reads a
   switched-off signal's source and its "Switch On (starts n)" title unchanged (8e removes it).
3. Add `SectionHeading` in the same file: one view for OPERATOR and PROJECTS, taking the controller
   and a kind (operator or projects). Its body reads only its own kind's fold value and title, so
   the section headings' redraw budget holds; do not build it from values read in `SidebarView`'s
   body. The "+" items, its help and its enabling stay per kind exactly as today (Pause and Resume
   included: 8d moves them).
4. `SidebarView` draws `HeadingRow(value:controller:).equatable().tag(id)` for each project and
   signal heading and `SectionHeading` for the two sections. Delete `ProjectHeaderRow`,
   `SignalHeader`, `SidebarHeader` and `SignalOperatorHeading`. `Views/Operators/SignalRows.swift`
   keeps `SignalOperatorRow` only.
5. Return on an empty heading, in `AppController.activateSelection()`: an empty project heading
   presents New Task… when `canCreateTask`, else New Terminal… when `canCreateTerminal`, else
   nothing; an empty signal heading calls `presentNewSignal(editing:)` with the live signal. A
   heading with rows still folds or opens. Delete `openRowMenu`, `RowMenuAnchor.swift` and its
   tests.
6. A removed signal: `SignalSidebar` no longer sets `enabled = false` on the saved configuration.
   Its section's collapsed state comes from a runtime set of folded removed signals that the
   projection holds and includes in its inputs (start: none folded, so a removed signal's heading
   draws open). `AppController.toggleCollapsed(_:)` flips that set for a removed signal and writes
   nothing to the workspace; it still flips `signals[i].collapsed` for a live one. `reveal(_:)`
   opens a removed signal's runtime fold as it opens a live one's, and for a task under the
   Operator never touches its project's fold.
7. Docs, one line each: `docs/keyboard.md` (Sidebar table, Return row: replace "An empty header
   opens its menu." with what Return now does on an empty project or signal heading);
   `docs/design/ui-patterns.md` (the `SignalOperatorHeading`, `SignalHeader`, `SignalHeadingValue`
   sentences and the `RowMenuAnchor` mention); `docs/architecture.md` (`SignalHeadingValue` becomes
   `HeadingValue`); the App composition inventory rows in `app/Sources/AiTermUI/README.md` naming
   the deleted views. Leave `docs/design/design-system.html` to the design-system sync.

## Keep

- `FoldOnTap`, `SidebarHeadingInset`, `RowPill`, `AddMenu`, `StatusCountChips`: the shared parts,
  unchanged.
- The heading's `.task` and "Switch On (starts n)": 8e removes them with the Core rule.
- Pause and Resume in OPERATOR's "+": 8d moves them.
- `SectionFold`, the mutual fold, `toggleOperatorOpen`, `crossSections` and `SectionCrossing`:
  kept on purpose by the plan.
- `projects.toggleCollapsed`'s `hasRows` guard and `ProjectActions.setCollapsed`.

## Decisions already taken

- A removed signal's heading always has tasks (it exists only while a task names it), so it is
  never empty; Return on it folds or opens. No empty-removed case to handle.
- The runtime fold set is never pruned: a removed signal's id is never reused, and the set is lost
  on relaunch, which is fine for a heading that disappears with its last task.
- Focus View and List View leave a removed signal's fold alone, as today (`setCollapsed` finds no
  signal or project for its id).
- A removed signal's heading still has no menu, as today.
- Locked workspace on a signal heading: Edit Signal… follows `canPresentNewSignal`, Switch and
  Remove follow `canChangeWorkspace`; the fold is off as today. Pixels do not change: nothing in
  the heading reads the enabled environment.
- Return on an empty project heading presents the sheet directly, as ⌘N does; it needs no
  run-loop deferral (that was for the modal menu).

## Tests

- Delete `RowMenuAnchorTests` (the behaviour is deleted) and
  `SidebarInteractionTests.returnOnAnEmptyHeaderOpensItsMenu`, replaced by: Return on an empty
  project heading presents New Task (a project with a provider) or New Terminal (a plain folder);
  Return on an empty signal heading presents the signal sheet in edit mode (wait for it as
  `FileMenuTests` waits for ⌘S); a locked workspace presents nothing.
- Add: a removed signal's `HeadingValue` is not paused while a live switched-off one is; folding a
  removed signal's heading collapses its section and leaves every task record byte for byte equal;
  `reveal` on a task under a folded removed signal opens it and leaves its project's fold alone.
- Adjust: `RowAccessibilityTests.aProjectHeaderCollapsesOnlyWithRowsInAnUnlockedWorkspace` and
  `LockedSidebarTests` to `HeadingRow`; `SignalSidebarTests` and `SignalSidebarPresentTests` to
  `HeadingValue`; snapshot code to `SectionHeading`.
- Redraw budgets that must hold unchanged: `SidebarRowRedrawTests`
  `expandedSignalHeadersIgnoreLedgersAndTheirChildStatusChanges`,
  `anExpandedProjectHeaderDoesNotRedrawForItsTasksStatus`,
  `theSectionHeadingsDoNotRedrawForAStatusTheyDoNotDraw`, and the arrow-key test.

## Proof

- Before your first edit: `scripts/snapshots.sh build/8c-before`; after:
  `scripts/snapshots.sh build/8c-after`; list differences with
  `for f in build/8c-before/*.png; do cmp -s "$f" "build/8c-after/$(basename "$f")" || echo "$(basename "$f")"; done`.
  The only allowed difference is `signals-removed.png`: the removed signal's heading has no pause
  glyph, its trailing slot empty. Every other `sidebar-*` and `signals-*` image, the selected and
  collapsed header images and the README fixture are identical. GitLab artwork in `marks.png` and
  `signal-jira-reviewRequested-1.png` has two known variants; capture again before calling that a
  difference.
- While iterating: `scripts/test.sh swift -- --filter SidebarRowRedrawTests`, `SidebarInteractionTests`,
  `SignalSidebarTests`, `SignalSidebarPresentTests`, `RowAccessibilityTests`, `LockedSidebarTests`,
  `SignalSnapshotTests`, `FileMenuTests`.
- Then plain `scripts/test.sh`, in the background.

## Done when

- `grep -rnw "RowMenuAnchor\|openRowMenu\|ProjectHeaderRow\|SignalHeader\|SignalHeadingValue\|ProjectHeadingValue\|SidebarHeader\|SignalOperatorHeading" app docs/keyboard.md docs/architecture.md docs/design/ui-patterns.md`
  returns nothing (whole words, so `SidebarHeading` and `SidebarHeadingInset` do not match).
- `grep -rn "configuration?.collapsed\|configuration.collapsed\|enabled = false" app/Sources/AiTerm`
  returns nothing.
- Snapshots differ only in `signals-removed.png` as described; budgets pass; plain
  `scripts/test.sh` green.

## Not in this step

- Menus as one command list drawn twice, Pause and Resume's one home (8d).
- The selection following its row, "Switch On" without a source read (8e).
- The section fold design itself (left out by the plan).
