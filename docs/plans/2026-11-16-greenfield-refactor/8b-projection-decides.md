# 8b. The projection decides each row's mark and "needs you"

Implementer: Opus 5.5, high. Depends on: 8a (`TaskItem.isUnderOperator`), and through it 1f (no
`queued` row state, no test-only attention path), 3a (no "Couldn't reopen" state), 3c (the
Operator row's one id and `.operatorChat`), 4b and 4c (one per-row teardown state, leaving rows
filtered in the projection), 5f (a row's current activity is runtime-only), 5h (the driven task
row's wording built in Core). Audit: SB F4, SB F14.

## Why

A sidebar row's trailing mark and whether it "needs you" are decided in several places today. The
projection sets a driven task's status and a `paused` flag, then the view turns status, the
Operator line's look, `paused` and removal into the mark (`TaskRowMark` inside
`Views/SidebarRows.swift`). "Needs you" has two rules written in three places: project rows count
done or needs input, the Operator section and Focus View's signal layout count needs input only.
The projection also hands views doctored copies of every task (conversations replaced by a fake
`"saved"` entry, the signal record rebuilt with a null item) because those copies double as its
change-detection key. All of this grew while rows were redesigned several times. The end state:
the projection decides each row's mark and "needs you" once and hands views small row values that
carry every fact a row draws or its menu needs; views add only what they observe per row
(selection, removal, missing checkout, thread count, preferences); every attention reader uses the
one flag; the tested pure row values live beside the projection, not in the view file. No pixel
changes and every redraw budget holds. A wrong change moves a per-row observation into the
projection (all rows would then redraw together) or changes a mark or a count anywhere.

## Today

As the code stands after phases 1 to 5 and 8a.

- `SidebarProjection` (`app/Sources/AiTerm/SidebarProjection.swift`), one `@Observable` owner
  built by `AppController`. `refresh()` builds `drawn`, a copy of every task with
  `conversations` emptied (or set to one fake conversation when a driven task has no window and a
  worker conversation) and its `signalTask` rebuilt with `item: .unknown(.null)` and a distant
  start date, so copies compare equal when nothing drawn changed. A private `Inputs` value (skipped
  sentences, source failures, the Operator row value, signals, `operatorOpen`, items, the doctored
  tasks, terminals, row sessions, branches, diffs, plus whatever 5f made it read for a task's
  current activity) gates derivation: equal inputs derive nothing and `derivations` does not move.
  It publishes `signalOperator`, `signalSections`, `entries`, `sections`, `tasks` (the doctored
  copies, by id), `terminals` (real `TerminalItem`s, by id), `operatorOpen`, `operatorPaused`,
  `operatorHeading`, `projectsHeading`. `usageRow(for:)` reads `tasks[id]?.agent` for the footer.
  The skipped-items sentence is built twice: in `refresh()` for `Inputs.skipped` and again in
  `SignalSidebar.init`.
- The attention lists live on the projection after 1f and 4c (today `projectsNeedingAttention`,
  `operatorNeedingAttention`, `projectSectionsNeedingAttention`; find them with
  `grep -n "NeedingAttention\|needingAttention" app/Sources/AiTerm/SidebarProjection.swift`). They
  already skip a task on its way out. Project rows and terminals count `TaskStatus.needsAttention`
  (done or needs input); the Operator row and driven tasks count `status == .needsInput`. Readers:
  the Dock badge and Focus View in `AppController`, the folded headings' amber counts
  (`SectionFold.attention`), `openOperatorAttention` and `openProjectsAttention`.
- `AppController.signalLayout(focus:)` (Focus View and List View) opens a signal while a task in
  it has `status == .needsInput`; projects use `SidebarModel.focusView`, which reads
  `ProjectSection.needsAttention` (Core).
- Core rows (`app/Sources/AiTermCore/Sidebar/SidebarModel.swift`): `TaskRow` (id, title, ticket key
  and URL, `ticketIsGitLabIssue`, merge request, live `BranchLabel`, avatars, status, base diff,
  `operatorLine`, `paused`, background jobs), `TerminalRow`, `ProjectSection`,
  `SidebarModel.taskRow(...)` and the terminal mapping in `section(...)`.
