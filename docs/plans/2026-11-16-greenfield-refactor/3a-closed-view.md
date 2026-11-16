# 3a. Closed view

Implementer: Opus 5.5, high. Depends on: all of phases 1 and 2. Audit findings: WD F1 (WD F3 and WD F6
become moot), TL F5 (moot).

## Why

Closing a task's iTerm2 window today asks a destructive question a second later: AiTerm brings
itself forward with Remove, Archive and Cancel, and Cancel reopens the window. A terminal's close
deletes its row. When iTerm2 relaunches, every row's window is reopened and every conversation
resumed, unasked. All of this exists because rows and windows were "locked together": a row without
a window was treated as a debt to repay eagerly, and an eager restore would reopen what the person
just closed, so the close had to be asked about, which needed a one-second heuristic to tell a
person's close from iTerm2 quitting. The maintainer decided the closed view: a row's window is a view
of the row. Closing it asks nothing and removes nothing; the row stays and draws as a row without a
window already draws; choosing the row opens its window with its conversations resumed; nothing
reopens by itself, not even after iTerm2 restarts. A right change in this step deletes the question,
the hold, the restore machinery and their triggers, keeps adoption by tag, and makes "choose" the
only way a closed manual task or terminal gets a window again.

## Today

All in `app/Sources/` unless stated. The window owner is still named `WindowReconciler`
(`AiTerm/WindowReconciler.swift`); step 3b renames it.

**`WindowReconciler`.** Built in `AppController.init` (about line 163) after `RowFocus`,
`TaskLauncher`, `TaskArchiver` and `TerminalActions`. Every piece of state, and what happens to it here:

| State | What it is | Here |
| --- | --- | --- |
| `workspace`, `live`, `daemon`, `notices` | rows, tabs, the helper, the banner | stay |
| `work` | `.reopening` token while a window opens; also `isBusy` for the triage | stays for the token; `isBusy` goes |
| `checkouts` | `missingCheckouts` in `planInputs`, `refresh()` after a gone worktree, `onAttach` refresh | stays for `isMissing`, `refresh()` and the attach refresh |
| `focus` | `setRestoreOwedRow` slot, `onWindowGone`, `windowActivated` forwarding, `select` after Cancel | stays for the first three (3b removes them); the Cancel use goes |
| `remover` | `confirmRemove(task:archiveInstead:)` in `ask`, `awaitsRetry` in `planInputs` | goes |
| `archiver` | the Archive answer | goes |
| `launcher`, `terminals` | `TaskLauncher.openWindow`, `TerminalActions.openWindow` | stay |
| `now`, `closeHold` | the triage clock and hold | go |
| `bringForward` | brings AiTerm forward for the question | goes |
| `launchIterm` | starts iTerm2 when a row is chosen while iTerm2 is away | stays |
| `triage` (`ClosedWindowTriage`) | held closes, last close, `isSynced` | goes; only "iTerm2 is synced" survives, as a plain Bool `itermSynced` |
| `settling`, `asking`, `questioned` | the hold's look, the question chain, rows asked about | go |
| `lastRestore` | the serial restore chain tests await | goes |
| `restoring: [UUID: Task]` | each row's restore in flight, joined by a second choose | stays, renamed `opening` |
| `failed`, `failedRows` | rows whose restore failed, the "Couldn't reopen" caption | go |
| `worktreeGone` | rows a restore found without a worktree, held until the monitor reads them | goes |
| `epoch` | lets armed tasks see a `stop()` | goes (nothing is armed any more) |
| `passing`, `passAgain` | pass re-entrancy | go: a pass only adopts, and no adoption starts another pass |
| `passedSessions` | the tabs as the last pass read them | stays: it keeps session events that move nothing a row reads from passing |
| `passedOwed`, `passScheduled` | the workspace-change trigger | go |

Every trigger, and what happens to it here:

