# 1f. App leftovers

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1a to 1e (1d already removed the dead `OperatorLine`
members; 1e already removed dead `OperatorPorts` fields). Comes from: TL F4, SB F1, SB F2, SS F4, SS F7,
SS F8, TS F2.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

Two claims in the plan and audits do not hold in the code, and one needs a decision.

- `CreationSteps.agentsListStep` and `CreationSteps.summarizesOnlyOnLast` do not go with the broadcast
  step config. New Signal's `SignalModel.steps` builds `CreationSteps(count: 5, agentStep: nil,
  agentsListStep: 4, promptSteps: [2, 3], summarizesOnlyOnLast: true)`, and `showsDestination` and
  `hasPrompt` read both. Only `CreationSteps.broadcast`, `showsCommand(onStep:)` and the test
  `broadcastCreatesOnStepFive` go. `saysNoAgentCanRun` stays too (the footer reads it).
- `AgentCommand.previewCommand` is not only the New Task footer's: `AgentCommandTests` uses it in eight
  places. After the footer preview is gone it has no product caller. It goes, and its test lines are
  converted to `build` calls or deleted as listed under Tests.
- `TaskDraft` keeps one private derived value for the automatic branch prefix (see Decisions), not
  literally "one string and one flag", so that clearing a ticket still keeps the prefix it chose and a
  fresh draft still reads `feat/` in the branch field.

## Why

Before signals, AiTerm had broadcasts, a board and a Shelf. Those screens are gone, but their
scaffolding stayed: a one-case row enum, a `queued` row state nothing sets, a second attention list
and Dock badge that only tests call, pickers and a command preview no sheet draws, a prompt editor
that nobody disables, and comments naming types that no longer exist. A reader meets a second kind of
archive row, a board and a Shelf that are not there. After this step the Archive is called Archive
everywhere in code, the dead members and views are gone with the tests that only exercised them, and
the live behaviour (and every pixel) is unchanged.

## Today

Every claim below was grepped over `app/Sources`, `app/Tests`, `daemon`, `hooks`, `compat`,
`scripts` and `docs` (not `docs/research`, `docs/plans`, `docs/reviews`: those are history, never edit
them). Re-run each grep first.

**Archive naming.**
- `AiTermCore/Tasks/ArchiveSearch.swift`: `ShelfRow` is a one-case enum (`.task(ArchiveSearch.Entry)`)
  with `id` and `shelvedAt`; `ArchiveSearch.rank(_ rows: [ShelfRow], ...)` and `tier(of row: ShelfRow, ...)`
  exist only to wrap and unwrap it; the second `rank(_ entries: [Entry], ...)` wraps and unwraps again.
  Orphan doc line "An ended broadcast as the Shelf lists it" sits at the top with no declaration.
- `AiTermCore/Tasks/AppState+Archive.swift`: `shelfRows` (maps `archiveEntries` to `ShelfRow`), plus an
  orphan comment about ended broadcasts.
- `AiTerm/ArchiveSheetModel.swift`: `entries: () -> [ShelfRow]`, `Projection.rows/highlighted`,
  `primaryTitle(of:)` (one-case switch returning "Restore"), `performHighlighted()` (one-case switch).
- `AiTerm/Views/ArchiveSheet.swift`: `row.shelvedAt`, `switch row { case .task ... }`, the constant
  `let opens = false` in `perform()`, doc text about "ended broadcast ... opens its sheet", and a stray
  doc comment at the end of the file ("An ended broadcast on the Archive") with no declaration under it.
- `AiTerm/AppController.swift`: `presentArchive()` reads `state.shelfRows`; `removeFromShelf(_:)`
  calls `archiver.confirmRemove(archived:)`.
- `AiTerm/Snapshots/SheetSnapshots.swift` (`ArchiveSnapshots.model(entries:)`, `rows`): types and an
  orphan comment.
- Names: `WorkMeter.Work.archiveRank` has the comment "A Shelf projection's search ranking";
  `TaskWorkflow.swift` (about line 36), `TaskArchiver.swift` (about line 84), `WindowReconciler.swift`
  (about line 109), `SheetChrome.swift` (about line 30), `SheetKind.swift` (about line 71) mention
  Shelf, Shelve or broadcasts.
- Tests: `ArchiveSheetModelTests` (`entry(...) -> ShelfRow`), `ViewWorkBudgetTests` (`archivedRow`,
  `ShelfSource`, tests named `...TheShelf...`), `WorkBudgetTests` (`shelvingAndRestoringATaskSpawnsGit`,
  `savingTheFrozenWorkspaceWith500ShelvedTasks`), `ArchiveTests`
  (`shelvingAnUnknownFolderKeepsItUnlessExplicitlyConfirmed` and its doc), `TaskWorkflowTests`
  (`shelvesOwnHalfFinishedArchiveIsCleanedUpOnARetry`), `ArchiveSearchTests` (an empty section header
  "ended broadcasts on the Shelf").
- Saved keys: none of these is saved. `ShelfRow` is not `Codable`, `shelvedAt` is a computed property
  over `ArchivedTask.archivedAt`, which is the saved key and stays. `docs/design/design-system.html` has a
  CSS class `.shelf` that is unrelated styling: leave it.

**Controller and coordinator members.**
- `AppController.choose(task:tab:)`: no caller (`grep -rn "choose(task" app` shows only one-argument
  calls). `AppController.openNote(_:)`: only caller is `SignalSidebarTests.aQuestionNotificationSelects...`;
  it duplicates the closure `AppController.init` installs on `operatorPorts.notifications.onOpen`.
- `SheetCoordinator.onDismiss`: declared and called in `sheet`'s `didSet`, never assigned (`grep -rn onDismiss
  app` hits only this and the daemon's unrelated `dismissStartup`). `SheetCoordinator.onChange` is assigned only
  by `AppController.init` (`sheets.onChange = ... refreshRows()`), documented as "the rows derive the board
  while its sheet shows"; `SidebarProjection` reads no sheet, so it drives nothing. With both gone the
  `didSet` has no body.
- `AppController.choose(_ row: RowSelection)`: the `.operation(let id)` case has two branches that both
  call `focus.select`.
- `TaskRemover` (`removeAutomatically`, about line 263): `catch let waiting as ClosingWait { throw waiting }
  catch { throw error }` rethrows what it caught.
- Empty comment stubs and orphan doc blocks: `AppController.init` end (about lines 262-265, a comment about a
  board and "D7" followed by blank lines), `AppController` about lines 485-486 ("The board of `run`..."),
  `ProjectActions` about lines 245-247 (names the retired `foldedRuns`), `SheetCoordinator` about lines
  139-141 and 181-182, `AppState+Archive` about lines 40-42, `ArchiveSearch` lines 3-4, `SheetKind` about lines
  68-71 and the stray comment after `case .terminal` in `RenameTarget.subtitle`, `SidebarView` about lines
  320-323 (`OperatorWakeNotice`, no declaration), `SidebarRows` about lines 726-730, `SidebarModel` about
  lines 470-472.
- Comments naming types that do not exist (`presentBoard`, `BoardFocus`, `chooseOperatorRow`,
  `presentNewBroadcast`, `BroadcastBoardHost`, `OperatedTask`): `grep -rn` for each finds them only in
  comments, in `AppController`, `SheetCoordinator`, `SheetKind`, `TaskRemover` and
  `app/Tests/AiTermTestSupport/Builders.swift`.

**The `queued` row state.** `TaskRow.queued` (`AiTermCore/Sidebar/SidebarModel.swift`) is never set true:
`SidebarModel.taskRow` passes `queued: false` through `RowFacts`. Plumbing: `RowFacts` (a struct used only in
`taskRow`, with `queued` and a `paused` that is always false), `TaskRowView` in `Views/SidebarRows.swift`
(`row.queued` in three places and `queued:` passed to the next two), `TaskRowAccessibility.init(queued:)`
and its "It has no window until the Operator starts it." hint, `TaskRowMark.init(queued:)`. No source builds
`TaskItem.isQueuedByOperator` (the name appears only in comments). Only `BackgroundCardTests` and
`TaskRowCaptionTests` pass `queued`. `TaskRow.paused` is live (`SignalSidebar.present` sets it): keep.

**Unread hand-off counts.** `ProjectSection.operatorTasks` and `operatorWorktrees` are written by
`SidebarModel.section` and `SignalSidebar.init` and read by nothing (`grep -rn "operatorTasks\|operatorWorktrees"
app` shows only those writes and the declarations; the `operatorWorktrees:` parameter of
`ProjectActions.removalDetail` is a different, live value). `SidebarModel.Rows.held` is always `[:]`.
`ProjectActions.confirmRemove` computes its own `held` count: live.

**The test-only attention path.** `SidebarModel.needingAttention` and `firstNeedingAttention`, and the whole
`AiTermCore/Interface/DockBadge.swift`, have no source caller. Their callers are `DockBadgeTests`,
`SidebarModelTests` (three places: about lines 103, 170-186, 267) and `SignalSidebarPresentTests` (about
line 166). The live path is `SidebarProjection.projectsNeedingAttention` (operator rows first, then
`projectSectionsNeedingAttention`), used by `AppController.updateDockBadge` and `showFocusView`, each repeating
the same closure that drops `remover.leavingTasks`. Live coverage today: `AppControllerTests`
(`theDockBadgeCountsWhatFocusViewStepsThrough`, `theDockBadgeIsWrittenOnlyWhenItsLabelChanges`,
`focusViewSelectsTheFirstRowNeedingAttention`).

**Dead views and sheet config.** Each has zero product callers (grep the name over `app/Sources`):
- `Views/SearchPicker.swift`: `SearchPicker` (generic view; only `SearchPickerStateTests` builds it),
  `PickedItemField`, `LaneChip`. `PickerResultRow` and `TicketPickerField` in the same file are live
  (`ProjectSheet`, `NewReviewSheet`, `NewTaskSheet`, `PickerResultRowTests`).
- `Views/ChipsPicker.swift`: `ProjectResultRow` (zero uses). `PickChip`, `ChipsPicker`, `ChipFlow` are live.
- `Views/SheetChrome.swift`: `AgentSegmented`, `AgentSegmentLabel` (only `AgentSegmented.isSelectable` is
  called, by `NewReviewSheetTests`), `CommandBlock` (zero uses).
- `Views/DestinationLine.swift`: `Destination.operatorWindow` (zero uses; the other `.operatorWindow` hits are
  `OperatorNote.Target`).
- `CreationModel.swift`: `CreationModel.previewCommand`, `CreationModel.composedPrompt`,
  `CreationKind.composedPrompt` (protocol requirement, its default and the two overrides in
  `TaskCreationModel.swift` and `ReviewCreationModel.swift`): callers are tests only. The launcher composes
  its prompt itself through `AgentCommand.composePrompt` (`TaskWorkflow`). `CreationSteps.broadcast` and
  `showsCommand(onStep:)`: tests only. `AgentCommand.previewCommand`: `CreationModel.previewCommand` and
  `AgentCommandTests` only.
- `Views/Steps/PromptStep.swift` reads `\.isEnabled` to dim its editor, and `Views/PromptEditor.swift` has
  `enable(_:_:)`, called from `makeNSView` and `updateNSView` with the environment's `isEnabled`. No caller
  wraps a prompt step in `.disabled` (`grep -rn "\.disabled(" app/Sources/AiTerm/Views`: none around
  `PromptStep` or its sheets). The same file's `wantsFocus` comment says "a disabled editor doesn't take it".
- `Views/NameSheet.swift`: the subtitle draws only while `closing == nil`; `newDivider` and `newTerminal` both
  pass `closing`, so their subtitles ("Groups the projects under it in the sidebar.", "Opens a shell in the
  project folder.") never draw, and the branch `closing == nil, let destination` is dead. Renames pass no
  `closing`, so `RenameTarget.subtitle` is live.
- `Views/ModelReasoningFields.swift`: the `missingModelLabel` parameter (`grep "missingModelLabel:"` is empty;
  only its default is read). `KeyboardSettingsPane.spokenNames`: the "1–3" and "1–5" entries (only "1–4" is
  used).

**TaskDraft.** `AiTermCore/Tasks/TaskCreator.swift`: `TaskDraft` stores `branchType`, `branchName`, `fullBranch`,
`typeEdited`, `branchEdited` and has `setBranch`, `setBranchType`, `setFullBranch`. The sheet (`NewTaskSheet`)
only calls `setFullBranch`; `setBranch` and `setBranchType` on a `TaskDraft` are called by tests only (the
`setBranch` hits in `SheetSnapshots`, `NewReviewSheet` and the review tests are `ReviewDraft`'s, a different
type). `BranchType.split` is used only by `TaskDraft`. A fresh draft reads `feat/` in the New Task branch
field today.

## Change

1. **Archive naming.** Make `ArchiveSearch.Entry` `Identifiable` (id is `archived.id`) and delete `ShelfRow`.
   `ArchiveSearch.rank` takes and returns `[Entry]` (one function; delete the wrapping overload) and `tier(of:)`
   takes an `Entry`; sort newest first by `entry.archived.archivedAt`. Delete `AppState.shelfRows`; the sheet reads
   `archiveEntries`. `ArchiveSheetModel` holds `[ArchiveSearch.Entry]`; `primaryTitle` becomes a constant
   "Restore" (keep the `Projection.primaryTitle` optional: nil with nothing highlighted); `performHighlighted()`
   restores the highlighted entry and returns whether there was one. `ArchiveSheet.perform` dismisses after a
   successful `performHighlighted()` with no `opens` constant; its rows draw `ArchiveRow(entry:date:)`
   directly and use `row.archived.archivedAt` for the date label. `AppController.removeFromShelf` becomes
   `removeFromArchive`. Rename the tests and test helpers listed under Today to Archive and archive wording
   (for example `movingTheArchiveHighlightDoesNotRankAgain`, `ArchiveSource`,
   `archivingAndRestoringATaskSpawnsGit`, `savingTheFrozenWorkspaceWith500ArchivedTasks`,
   `archivingAnUnknownFolderKeepsItUnlessExplicitlyConfirmed`, `archivesOwnHalfFinishedArchiveIsCleanedUpOnARetry`
   becomes `anArchiveThatStoppedHalfwayIsCleanedUpOnARetry`). Delete the empty header comment in
   `ArchiveSearchTests`.
2. **Controller and coordinator.** Delete `AppController.choose(task:tab:)`. Delete `AppController.openNote`
   and rewrite `SignalSidebarTests.aQuestionNotificationSelectsTheOperatorThroughTheManagedFocusPath` to fire the
   installed closure: `controller.signalController.ports.notifications.onOpen?(.operatorWindow)` (the test's
   ports hold a `RecordingNotifications`, whose `onOpen` is exactly the closure `AppController.init` sets).
   Delete `SheetCoordinator.onDismiss`, `SheetCoordinator.onChange`, the `sheets.onChange = ...` line in
   `AppController.init`, and the now empty `didSet` on `sheet`. Collapse `choose(_ row:)` to one case for
   `.operation`, `.terminal`, `.project`, `.signal` that returns `focus.select(row)`. Delete the two no-op
   `catch` clauses in `TaskRemover.removeAutomatically` (the enclosing function already propagates both).
3. **Comment stubs.** Delete every orphan comment and blank-line stub listed under Today. For each doc comment on
   a symbol this step edits, rewrite it to say what the code does now. Do not hunt comments elsewhere:
   step 1j sweeps the rest by grep.
4. **`queued`.** Delete `TaskRow.queued`, `RowFacts` (build the row with `avatars` and `status` directly; `paused`
   keeps its default false), the three `row.queued` uses in `TaskRowView` (the title is `dimmed` only when
   `removing`; `jobs` is empty only when `removing`), `queued:` from `TaskRowAccessibility.init` (and its hint
   branch) and from `TaskRowMark.init`. Rewrite their doc comments, which still describe a queued Operator task.
5. **Hand-off counts.** Delete `ProjectSection.operatorTasks`, `operatorWorktrees`, `SidebarModel.Rows.held`
   (and the `held: [:]` argument), the `held` locals in `SidebarModel.section`, and the line in
   `SignalSidebar.init` that adds to them (the `projects` mapping still removes the held tasks from each
   project's rows).
6. **Attention and Dock badge.** Delete `DockBadge.swift`, `SidebarModel.needingAttention` and
   `firstNeedingAttention`. Add one method on `SidebarProjection`, `needingAttention(skipping: Set<UUID>)`,
   returning `projectsNeedingAttention` without the task rows whose id is in the set. `AppController.updateDockBadge`
   and `showFocusView` call it with `remover.leavingTasks`; the two copies of the filter closure go. Port the
   live cases of `DockBadgeTests` and the three `SidebarModelTests` places onto a projection-driven test
   (see Tests).
7. **Dead views.** Delete `SearchPicker`, `PickedItemField`, `LaneChip` and the file `SearchPicker.swift`
   after moving `PickerResultRow` and `TicketPickerField` into `ChipsPicker.swift` unchanged. Delete
   `ProjectResultRow`, `AgentSegmented`, `AgentSegmentLabel`, `CommandBlock`, `Destination.operatorWindow`.
   Rewrite comments that name `SearchPicker` (`Dropdown.swift`, `ChipsPicker.swift`, `JiraTicket.swift`,
   `AiTermUI/Palette.swift`, `AiTermUI/Metrics.swift`) to name `ChipsPicker` or the field, and the line in
   `docs/keyboard.md` (about line 67) to "An open `ChipsPicker` list". Do not change any token value in `AiTermUI`.
8. **Command preview and broadcast step config.** Delete `CreationModel.previewCommand` and `composedPrompt`,
   `CreationKind.composedPrompt` with its default and both overrides, `CreationSteps.broadcast`,
   `CreationSteps.showsCommand(onStep:)`, `AgentCommand.previewCommand`. Rewrite the doc comments of
   `CreationSteps`, `AgentCommand.invocation` ("shared by build and previewCommand") and
   `Sheet.creationHeight` in `AiTermUI/Metrics.swift` (its text sizes the sheet by "the command" row;
   the value 500 stays, the words change). Fix the sentence "previews the command before launch" in
   `README.md` (about line 68) and `docs/configuration.md` (about line 34): the sheet shows no command.
9. **Prompt editor.** Remove `PromptStep`'s `\.isEnabled` read and its opacity modifier, and `PromptEditor.enable`
   with its two calls and the `isSelectable` guard and comment in `viewDidMoveToWindow`. The doc comment of
   `PromptStep` loses "Disabled, its editor alone is dimmed...".
10. **Subtitles.** In `NameSheet` delete the `subtitle` parameter, stored property and the
    `if closing == nil { SheetSubtitle(subtitle) }` header for the two creation sheets; keep the subtitle for
    renames. The simplest result: `subtitle` becomes optional (`String?`), `newDivider` and `newTerminal` pass
    none, `rename` passes `target.subtitle`; the dead `closing == nil, let destination` branch goes.
    Delete the `ModelReasoningFields.missingModelLabel` parameter (the placeholder reads the constant text
    "Choose a current model…" directly) and the "1–3" and "1–5" `spokenNames` entries.
11. **TaskDraft.** See Decisions for the exact behaviour. Remove `branchType`, `branchName`, `typeEdited`,
    `fullBranch` as stored public or separate state; keep `branch` (read), `setFullBranch`, `setTitle`,
    `apply(ticket:)`, `worktreeSlug`. Delete `TaskDraft.setBranch`, `setBranchType` and `BranchType.split`
    (and its test).

## Keep

- `TaskRow.paused`, `SignalSidebar.present`, everything under `SignalSidebar` except the hand-off line: live.
- `ProjectActions.confirmRemove`'s `held` and `removalDetail(operatorWorktrees:)`: live (the alert says how many
  worktrees signals hold).
- `ReviewDraft.setBranch`, `ReviewCreationModel`'s `composePrompt` use via `AgentCommand.composePrompt`,
  `AgentCommand.composePrompt` itself and `AgentCommand.build`: the launcher uses them.
- `CreationSteps.agentsListStep`, `summarizesOnlyOnLast`, `agentStep`, `saysNoAgentCanRun`, `hasPrompt`,
  `showsDestination`: New Signal and the footer read them.
- `AgentStep.missingAgentNote` and its tests; `SegmentedControl` in `AiTermUI` (used by Settings and signals).
- `DropdownKeys` and its four tests in `SearchPickerTests.swift`: live (`ChipsPicker` uses `DropdownKeys`).
- `OperatorLine` (1d trimmed it), `OperatorBadge` and `DecodeWords` (step 8 merges them), `SidebarHeading.style`
  and `.ink` (not listed in the plan for this step), `OperatorRow` (phase 3c), `AppController.openRowMenu`
  (phase 8c): other steps own them.
- `AgentCommand.resumeWorker`: called only by tests, but it is not in this step's list. Report it, do not
  delete it.
- `docs/design/design-system.html` `.shelf` CSS class, every file under `docs/reviews/`.

## Decisions already taken

- **TaskDraft branch.** A fresh draft's `branch` reads `feat/` (the field shows it today; pixels must not
  change). Until the person edits the branch, it is the automatic prefix plus the slug of the ticket's branch
  key and summary, or of the title when no ticket: picking a ticket re-derives it, typing a title re-derives
  it. The prefix is `BranchType(issueType:)` of the ticket, `feat` with none; clearing the ticket keeps the
  prefix it had chosen (today's behaviour, tested). One private derived prefix value is allowed for that; there
  is no public type, no setter and no second branch representation. After `setFullBranch` with a changed value,
  the branch is the person's: nothing re-derives it (this also stops the prefix following a ticket, as today,
  because today `setFullBranch` sets `typeEdited` too). `setFullBranch` with the current value is ignored, as
  today. `worktreeSlug` is empty while the unedited branch has no name after its prefix, and for an edited branch
  that is blank; otherwise `BranchNaming.worktreeSlug(branch:)`.
- **Dock badge filter.** The filter keeps its meaning (tasks on their way out are not counted). Phase 4c moves it
  into the projection for good; here it only moves out of the controller's two closures.
- **A `SearchPicker` reader in docs or comments that is not listed:** rewrite it to `ChipsPicker`.
- **`AgentCommand.build` and `invocation`:** their `operated:` parameter stays; step 1j renames it.
- **Comments in files this step edits that narrate other history** (a broadcast in a doc comment of a symbol you
  are not touching): leave them for 1j.
- A deleted view with no remaining test coverage needs none: it drew nothing.
- Nothing here can lose a saved value: no saved key is renamed (see Today, Archive naming).

## Tests

Delete (each with its survivor, or "behaviour deleted"):
- `DockBadgeTests` (whole suite) and the three `SidebarModelTests` places (`needingAttention` empty check in the
  status-count test, `firstNeedingAttentionFollowsTheDrawingOrder`, the `DockBadge.label` line of the usage test):
  replaced by the ported projection tests below. The usage assertions in that test stay.
- `SignalSidebarPresentTests.theOperatorRowAndTheDockBadgeDoNotCountAWaitingTask`: change the `DockBadge.label`
  line to read the projection: the operator row and the dock count do not count a waiting task (assert
  `needingAttention(skipping: [])` is empty). Do not delete the test.
- `SearchPickerStateTests` (`newResultsStartTheHighlightAtTheFirstRow`, `openingTheListFocusesItsField`): behaviour
  deleted (`SearchPicker` has no caller). Rename the file and suite `SearchPickerTests` to `DropdownKeysTests`.
- `CreationSheetStepsTests.broadcastCreatesOnStepFive` and the `showsCommand` line of
  `taskAndReviewShareThreeStepsWithTheAgentLast`: behaviour deleted. Rewrite its header doc (it says New
  Broadcast has five steps).
- `TaskCreationModelTests` (about lines 132 and 237-241): the `previewCommand` assertions: behaviour deleted. The
  surviving `composePrompt` tests in `AgentCommandTests.testComposePrompt`, `DescriptionPromptTests` and
  `TicketSourcesTests` detect a wrong prompt. `ReviewTicketFieldTests` (about lines 126-130) assert
  `m.composedPrompt`: change them to `AgentCommand.composePrompt(userText:ticket:appendTicket:request:appendRequest:)`
  over the same draft values, so the review prompt rule keeps a test.
- `AgentCommandTests`: delete `testPreviewCommandMatchesBuildWithoutTouchingDisk` and the `previewCommand`
  lines in `testACommandTooLongForTheTerminalLineGoesToFile` and `testAPromptWithControlCharactersGoesToFile`
  (their `build` assertions on the line above detect the same failure). Convert the two `previewCommand` lines
  in `testPiCommandUsesQualifiedModelAndThinking` (no prompt) and `testAWordZshWouldExpandIsQuoted` (codex
  `x y` quoting) into `build` calls with `prompt: nil` and the same expected strings, so those quoting and PI
  cases keep a test.
- `NewReviewSheetTests.anAgentIsSelectableOnlyWhenItsCLIIsInstalled`: delete the three `AgentSegmented.isSelectable`
  lines (behaviour deleted: `AgentStep` offers only installed agents), keep the `missingAgentNote` lines.
- `TaskRowCaptionTests` lines about 53-54 (queued mark): behaviour deleted. `BackgroundCardTests.hoveringTheMarkOpensTheExistingCard`: drop its `queued` argument and expect the card to open
  (`changed > 1000`) for every status.
- `TaskCreatorTests`: delete the tests that assert the type and name halves (`testTheBranchTypeFollowsTheTicketUntilPicked`
  about lines 89-100 loses its `setBranchType` part and keeps the "follows the ticket" part rewritten to read
  `branch`; the test around lines 105-125 about `setBranch("my-own-name")` giving `feat/my-own-name`, and
  `setBranch("release/x")`, are deleted: behaviour deleted). Every other `d.setBranch(...)` call on a `TaskDraft`
  (about lines 54, 80, 142, 221-339) becomes `setFullBranch`, with the expected strings unchanged: they all pass full
  branches. `NewTaskSheetKeyboardTests.typingATypePrefixIntoTheBranchFieldPicksTheTypeAsYouType` (about lines
  110-135): behaviour deleted. `BranchTypeTests`: delete the `split` test (about lines 38-43).
- `TaskCreationModelTests` (about lines 214-224) and `ReviewInTaskTests` call `setBranch` on a draft: check which
  draft each builds; a `TaskDraft` one becomes `setFullBranch`.

Add (name the behaviour):
- `theDockBadgeCountsWhatFocusViewStepsThrough`-style projection tests, in `SidebarProjectionTests`, ported from
  `DockBadgeTests` and `SidebarModelTests`: nothing waiting gives an empty list; a task row counts once however many
  of its tabs wait; a done row counts like a needs-input row; a terminal that waits counts and is listed before
  its project's tasks; a task in `skipping` is passed over; operator rows come first.
- A `TaskCreatorTests` case: a fresh draft's `branch` is `feat/`; a ticket re-derives it; clearing the ticket keeps
  the prefix; an edited branch is never re-derived.

Fixtures: none are re-recorded. The Archive snapshot (`ArchiveSnapshots`) renders the same pixels.

## Proof

While iterating: `scripts/test.sh swift -- --filter ArchiveSheetModelTests`, then `ArchiveSearchTests`,
`SidebarProjectionTests`, `SidebarModelTests`, `TaskCreatorTests`, `TaskCreationModelTests`, `AgentCommandTests`,
`CreationSheetStepsTests`, `NewReviewSheetTests`, `NewTaskSheetKeyboardTests`, `BackgroundCardTests`,
`TaskRowCaptionTests`, `ViewWorkBudgetTests`, `WorkBudgetTests`, `SignalSidebarTests`, `AppControllerTests`.
Then plain `scripts/test.sh` in the background. For the view deletions, `scripts/snapshots.sh build/refactor-1f`
and compare the Archive sheet, New Task, New Review, New Signal and the add-divider and new-terminal sheets with
`build/refactor-before`: equal pixels (no subtitle was ever drawn on the two creation sheets). If
`build/refactor-before` does not exist, say so in the report.

## Done when

- `grep -rniE "shelf|shelve|shelv" app docs/*.md README.md AGENTS.md scripts daemon hooks compat` returns nothing.
- `grep -rnE "ShelfRow|shelfRows|removeFromShelf|DockBadge|firstNeedingAttention|SidebarModel\.needingAttention|AgentSegmented|CommandBlock|ProjectResultRow|PickedItemField|LaneChip|previewCommand|showsCommand|CreationSteps\.broadcast|openNote|onDismiss|missingModelLabel|setBranchType|BranchType\.split|ProjectSection\(.*operatorTasks|\.operatorTasks|var operatorWorktrees|SearchPicker\b" app/Sources app/Tests docs/*.md README.md`
  returns nothing (`operatorWorktrees` stays only as `ProjectActions.removalDetail`'s parameter).
- `grep -rnE "choose\(task: [^)]*tab:" app` returns nothing.
- Plain `scripts/test.sh` is green; the report lists each deleted test with its survivor.
- `README.md` and `docs/configuration.md` no longer say the sheet previews the command.

## Not in this step

- Find a Fix wiring in `AppController` (`fixPipeline`, `makeFix`, `FixClone.sweep`, `notices.fixSession`) and
  `SheetCoordinator`'s `fixPipeline`: 1i.
- Renaming `operated:` and the other vocabulary, and the remaining comment narration: 1j.
- Old-format readers: 1h. Daemon facts and wire: 1g.
- `OperatorLine` leftovers, `WorkerTabs`, `ActivityLog`: 1d. Window, remove, take-over and the Operator row id
  (`AppController.choose`'s later shape, `RowMenuAnchor`, `openRowMenu`, `bringAiTermForward`): phases 3, 4, 8.
- The sidebar's "is this task under the Operator" rule and `OperatorBadge` merge: 8a and 8b.