- Driven rows: `SignalSidebar` (`app/Sources/AiTerm/SignalSidebar.swift`) moves held tasks under
  their signal and applies, per row, the Core wording function 5h introduced (today
  `SignalSidebar.present`); it sets `operatorLine`, `status` and `paused`. Find it with
  `grep -rn "starting its worker" app/Sources`. `SignalOperatorRowValue.make` (same file) builds the
  Operator row's line, status, `paused`, `shown`, event and completed activity.
- Views: `TaskRowView(row:task:controller:)` (`Views/SidebarRows.swift`). Per row it reads
  `controller.focus.isSelected(id)`, `controller.checkouts.isMissing(id)`, the row's teardown state
  from `TaskTeardown` (today `remover.removal(of:)`), `controller.reviewThreads.threads(of:)`,
  `controller.preferences.badgeDetails` and `canChangeWorkspace`. It builds `TaskRowCaption`,
  `TaskRowBadges`, `TaskRowAccessibility` and `TaskRowMark(status:line:removing:paused:)`. From
  `task` it uses: the id (choose), `isUnderOperator` (Take Over), `kindName`, `worktreePath` (Open in
  Finder, VS Code badge and item), `jira` (Open in Jira or GitLab), `branch` (VoiceOver label), and
  `task != nil` as a guard. `SignalOperatorRow` (`Views/Operators/SignalRows.swift`) builds its own
  `TaskRowMark` from its value. `SidebarView.taskRows(of:in:controller:)` and `operatorRows(...)`
  pass `rows.tasks[row.id]`.
- Pure values in the view file (about lines 632 to 922 today): `ProjectJiraBadge`,
  `TaskRowAccessibility`, `TaskRowMark`, `TaskRowCaption`, `TerminalRowAccessibility`,
  `TaskRowBadges`.
- Snapshot code builds rows by hand: `SidebarSnapshots.workCards` sets `row.status` on a copied
  `TaskRow` and passes `task:`; `SidebarSnapshots` and `SignalSidebarSnapshots.waitingMarks` pass
  `task:` too (`grep -rn "TaskRowView(" app/Sources app/Tests`).
- Tests: `SidebarRowRedrawTests`, `SidebarProjectionTests`, `SignalSidebarTests`,
  `SignalSidebarPresentTests`, `TaskRowCaptionTests` (holds `TaskRowMarkTests`),
  `RowAccessibilityTests`, `SidebarModelTests`, `TaskRowOverflowTests`, `BackgroundCardTests`,
  `AppControllerTests` (Dock badge and Focus View), `WorkBudgetTests`.

## Change

1. Move `TaskRowMark` (cases: a status, ended, pause sign) to Core beside `TaskRow`. Its rule
   becomes a Core initialiser from a status, an optional Operator line and a paused flag: paused
   gives the pause sign; an `ended` line look gives the check unless the status is working, needs
   input or background; anything else is the status. Removal is not an input any more.
2. `TaskRow` gains `mark` and `needsYou`, and the facts its view and menu need: `kindName`,
   `worktreePath`, `savedBranch` (the task's own branch, which VoiceOver reads after the title; the
   live `branch` label can differ when the agent moved), and `underOperator` (from 8a's
   accessor). `paused` is deleted: the pause sign is now in `mark`. New fields get defaults so the
   tests that build rows by hand still compile.
3. `TerminalRow` gains `needsYou`.
4. `SidebarModel.taskRow` sets `mark` to the status's mark, `needsYou` to
   `status.needsAttention`, and the new facts from the task. The terminal mapping sets `needsYou`
   the same way. `ProjectSection.needsAttention` reads the rows' `needsYou`.
5. Where 5h's Core wording is applied to a driven row, set the row's `mark` with the rule from
   step 1 (the paused flag that set `paused` before) and `needsYou` to "status is needs input".
   If 5h's function returns a value, add the mark and the flag to that value in Core, so the
   decision stays in one tested place; `SignalSidebar` only copies it onto the row.
   `SignalOperatorRowValue` gains `mark` (same rule, its own paused flag) and `needsYou` (its
   status is needs input). Its `paused` stays: the heading and the Pause item read it until 8d.