| Trigger | Today | Here |
| --- | --- | --- |
| `helper.onEvent` `.snapshot` | `triage.itermSynced`, `AppState.reconciled(with:)` plus `rememberingConversations`, then `pass()` | stays, with `itermSynced = snapshot.connected` |
| `.itermConnected`, `.itermDisconnected`, `.itermAuthFailed` | `triage.itermSynced(false)` | stays as `itermSynced = false` |
| `.windowActivated` | forwarded to `focus.windowActivated` | stays (3b moves it to `RowFocus`) |
| `.windowClosed` | `windowClosedInIterm`: triage, clear, arm a hold look | becomes: clear the row's window, then `pass()` |
| `.sessionOpened`, `.sessionChanged` | remember that task's conversations; `pass()` when `live.rowSessions` moved | stays |
| `helper.onAttach` | `checkouts.refresh()` (the checkout cleanup's retry) | stays |
| `focus.onWindowGone` | `handleWindowClosed` | stays |
| `focus.setRestoreOwedRow` | `choose(_:)`, which passes and joins a restore | stays as the way a choose reaches the opener; 3b removes the slot |
| `work.onChange` | `pass()` | goes |
| `checkouts.onMissingChanged` | `pass()` and `worktreeGone` trim | goes |
| `workspace.onChangeable` | `pass()` | goes |
| `workspace.onChange` | `workspaceChanged()` and its deferred pass | goes |
| `checkouts.onPolled` | `wouldAct()` then `pass()` | goes |
| the hold's `settling` task | `pass()` a hold after a close | goes |

Methods: `handle`, `handleWindowClosed`, `windowClosedInIterm`, `isBusy`, `pass`, `planInputs`,
`wouldAct`, `owed`, `workspaceChanged`, `act`, `ask`, `restore`, `open`, `fail`, `choose`, `hasFailed`,
`stop`.

**`AiTermCore/Daemon/AppState+WindowPlan.swift`.** `WindowRow` (`.task`, `.terminal`), `WindowStep`
(`adopt`, `restore`, `ask`, `drop`) and `AppState.windowPlan(sessions:settled:due:waiting:lettingGo:)`.
The adoption rule ("a row takes a window its tag is in when it has none, or when its own is not among
them") is the only part that survives. Signal tasks are planned `adoptOnly` (about line 69), the first of
the five copies of "a signal task is not restored here"; two more are in the reconciler (`owed`, and the
guards in `restore` and `choose`), one in `RowFocus.owedRestore`.

**`AiTermCore/Daemon/ClosedWindowTriage.swift`.** The one-second rule, 80 lines. Only callers: the
reconciler and `AppPorts.swift` (`ClosedWindowTriage.hold` in `AppTimings.live`).

**`AiTermCore/Daemon/AppState+Snapshot.swift`** `reconciled(with:)` and `AppState.closeWindow(_:)` in
`AiTermCore/Models.swift` (about line 556) clear a row's window when a connected snapshot lacks it or a
window is reported gone. Both stay; their comments talk about "owed" and `windowPlan` deciding.

**The question.** `TaskRemover.confirmRemove(task:archiveInstead:)` (about line 168) with the
`ArchiveInstead` typealias and the four-way detail switch; `AlertPrompt.removeTask(_:detail:offersArchive:)`
in `AiTerm/Prompter.swift`. `grep -rn "archiveInstead\|offersArchive" app/` finds only these, the
reconciler's `ask`, and `ClosedTaskWindowTests`.

**Bringing AiTerm forward.** `AppPorts.bringForward`, `AppController.bringAiTermForward()` (bottom of
`AppController.swift`), passed in `AppController.live`. `grep -rn "bringForward\|bringAiTermForward" app/`
finds those, the reconciler, `ScratchController.swift`, `RaceFixture.swift` and two test files.

**Timings.** `AppTimings.closedWindowHold` and `AppTimings.now` are read only to build the reconciler
(`AppController.init` about line 115): `grep -rn "closedWindowHold\|timings.now" app/`.

**The "let go" flag.** `TaskOperation.removing(windowLetGo:)`, `.archiving(windowLetGo:)` and
`TaskOperation.letsWindowGo` in `AiTermCore/Tasks/WorkInFlight.swift`; `WorkInFlight.update(_:to:)`;
the `operation:` closure of `WorktreeTeardown.closeWindow(of:holding:requiringDaemon:operation:)`. The
only reader of `letsWindowGo` is the reconciler's `planInputs`
(`grep -rn "letsWindowGo\|windowLetGo\|\.update(" app/Sources`); the only caller of `update` is
`WorktreeTeardown.closeWindow`.

**Hooks only the reconciler hears.** `CheckoutMonitor.onMissingChanged` with `missingHooks`,
`CheckoutMonitor.onPolled` with `polledHooks`, `WorkspaceStore.onChangeable` with `changeableHooks` and
`heardChangeability`. Re-run `grep -rn "onPolled\|onMissingChanged\|onChangeable" app/Sources app/Tests`:
the product callers are the reconciler only.

**The caption.** `SidebarRows.swift` `TaskRowView.body` reads `controller.windows.hasFailed(row.id)` and
passes `failed` to `TaskRowCaption(removal:missing:failed:)` ("Couldn't reopen") and
`TaskRowAccessibility(title:task:missing:failed:...)` ("Press Return to try again.").

**Who chooses.** `RowFocus.select` (about line 203) restores a windowless row through `owedRestore`,
which sends a signal task to the `setReopenWorkerWindow` slot and anything else to the reconciler's
`choose`. `TaskArchiver.restore` ends with `focus.select(.task(id))`. The arrow keys use `RowFocus.peek`,
which never opens anything (`guard let row, window(for: row) != nil else { browse(row) ... }`).

**Tests.** `ClosedTaskWindowTests.swift`, `RestoringRowTests.swift`, `WindowReconcilerTriggerTests.swift`,
`ResumingConversationsTests.swift`, `ManualInstant.swift` (test clock, only for the triage) in
`app/Tests/AiTermTests/`; `ClosedWindowTriageTests.swift`, `WindowPlanTests.swift`,
`WindowReconciliationTests.swift`, `WorkInFlightTests.swift` in `app/Tests/AiTermCoreTests/`; window
cases in `ArchiveTests`, `OperationIssueTests`, `CheckoutCleanupTests`, `ControllerRaceTests`,
`AppControllerTests` (`ControllerWindowsTests`), `WorkBudgetTests`, `RowAccessibilityTests`,
`TaskRowCaptionTests`. `grep -rn "windows\.\(lastRestore\|settling\|asking\|triage\|restore\|hasFailed\|pass\)" app/Tests`
lists every test that touches removed API.

## Change

1. **Delete `ClosedWindowTriage`** and its file. In `AppPorts.swift` delete `AppPorts.bringForward`,
   `AppTimings.closedWindowHold` and `AppTimings.now`, and their doc sentences. Delete
   `AppController.bringAiTermForward()` and the `bringForward:` argument in `AppController.live`.
2. **Reduce the window plan to adoption.** In `AppState+WindowPlan.swift`, delete `WindowStep` and
   replace it with a small value `WindowAdoption` (the `WindowRow` and the `windowId` it takes). The plan
   becomes `windowPlan(sessions:)` returning the adoptions, by the existing rule, for every task (any
   ownership, with or without a checkout: a tab tagged with a task's id means it has a window) and every
   terminal. The `settled`, `due`, `waiting` and `lettingGo` inputs, `adoptOnly` and the `hasCheckout`
   filter go. Rewrite the doc comment to say only the adoption rule.
3. **Rewrite `WindowReconciler` to three jobs:** clear a row's window when iTerm2 says it is gone, adopt
   tagged windows, and open a chosen row's window. Its state is exactly what the table above says stays:
   `opening`, `passedSessions`, `itermSynced`, the one pending open described below, and the dependencies `workspace`, `work`, `live`,
   `checkouts`, `focus`, `launcher`, `terminals`, `notices`, `daemon`, `launchIterm`. Its init drops
   `remover`, `archiver`, `now`, `closeHold` and `bringForward`, and every hook in the "goes" rows of the
   trigger table.
   - `handle(_:)`: on a snapshot, set `itermSynced`, apply `reconciled(with:)` and
     `rememberingConversations(from:)` as today, then `pass()`, then open the pending row if there is
     one (below). On the three connection events set
     `itermSynced = false`. On `.windowClosed` call `handleWindowClosed`. Session events as today.
   - `handleWindowClosed(_ windowId: String?)`: clear the row's window through `AppState.closeWindow`, then
     `pass()` (a second window tagged with the row is taken at once).
   - `pass()`: note `WorkMeter.Work.reconcilerPass`, record `passedSessions`, apply each adoption with one
     `workspace.mutate` per adoption as `act(.adopt)` does today. No re-entrancy flags.
   - `open(_ row: WindowRow) -> Task<Void, Never>?` replaces `restore` and `choose`; it is what a choose
     calls. In order: an open already running for the row is returned; a row that has a window, or is
     gone, returns nil; no daemon reports `OperationIssue.disconnected("again")` and returns nil; not
     `itermSynced` calls `launchIterm()`, remembers the row as the one pending open (see below) and
     returns nil, reporting nothing; a task with a `signalTask` returns nil (it still goes through `RowFocus`'s
     worker slot until 3b); a task the checkout monitor reads missing (`checkouts.isMissing`) returns nil
     and reports nothing (its row says Worktree missing); `work.begin(.reopening, ...)` refused returns nil.
     Otherwise start and store the open: a task's is today's `open` body (the `FolderCheck`, then
     `launcher.openWindow` with the first `resumeCommands` entry and one `createTab` per other); a
     terminal's is `terminals.openWindow(for:in:adding: false, with:)`. A worktree `FolderCheck` finds gone
     calls `checkouts.refresh()` and reports nothing. Success calls `notices.dropIssues(about:)`. A failure
     is reported at once with today's titles ("Couldn’t reopen the window." with the task as subject,
     "Couldn’t reopen “name”." with the terminal as subject, "Reopened the window, but not every
     conversation.") and nothing else is recorded. No `iterm_unavailable` exemption: the person clicked,
     and nothing will retry.
   - The pending open: one optional `WindowRow`, set when a row is chosen while iTerm2 is not synced
     and replaced by the next such choose. When a connected snapshot arrives, take it out and, if that
     row is still the selection, still exists and still has no window after the adoptions, call `open`
     for it. It is dropped without opening when the selection moved to another row. This is the one
     thing remembered: a person who quit iTerm2 and clicks a row gets iTerm2 started and that row's
     window, with one click.
   - The `setRestoreOwedRow` closure maps the `RowSelection` to a `WindowRow` (task or terminal, nil for
     anything else) and calls `open`.
   - `stop()` sets `itermSynced = false` and nothing else.
   - Rewrite the type's doc comment for the closed view in three or four sentences.
4. **`TaskRemover` and `Prompter`.** Delete `confirmRemove`'s `archiveInstead` parameter, the
   `ArchiveInstead` typealias and the two Archive branches of the detail switch (keep the two wordings
   the menu uses). Delete `offersArchive` from `AlertPrompt.removeTask`. Fix the comment in
   `removeWorktree` that says a kept task's window "is owed and comes back": it stays without a window.
5. **The "let go" flag.** Make `TaskOperation.removing` and `.archiving` payload-free, delete
   `letsWindowGo` and `WorkInFlight.update(_:to:)`, and delete the `operation:` parameter of
   `WorktreeTeardown.closeWindow` and both `work.update` calls in it. Update the call sites in
   `TaskRemover`, `TaskArchiver` and the tests. The comment on `closeWindow` keeps "the row drops it
   first" and loses the window-plan clause.
6. **Hooks.** Delete `CheckoutMonitor.onMissingChanged`, `missingHooks` and the hook call in the
   `missingCheckouts` `didSet` (keep the `missingRows` mirror; 3c replaces it), `CheckoutMonitor.onPolled`,
   `polledHooks` and its call in `startMonitoring`, and `WorkspaceStore.onChangeable`, `changeableHooks`
   and `heardChangeability` with the two `didSet`s on `loaded` and `persistenceError` that only call it,
   once the grep above shows no other reader.
7. **The caption.** Delete `hasFailed`, the `failed` parameter of `TaskRowCaption(removal:missing:)` and
   its "Couldn't reopen" note, and the `failed` parameter of `TaskRowAccessibility`. A task row with no
   window (`task.windowId == nil`, not missing, not removing) gets the hint "Press Return to open its
   window."; one with a window keeps "Press Return to focus the window.".
8. **`TaskArchiver.restore`.** It still ends by choosing the row, but awaits it: after the toast,
   `await focus.select(.task(id))?.value`, so the restore's task ends once the window has opened and been
   raised. Rewrite its doc comment and the type's ("the window lock reopens it") for the closed view.
9. **`AppController`.** Build the reconciler with the new init; drop `bringForward`, `closedWindowHold`
   and `now` from the locals; update the doc comment of `windows`.
10. **Comments that describe the old lock**: `TaskLauncher.create` ("nothing restores it underneath"),
    `TaskLauncher.openWindow` ("`WindowReconciler.restore` opens..."), `TerminalActions.close`,
    `AppState.closeWindow`, `reconciled(with:)`, `WorkInFlight` docs, `ScratchController`'s doc about
    `ManualInstant` and `windows.settling`. Say what the code does now.

## Keep

- **Adoption by tag**, including for driven tasks: a window iTerm2 restored, a relaunched AiTerm's
  windows, a dragged tab. It is the only thing that stops a duplicate window.
- **`reconciled(with:)` ignoring a disconnected snapshot**: iTerm2 out of reach lists no windows, and
  clearing every row then would lose live windows.
- **`rememberingConversations` and its "every agent tab named" rule**: what a later open resumes.
- **`passedSessions` and `WorkMeter.Work.reconcilerPass`**: a pass still runs on session events, so the
  budget `sessionEventsThatChangeNoRowEachPassTheWindowLock` (0 passes for ten events that move only a
  context fill and a title) still guards a live mechanism.
- **`opening` and the join**: two clicks during one open must give one window, raised once.
- **`TaskLauncher.openWindow` closing a window whose row went** and `TerminalActions.openWindow` doing
  the same: a row removed while its window opened must not leave an orphan.
- **`AppController.start()` starting iTerm2** when it is not running: out of scope by decision.
- **`SignalSidebar`'s `OperatorLine.windowClosed`** for a driven task without a window: that is how a
  row without a window draws today, and the design says no new visual.
- **`TerminalActions.close`'s `.reopening` refusal** ("still reopening its window"): opens still hold
  `.reopening`.
- **`LiveSessions`** dropping a closed window's tabs: tab bookkeeping, not row state.
- **`helper.onAttach { checkouts.refresh() }`**: the checkout cleanup waits on a daemon to close a window.

## Decisions already taken

- A `window.closed`, or a connected snapshot that lacks a row's window, clears that row's window and
  nothing else. The row stays, its saved conversations stay, its selection stays.
- A terminal's closed window keeps its row; choosing it opens a fresh shell in its project folder.
- Nothing opens by itself: not after a close, not on a snapshot, not after iTerm2 or AiTerm restarts,
  not for worktrees imported with a new project, not after a workspace backup is restored, not for a task
  kept late during Remove or Archive. Each such row opens when chosen.
- The arrow keys (`peek`) never open a window; they only raise one that exists. Focus View and the
  attention counts use `peek` too, so they open nothing.
- A removal's own close can be adopted back for a moment if a snapshot or session event lists the
  closing tab before `window.closed` arrives. That is harmless: `window.closed` clears it again,
  `AppState.moveToArchive` sets `windowId = nil`, and Remove drops the row. Do not add a guard for it.
- Opens are no longer serialised one after another; each choose opens its own window.
- A chosen row whose worktree the monitor reads missing opens nothing and reports nothing: the row says
  Worktree missing. One `FolderCheck` finds gone first refreshes the monitor and reports nothing.
- A chosen row while iTerm2 is not synced (no connected snapshot since the last disconnect, which
  includes the first moments after launch, and every click after the person quit iTerm2): start
  iTerm2 with `launchIterm` and remember that one row; it opens when iTerm2 connects, if it is still
  selected. After a quit, every row is without a window, so this is the ordinary first click, and
  it must not need a second one. If iTerm2 never connects, the banner (3d) says why; nothing else
  is reported for the row.
- A failed open is reported on the click through `notices.report`, as a failed create is. No per-row
  failure state and no caption.
- A row busy with other work (being created, removed, archived, restored) opens nothing on choose.
- A driven or taken-over task keeps going through the `RowFocus` worker slot in this step; 3b moves it.
- Quitting while an open runs lets it finish or fail; nothing is cancelled.

## Tests

Delete, with the reason:

- `ClosedWindowTriageTests.swift`, every case: the type is deleted.
- `ManualInstant.swift`: only the triage used it.
- `WindowReconcilerTriggerTests.swift`, every case (`anOwedRowWhoseCheckoutComesBackIsRestoredAtThatRead`,
  `anOwedRowWaitingOnTheWorkspaceLockIsRestoredOnceItLifts`, `anOwedRowNoTriggerCoversIsRestoredWithinOnePoll`,
  `aRowHeldBackStartsNoPassAtAPoll`, `importedWorktreesGetTheirWindowsAtTheImport`): the triggers and
  the restore they started are deleted.
- `ClosedTaskWindowTests.swift`: `closingATasksWindowAsksRemovesQuestionAndCancelReopensAndRaisesIt`,
  `aReviewsThreeButtonQuestionSaysOnlyRemoveDeletesItsBranch`, `answeringArchiveAfterAClosedWindowArchivesTheTask`,
  `answeringRemoveAfterAClosedWindowRemovesTheTask`, `itermGoingAwayAsksNothingAndRestoresOnceConnected`,
  `aLoneCloseIsAskedAboutEvenWhenITerm2GoesAwayAfterItsHold`, `quittingWhileACloseIsHeldAsksAndRestoresNothing`,
  `twoClosesSecondsApartAreAskedOneAfterTheOther`, `aLoneCloseIsAskedAboutWhileAnotherTaskIsCreated`,
  `aRowAskedAboutIsNotRestoredWhileTheAlertIsUp`: the question, hold and restore are deleted.
  `theCloseARemovalMakesAsksNothingMore`: no question exists; a removal finishing after its own
  `window.closed` stays covered by `CheckoutCleanupControllerTests.removingATaskClosesItsWindowBeforeDeletingItsWorktree`.
  `theCloseTheCheckoutCleanupMakesAsksNothing`: covered by
  `CheckoutCleanupControllerTests.aCleanupWhoseWindowsCloseArrivesFirstStillForgetsTheTask`.
  `aTerminalsWindowClosedAloneTakesItsRow`: the behaviour is reversed (new case below).
- `RestoringRowTests.swift`: `anOwedRowIsRestoredOnceITerm2IsThereWithoutBeingChosen`,
  `aWorktreeFoundGoneIsLookedForOnceUntilTheMonitorReadsIt`, `aQueuedRestoreWaitsOutWindowsClosingMeanwhile`,
  `aRestoreThatFailsAsItermGoesAwayIsNotMarkedFailed`, `aFailedRowThatAdoptsAWindowNoLongerSaysItFailed`,
  `aRestoreRefusedForITerm2BeingUnavailableIsNotMarkedFailedWhileSynced`: eager restore, the gone-worktree
  hold and the failed state are deleted.
- `WindowPlanTests`: `aTaskWithNoWorktreeYetIsNeitherRestoredNorAskedAbout`, `anOwedRowIsRestoredOnlyOnceSettledAndNotWaiting`,
  `aDueCloseAsksAboutATaskAndDropsATerminal`, `aDueTaskWhoseTabLivesOnIsAdoptedNotAsked` (its case is the
  `lost` row of `aRowTakesTheWindowItsTagIsIn`), `aRowInWaitingStillAdoptsTheWindowItsTagIsIn`,
  `aTaskLettingItsWindowGoIsLeftToItsRemoval`: the inputs they test are deleted (for the first, the
  `hasCheckout` filter: a task with no worktree has no tagged tab to adopt).
- `WorkInFlightTests.onlyARemovalOrAnArchiveThatHasLetItsWindowGoKeepsTheWindowPlanAway`: the flag is deleted.
- `OperationIssueControllerTests.aRowAwaitingARemovalsRetryIsNotRestored`: nothing restores by itself;
  `awaitsRetry` itself is covered by the remover's own tests until 4b.
- `WorkBudgetTests.pollsWithNothingOwedPassTheWindowLockNever`: the poll trigger is deleted.
- `RowAccessibilityTests.aLockedWorkspacesFailedRowSaysNothingAboutTryingAgain`: keep only its second
  expectation (a row with a window says "Press Return to focus the window.") and rename it.

Rewrite, keeping the subject (await what `select`, `choose` or `windows.open` returns instead of
`windows.lastRestore`; deliver a connected snapshot first, as every open needs `itermSynced`):

- `ClosedTaskWindowTests.aTaskWhoseTabLivesOnInAnotherWindowIsNotAskedAboutAndTakesThatWindow`: without
  the clock; the row takes "other", nothing opens, nothing is asked.
- `ClosedTaskWindowTests.aReconnectRestoresEachRowOnceAndNeverOneBeingRemoved`: becomes "across a
  reconnect each row takes its own tagged window and nothing is opened": Early takes "e-restored", Work
  and the terminal take their late windows, `window.createTask` and `window.createTerminal` are never
  sent. Drop the Leaving row and its removal.
- Move both into a new file `app/Tests/AiTermTests/ClosedViewTests.swift`, suite `ClosedViewControllerTests`,
  and delete `ClosedTaskWindowTests.swift`.
- Rename `RestoringRowTests.swift` to `OpeningRowTests.swift`, suite `OpeningRowControllerTests`, and
  rewrite its survivors: `choosingARowWhileItsRestoreRunsRaisesWhatItOpensOnce` (two `select`s while
  `window.createTask` is held: one window, one raise), `aRestoreTheSelectionLeftOpensTheWindowWithoutRaisingIt`
  (select, then `browse(nil)`), `aTaskBeingCreatedIsOpenedOnceAndNotRestored` (a snapshot and a `select`
  during the create open no second window), `aTaskWhoseWorktreeWentUnreadIsNotRestored` (select: no
  `window.createTask`, no issue), `choosingARowWhoseRestoreFailedTriesAgainAndRaisesIt` (first select
  reports "Couldn’t reopen the window." with the task as subject; second select opens and raises),
  `aTerminalWhoseRestoreFailedShowsTheBannerWithItsName` (select reports "Couldn’t reopen “Shell”." with the
  terminal as subject), `choosingAnOwedRowWhileITerm2IsAwayStartsIt` (iTerm2 started once, no
  `window.createTask`, the issue is the not-connected sentence). Keep unchanged:
  `choosingATaskWhoseTabLivesOnElsewhereRaisesThatWindow`, `choosingATaskBeingRemovedRestoresNothing`,
  `aTaskWhoseCheckoutIsMissingIsNotRestored`, `startingWhileITerm2IsNotRunningStartsItOnce`,
  `startingWhileITerm2IsRunningLeavesItBe`, `choosingAnOwedRowWithNoHelperSaysSo`. Rename "Restore" and
  "Owed" in test names to "Open" and "WithoutAWindow".
- `ResumingConversationsControllerTests` (all four reopen cases): snapshot, then
  `await controller.focus.select(.task(id))?.value` instead of the eager restore. Same expectations.
- `WindowPlanTests.anOperatorsStartedTaskTakesItsTaggedWindowButIsNeverRestoredHere`: a driven task takes
  its tagged window and a driven task without one gets no step. `aRowWithItsWindowNeedsNothing`,
  `aRowTakesTheWindowItsTagIsIn`: new signature only.
- `WindowReconciliationTests.aRowWhoseWindowIsGoneIsOwedIt`: rename to "...is cleared"; same body.
- `ArchiveControllerTests.restoringBringsTheWorktreeAndRowBackAndItsWindowWithItsConversations` and
  `WorkBudgetTests.shelvingAndRestoringATaskSpawnsGit`: drop the `lastRestore` awaits; awaiting the
  restore now awaits the window. The git spawn counts must not move.
- `WorkBudgetTests.sessionEventsThatChangeNoRowEachPassTheWindowLock`: drop its `lastRestore` await; the
  budget (0 passes) stays.
- `OperationIssueControllerTests.restoringATaskTakesDownTheBannerAboutIt` and
  `restoringATaskDropsAReportAboutItHeldBehindTheBanner`: snapshot, then select the row; rename
  "restoring" to "opening".
- `OperationIssueControllerTests.theIssueStaysWhenItsRowsWindowCloses`: unchanged.
- `CheckoutCleanupControllerTests.aSnapshotDuringTheCloseDoesNotReattachTheWindow`: becomes "a snapshot
  during the close does not stop the removal": drop the intermediate `windowId == nil` expectation, keep
  that the removal ends with the row gone and no issue.
- `CheckoutCleanupControllerTests.keepingATaskWhoseWindowAlreadyClosedBringsItsWindowBack`: becomes
  "...leaves it without a window": the task stays, no note, no issue, `window.createTask` never sent,
  `windowId == nil`.
- `AppControllerRaceTests` `aProjectCannotBeRemovedWhileATaskWindowOpensInIt`,
  `aSuccessfulTerminalReopenClearsItsFailureBanner`, `removingATerminalWhileItReopensSaysWhy`,
  `aWindowReopenedForATerminalThatWentMeanwhileIsClosed`: `windows.restore(...)` and `windows.choose(...)`
  become `windows.open(...)`.
- `ControllerWindowsTests.observedClosesLeaveRowsOwedAndPreserveCheckouts`: rename "Owed" to
  "WithoutAWindow"; same body.
- `WorkInFlightTests.aTokenEndsOnlyItsOwnWork` and `eachChangeIsHeardForItsSubject`: drop the `update`
  lines and the heard values they produced; keep the subjects.
- `TaskRowCaptionTests` and `RowAccessibilityTests`: drop the `failed` argument and the "Couldn’t
  reopen" expectations; `aTaskRowsHintSaysWhatChoosingItDoes` expects "Press Return to open its window."
  for a row without a window.
- `RaceFixture` and `ScratchController`: drop `bringForward`, `closedWindowHold` and `now`.

Add to `ClosedViewControllerTests` (each starts with a connected snapshot, as the app's bootstrap does):

- Closing a task's window clears its window, asks nothing, opens nothing and brings nothing forward;
  the row and its selection stay, and its saved conversations are unchanged.
- Closing a terminal's window keeps its row without a window; choosing it opens one fresh shell
  (`window.createTerminal` once) and raises it.
- Choosing a closed task opens its window once with its conversations resumed and raises it; choosing it
  again while the open is held sends one `window.createTask`.
- A connected snapshot that lacks every window (iTerm2 restarted) leaves every row without a window and
  sends no `window.createTask` or `window.createTerminal`; a later snapshot listing a tagged window gives
  that row its window.
- Peeking (`focus.peek`) at a row without a window selects it and sends nothing to the daemon.
- Worktrees imported with a new project come in without windows and open nothing until chosen.
- A failed open is reported on the click with the row as subject, and the row has no other mark of it.

## Proof

While iterating:
`scripts/test.sh swift -- --filter "ClosedViewControllerTests|OpeningRowControllerTests|WindowPlanTests|WindowReconciliationTests|ResumingConversationsControllerTests|ArchiveControllerTests|OperationIssueControllerTests|CheckoutCleanupControllerTests|AppControllerRaceTests|ControllerWindowsTests|WorkBudgetTests|WorkInFlightTests|RowAccessibilityTests|TaskRowCaptionTests|ItermFocusControllerTests"`.
Then plain `scripts/test.sh`, started in the background.

Snapshots: `scripts/snapshots.sh build/refactor-3a` and compare every PNG with `build/refactor-before`.
No snapshot draws the "Couldn't reopen" caption or a window question, so every image must be equal.

## Done when

- `grep -rn "ClosedWindowTriage\|closedWindowHold\|bringForward\|bringAiTermForward\|archiveInstead\|offersArchive\|letsWindowGo\|windowLetGo\|hasFailed\|lastRestore\|worktreeGone\|onPolled\|onMissingChanged\|onChangeable\|ManualInstant" app/`
  returns nothing.
- `grep -rn "WindowStep\|settled:\|lettingGo" app/` returns nothing.
- `AppState.windowPlan(sessions:)` returns adoptions only; `WindowReconciler` has no `pass()` trigger
  other than a snapshot, a closed window and a session event that moved `live.rowSessions`.
- Plain `scripts/test.sh` is green and its closing lines are in the report.
- Snapshots equal to `build/refactor-before`.

## Not in this step

- Renaming to `RowWindows`, one `open(row)` for driven tasks, taken-over tasks and the Operator chat,
  removing the `RowFocus` slots, the Operator's 180-second grace and its self-reopen: 3b.
- The Operator row's id and `RowFlags` (the `missingCheckouts` mirror): 3c.
- The iTerm2 banner: 3d.
- `docs/windows.md`, the alert line in `docs/keyboard.md`, `docs/status-model.md`,
  `docs/daemon-protocol.md`'s `window.closed` line and `docs/architecture.md`'s window paragraph: 3e.
- Remove asking about an unmerged branch before acting, and `awaitsRetry`: 4b. One teardown: 4c.