6. Every attention reader uses `needsYou`: the projection's attention lists, the folded headings'
   counts, `AppController.signalLayout(focus:)`, and `ProjectSection.needsAttention`.
   `TaskStatus.needsAttention` remains only as the rule `SidebarModel` applies to project rows and
   terminals.
7. Replace the doctored copies with an explicit key. A private `DrawnTask` value, built by one
   function from a task (and the state it needs), holds exactly what the derivation reads: id,
   project, kind, title, ticket, merge request, branch, base branch, worktree path, agent, whether
   it is under the Operator, and for a driven task the signal id, phase (with its condition),
   waiting facts, blocked reason, the choosing counts, its window being absent with a worker
   conversation saved, the saved configuration only when its signal was removed, and the text of
   its first current question. `Inputs.tasks` becomes a list of these. Nothing else from
   `TaskItem` or `SignalTask` enters the key, so journals, reply markers, launch attempts,
   conversation ids and ledger entries still derive nothing.
8. The projection stops publishing `tasks`. It publishes `taskAgents` (task id to saved agent),
   which only `usageRow(for:)` reads. `terminals` stays as it is (real values, not doctored).
9. The skipped-items sentences are built once in `refresh()` and handed to `SignalSidebar`.
10. `TaskRowView` takes only `row` and `controller`. It draws the spinner while its own teardown
    state says a removal or archive is in progress, otherwise `row.mark`. Everything it took from
    `task` comes from the row; menu actions that need the `TaskItem` (Rename) fetch it from
    `controller.state` when clicked, as Archive and Remove already do. `SignalOperatorRow` draws
    `value.mark`. `SidebarView` stops passing `rows.tasks[...]`.
11. Move `ProjectJiraBadge`, `TaskRowAccessibility`, `TaskRowCaption`, `TerminalRowAccessibility`
    and `TaskRowBadges` to a new file `app/Sources/AiTerm/SidebarRowValues.swift` beside the
    projection. `TaskRowAccessibility` is built from row facts (title, saved branch, kind name)
    plus missing, removing and `canChangeWorkspace`. `Views/SidebarRows.swift` keeps only views.
12. Snapshot code: drop the `task:` arguments; where it sets a row's `status` by hand, set its
    `mark` to that status's mark too, so every image draws as before.

## Keep

- The per-row reads in the views (selection, teardown state, missing checkout, thread count, badge
  preferences, `canChangeWorkspace`, `ExternalApps.vscode`, hover, the background card's hover, the
  motion environment). Each is a `PerRow` cell or a value only that row reads; moving one into the
  projection would make every change re-derive and redraw every row (`SidebarRowRedrawTests`).
- The derivation gate (`Inputs` equality and the `derivations` counter) and the rule that the
  projection writes a published property only when it changed.
- `TaskRow.status` and `operatorLine`: the status counts, the background card's VoiceOver value and
  the row's tooltip detail read them.
- `TaskStatus.waiting` and the waiting ring; `StatusMark`; `TaskRowMarkView` (a view, stays in
  the view file).
- `SignalHeader`, `SignalHeadingValue`, `ProjectHeaderRow` and `ProjectHeadingValue` as they are:
  headings are 8c's.

## Decisions already taken

- "Needs you" keeps today's two rules, now decided where the status is decided: a project task or
  terminal needs you when it is done or needs input; a driven task and the Operator row only when
  they need input. No count, badge or fold changes.
- A paused driven row: pause sign, idle status, does not need you. A driven row whose worker shows
  a permission prompt: needs input, needs you, its status mark.
- A row on its way out keeps its `needsYou`; the attention lists already skip it (4c). The view
  draws the spinner for it, as today.
- The VS Code badge's `task != nil` guard goes: a drawn row always has its task. Use
  `ExternalApps.vscode != nil` alone.
- A task removed between a derivation and a click: actions already fetch the current task and do
  nothing when it is gone.
- A fact a row draws that the key leaves out would leave the row stale. Build the key from what
  `SidebarModel.taskRow`, the driven wording and `SignalSidebar` actually read, and let the tests
  below catch a gap. The first-question text is new in the key: today a question moving from one
  task to another with the same count could leave both rows stale.

## Tests

- Move `TaskRowMarkTests` to Core as tests of the mark rule (drop the queued cases 1f removed and
  the removing cases, which are the view's now). Add: a projected driven row that is paused has the
  pause sign; one whose stage is done has the check while idle and its status mark while its worker
  works.
- Add Core or projection tests for `needsYou`: project task done or needs input yes; terminal done
  yes; driven task waiting, idle or done no; driven task with a question, blocked, or a permission
  prompt yes; the Operator row with a question yes.
- Add one app test that a driven task whose tab ended its turn (`.done`) is counted by no reader
  (Dock badge, Focus View, folded count), while a project task in the same state is counted by all.
- Add a projection test that each drawn driven fact changed alone (blocked reason, waiting facts,
  a question for the task, the window closing with a saved worker conversation) derives once and
  changes that row.
- Adjust: `SidebarProjectionTests` (`readsTheList` reads `entries`, `signalSections` and
  `terminals`; the `rows.tasks` title check reads the row in `sections`); `SignalSidebarTests`
  (`paused == true` becomes `mark == .pauseSign`; `TaskRowView` built without `task:`);
  `SignalSidebarPresentTests`; `RowAccessibilityTests` (new `TaskRowAccessibility` initialiser);
  `SidebarModelTests` attention cases.
- Deleted: none beyond the queued and removing cases in `TaskRowMarkTests`; the queued behaviour
  was deleted in 1f, and the removing spinner is covered by `SidebarRowRedrawTests.aRemovalRedrawsOnlyItsRow`
  plus the `sidebar-removal` snapshots.
- No fixture changes.

## Proof

- Before your first edit: `scripts/snapshots.sh build/8b-before`. After: `scripts/snapshots.sh
  build/8b-after`. List differing images with
  `for f in build/8b-before/*.png; do cmp -s "$f" "build/8b-after/$(basename "$f")" || echo "$(basename "$f")"; done`.
  The list must be empty; open any listed pair and look. The GitLab artwork in `marks.png` and
  `signal-jira-reviewRequested-1.png` has two known variants: capture again before calling that a
  difference.
- While iterating: `scripts/test.sh swift -- --filter SidebarRowRedrawTests`, then
  `SidebarProjectionTests`, `SignalSidebarTests`, `SignalSidebarPresentTests`, `TaskRowCaptionTests`,
  `RowAccessibilityTests`, `SidebarModelTests`, `AppControllerTests`, `ViewWorkBudgetTests`.
- Then plain `scripts/test.sh`, in the background.

## Done when

- `grep -rn "TaskRowMark(status" app/Sources/AiTerm/Views` returns nothing.
- `grep -rnw "rows\.tasks" app/Sources/AiTerm app/Tests` (Core's private `Rows.tasks` in
  `SidebarModel` is another thing and stays) and
  `grep -rn "unknown(\.null)\|id: \"saved\"" app/Sources/AiTerm/SidebarProjection.swift` return
  nothing.
- `grep -rn "needsAttention" app/Sources` returns only its definition on `TaskStatus`, its use in
  `SidebarModel` and `ProjectSection.needsAttention`.
- `grep -rn "== \.needsInput" app/Sources/AiTerm/SidebarProjection.swift app/Sources/AiTerm/AppController.swift`
  returns nothing.
- `grep -n "^struct\|^enum\|^final class" app/Sources/AiTerm/Views/SidebarRows.swift` lists only
  views and view modifiers.
- Snapshots identical; every redraw budget passes; plain `scripts/test.sh` green.

## Not in this step

- The heading modules, Return on an empty heading, a removed signal's heading (8c).
- Menus as command lists, Pause and Resume (8d).
- The selection following its row, the source read in the signal heading (8e).
- The daemon's one ordered work list (6a), which changes `background` on the rows.
