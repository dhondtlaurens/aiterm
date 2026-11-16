# 3b. One window owner

Implementer: Opus 5.5, high. Depends on: 3a (and so all of phases 1 and 2). Audit findings: WD F2,
SB F7.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

1. **Construction order.** The design notes say `RowWindows` is built before `RowFocus` and passed to it
   by reference. It cannot be: its `open(row)` must call `TaskLauncher.openWindow`,
   `TaskLauncher.openTakenOverWindow`, `TerminalActions.openWindow` and `SignalOperatorController`, and
   `TaskLauncher` and `TerminalActions` are built with `focus` (`AppController.init`, about lines 134 and
   159) while `SignalOperatorController` is built after them (about line 181). Building `RowWindows` first
   would need either the three opener slots again or moving the window primitives and all `focus` uses out
   of the launcher and the terminals. This brief builds `RowWindows` after `SignalOperatorController`;
   `RowFocus` holds no reference to it and reports a window it found gone through its existing
   `onWindowGone` hook, which `RowWindows` subscribes to. The slots still go: `AppController.choose` holds
   both owners and calls `RowWindows.open(row)`, then `RowFocus.select(row, after:)`.
2. **The Operator's own window paths.** The notes say the Operator's reopen-to-type and handover-close
   paths "call `RowWindows`". Here they stay in `OperatorSessionKeeper`, which keeps writing
   `operatorSession.window` itself as part of its saved handover record (one mutate and flush with
   `handover`, which is what makes a crash mid-handover recoverable), and `RowWindows` leaves the chat's
   window alone while a handover runs. The keeper reads "has a window" as `session.window != nil`, which
   `RowWindows` keeps true. Same outcome, no call from the controller back into an owner built after it.

## Why

After 3a a closed window is a closed view, but who opens a row without a window is still decided in
three places joined by three single-slot closures on `RowFocus` (`setRestoreOwedRow`,
`setReopenOperatorWindow`, `setReopenWorkerWindow`), set from `AppController` and from the window owner
because `RowFocus` was built before its openers. "A signal task is not opened here" is still written in
several places, and the Operator chat has a policy of its own: its window is never cleared when it
closes, so the keeper counts it open while a tagged tab is live or for 180 seconds after it opened, and
reopens a closed chat by itself on the next reconcile. The end state: one owner, `RowWindows` (today
`WindowReconciler`), keeps "this row has a window" for every row kind (manual task, driven task, taken-
over task, terminal, the Operator chat), clears it when iTerm2 says it is gone, adopts tagged windows,
and has one `open(row)` that picks the opener. `AppController.choose` alone decides what choosing a row
does and then asks `RowFocus`, which keeps selection, peek and raising, to raise. The Operator chat
follows the closed view too: it does not reopen by itself, only when the person chooses its row or the
Operator has something to type into it.

## Today

State after 3a. All in `app/Sources/`.

**`AiTerm/WindowReconciler.swift`.** After 3a: state `opening`, `passedSessions`, `itermSynced`; deps
`workspace`, `work`, `live`, `checkouts`, `focus`, `launcher`, `terminals`, `notices`, `daemon`,
`launchIterm`. It clears windows (`handleWindowClosed`, snapshot), adopts tasks and terminals by tag
(`pass` over `AppState.windowPlan(sessions:)`), forwards `.windowActivated` to `focus.windowActivated`,
subscribes to `focus.onWindowGone`, and sets `focus.setRestoreOwedRow` to its `open(_:)`, which refuses
any task with a `signalTask`. Built in `AppController.init` right after `TerminalActions`.

**`AiTerm/RowFocus.swift`.** `select(_:)` (about line 203) decides: project and signal browse; a driven
task still `.launching` with no checkout browses (`takenOver == false && phase == .launching &&
!hasCheckout`); the Operator row without a window browses and calls `operatorWindowOwed`; any other row
without a window calls `owedRestore` (a removing row gets nil; a task with a `signalTask` goes to
`operatedTaskOwed`; anything else to `restoreOwed`) and activates after it; a row with a window activates,
a task with `markSeen` after. `activate`'s not-found branch fires `windowGoneHooks` and, for the Operator
row on a click, calls `operatorWindowOwed` again. `windowActivated(_:)` is called by the reconciler.

**`AiTerm/AppController.swift`.** Sets `setReopenOperatorWindow` to `signalController.openOperator()` and
`setReopenWorkerWindow` to `launcher.openTakenOverWindow(...)` for a taken-over task or
`signalController.reopenWorker(_:)` for a driven one (about lines 247 to 261). `choose(_:)` (about line
534) sends a task to `choose(task:)` (a driven task with a tab to bring calls `bringTab`, anything else
`focus.select`) and every other row to `focus.select`. `operatorPorts.notifications.onOpen` calls
`focus.select` directly. `presentArchive`'s restore closure calls `archiver.restore`.

**`AiTerm/Views/Operators/SignalRows.swift`** `SignalOperatorRow` activates with
`controller.focus.select(.operation(OperatorSession.rowID))`, bypassing `choose`.

**`AiTerm/TaskArchiver.swift`** `restore(_:)` ends with `await focus.select(.task(id))?.value` (3a); `focus`
has no other use there.

**`AiTerm/Operators/SignalOperatorController.swift`.**
- `openOperator()` (about line 790): `keeper.ensure(allowPaused: true)` when `operatorHasWork`, then
  `daemon.activate(windowId:)`, recording `OperatorIssues.Source.openWindow`.
- `reopenWorker(_:)`: `native.reopen(task)`, recording `.reopenWorker`.
- `opened: (window, generation, at)`: set in `open(_:digest:)`, cleared on `.windowClosed` and in
  `keeper.finished`; read by `statusIssue` ("did not start in its window" after 180 s with a shell tab)
  and by the keeper's `windowIsOpen` port (a live tab tagged with the session's id in its window, or
  `opened` younger than 180 s).
- `reconcile()` calls `keeper.ensure()` whenever `operatorHasWork`, and `finishSessionIfIdle` does too.
- `rememberOperator()` records the session and conversation of the tab already in the session's window.

**`AiTerm/Operators/OperatorSessionKeeper.swift`.** `Ports.windowIsOpen`; `transition(finishing:allowPaused:)`
ends with "handover nil and `windowIsOpen` means done, else open": an established chat whose window
closed is reopened by the next `ensure()`. The keeper writes `operatorSession.window` with `handover` in
one mutate at each handover step. `existingWindow` and `open` look up a tagged Claude tab through
`daemon.snapshot()` before opening.

**`AiTerm/Operators/SignalWorkerIO.swift`** `reopen(_:)` (about line 425): the guarded resume of a driven
worker (activates a live worker tab if one is listed, else `openWorkerWindow` with the worker's command,
saving `windowId`). Throws `ActionUnavailable` with a reason.

**`AiTerm/TaskLauncher.swift`** `openTakenOverWindow(_:prepareRequest:resume:)`: the taken-over opener, which
makes a checkout when there is none, joins a second click, and reports its own failure through `notices`.
4e deletes it.

**`AiTermCore/Operators/OperatorIssues.swift`** `Source.openWindow` and `.reopenWorker` have one producer
each, the two methods above, and `keeper.finished` calls `succeed(.openWindow)`.
`grep -rn "\.openWindow\b\|\.reopenWorker\b" app/Sources app/Tests | grep -v "launcher\.\|terminals\.\|func openWindow"`.

**Core.** `WindowRow` is `.task`, `.terminal`; `AppState.windowPlan(sessions:)`, `AppState.closeWindow(_:)`
and `reconciled(with:)` know tasks and terminals only. The chat's tabs carry `aiterm_task =
operatorSession.id` (`SignalOperatorController.open` passes `taskId: session.id.uuidString`), so they
read as `SessionInfo.taskUUID == operatorSession.id`.

**Greps to re-run:** `grep -rn "setRestoreOwedRow\|setReopenOperatorWindow\|setReopenWorkerWindow\|owedRestore\|focus.select(" app/Sources`,
`grep -rn "windowIsOpen\|openOperator\|reopenWorker" app/Sources app/Tests`,
`grep -rn "timeIntervalSince(.*) < 180\|>= 180" app/Sources/AiTerm/Operators/SignalOperatorController.swift`.

**Tests that reach these paths:** `OpeningRowTests`, `ClosedViewTests`, `ResumingConversationsTests`,
`ArchiveTests`, `OperationIssueTests`, `WorkBudgetTests`, `ItermFocusTests` (taken-over cases go through
`controller.choose(task:)`), `SidebarInteractionTests`, `SignalSidebarTests`, `Operators/SignalSessionKeeperTests`,
`Operators/SignalOperatorLifetimeTests`, `Operators/SignalOperatorIssueTests`,
`AiTermCoreTests/Operators/OperatorIssuesTests`, `AiTermCoreTests/WindowPlanTests`,
`AiTermCoreTests/WindowReconciliationTests`.

## Change

1. **Rename** `WindowReconciler` to `RowWindows` (`git mv` the file to `AiTerm/RowWindows.swift`); the
   `AppController.windows` property keeps its name and takes the new type. Rename `handleWindowClosed`
   to `windowGone(_:)`.
2. **Core: the Operator chat as a window row.** `WindowRow` gains `.operatorChat` (no payload). If nothing
   reads `WindowRow.id` after this step, delete it and key `RowWindows.opening` by `WindowRow`.
   - `AppState.windowPlan(sessions:)` also plans the chat when `operatorSession` exists and its
     `handover` is nil: tabs whose `taskUUID` is `operatorSession.id`, its window `operatorSession.window`,
     by the same adoption rule. Applying `.operatorChat`'s adoption sets `operatorSession.window`.
   - `AppState.closeWindow(_:)` also clears `operatorSession.window` when it matches and `handover` is
     nil; `reconciled(with:)` clears it when a connected snapshot lacks it and `handover` is nil.
3. **Build `RowWindows` after `SignalOperatorController`** in `AppController.init`, with deps `helper`,
   `workspace`, `work`, `live`, `checkouts`, `focus` (only to subscribe to `onWindowGone`), `launcher`,
   `terminals`, `signalController`, `notices`, `daemon`, `launchIterm`. Keep the event hook order live
   sessions, then `RowWindows`, then `MessagingChecks`, then the signal controller: move the
   `helper.onEvent` lines for messaging and the signal controller below the `RowWindows` construction.
   Delete the `.windowActivated` forwarding from `RowWindows`; `AppController.init` adds one
   `helper.onEvent` hook, right after the live sessions' hook, that sends `.windowActivated` to
   `focus.windowActivated`. `RowFocus`'s init is unchanged (`ReviewThreadsWatcherTests` builds one with no
   helper).
4. **`RowWindows.open(_ row: WindowRow) -> Task<Void, Never>?`** keeps 3a's checks in order (an open in
   flight is returned; a row with a window or gone returns nil; no daemon reports
   `OperationIssue.disconnected("again")`; not `itermSynced` starts iTerm2 and remembers the row as 3a's
   one pending open, for any row kind, opened when iTerm2 connects if it is still selected; a task the monitor reads missing returns nil quietly), then picks the opener by kind:
   - manual task (`signalTask == nil`): 3a's open, unchanged;
   - taken-over task (`signalTask?.takenOver == true`): `launcher.openTakenOverWindow(id, prepareRequest:
     signalController.native.prepareTakenOverRequest, resume: signalController.native.takenOverResumeCommands)`,
     which reports its own failure;
   - driven task: still `.launching` with no checkout returns nil (nothing to open yet); otherwise a task
     that awaits `signalController.reopenWorker(id)` and reports a failure as "Couldn’t reopen the
     window." with the task as subject and the error's reason;
   - terminal: 3a's open, unchanged;
   - `.operatorChat`: a task that awaits `signalController.openChat()` and reports a failure as
     "Couldn’t open the Operator’s chat." with the error's reason and no subject.
   Every other "a signal task is not opened here" guard goes: the one in `open`, the one in the slot
   adapter, `RowFocus.owedRestore`, and `RowFocus.select`'s launching guard.
5. **`RowFocus`.** Delete `restoreOwed`, `operatorWindowOwed`, `operatedTaskOwed`, `setRestoreOwedRow`,
   `setReopenOperatorWindow`, `setReopenWorkerWindow` and `owedRestore`. `select(_ row:, after opening:
   Task<Void, Never>? = nil)` selects; a project or signal heading only browses; any other row activates
   after `opening` as today (a task with a window and no `opening` gets `markSeen` after, as today). Delete
   the not-found branch's Operator re-ask; the not-found branch keeps clearing `selfRaised` and firing
   `onWindowGone`. Rewrite the type's and `select`'s doc comments: selection, peek, raising, nothing else.
6. **`AppController.choose(_:)` decides.** Headings: `focus.browse(row)`, nil. A task: `choose(task:)` keeps
   its `bringTab` branch for a driven task with a tab to bring; a task `remover.isRemoving` gets
   `focus.select(row)` (select only). Every task, terminal and the Operator row: map to a `WindowRow` and
   return `focus.select(row, after: windows.open(windowRow))`. `operatorPorts.notifications.onOpen` calls
   `self.choose(...)` for both targets. `SignalOperatorRow`'s `activate` calls
   `controller.choose(.operation(OperatorSession.rowID))`. Delete the slot wiring and its comments.
   `bringTab` keeps `focus.select(.task(id))`: the task has a window there.
7. **Restore from the Archive.** `TaskArchiver.restore` no longer chooses the row (delete the final
   select and the `focus` dependency). Add `AppController.restoreFromArchive(_ id: UUID) -> Task<Void,
   Never>?`: it awaits `archiver.restore(id)` and, if the row is back among the tasks, awaits
   `choose(.task(id))`. `presentArchive` passes it to `ArchiveSheetModel`. Update `TaskArchiver`'s doc
   comment.
8. **`SignalOperatorController`.**
   - `openOperator()` becomes `openChat() async throws`: with no work it returns (nothing to open, as
     today); otherwise `keeper.ensure(allowPaused: true, reopen: true)`, and if the session still has no
     window it throws `ActionUnavailable("The Operator’s chat couldn’t open.")`, with the current
     `.session` issue's text as the reason when there is one. It no longer activates the window or records
     an issue: `RowFocus` raises, `RowWindows` reports.
   - `reopenWorker(_:)` becomes `async throws` and only runs `native.reopen(task)`.
   - Delete `OperatorIssues.Source.openWindow` and `.reopenWorker`, their labels, and
     `succeed(.openWindow)` in `keeper.finished`.
   - Delete the keeper's `windowIsOpen` port and its closure here (the 180-second grace). `opened` stays,
     read only by `statusIssue` and cleared as today; 5e names that grace.
   - In `reconcile()` and `finishSessionIfIdle()`, call `keeper.ensure(reopen:)` with `reopen` true when
     the Operator has something to type into its chat: `wakePending != nil` or
     `operatorSession?.wakeAwaitingRead == true`.
9. **`OperatorSessionKeeper`.** `ensure(allowPaused:reopen:)` passes `reopen` to `transition`. At the end
   of `transition`, for an established chat (`handover == nil`): `session.window != nil` is done (as
   `windowIsOpen` was), and a chat with no window opens only when `reopen` is true; otherwise return
   without opening and without reporting. A new generation (`handover == .opening`, including the first
   chat of a workload and a renewal) opens as today, whatever `reopen` says.
10. **Docs.** In `docs/operators.md` (about line 135) drop "opening its window, reopening a worker" from the
    list of sources AiTerm tracks; nothing else there changes.

## Keep

- **`OperatorSessionKeeper`'s handover writes** of `operatorSession.window` with `handover`, `existingWindow`
  and `SignalOperatorController.open`'s snapshot lookup for a tagged Claude tab: a reply lost after the
  daemon opened the chat must not open a second chat (5d and 6c revisit them).
- **`SignalOperatorController.closeOperator`'s absence check** while `handover == .closing`: it relies on
  `operatorSession.window` still naming the old window, which is why `RowWindows` leaves the chat's
  window alone during a handover.
- **`opened` and the "did not start in its window" issue** in `statusIssue`.
- **`rememberOperator()`**: it records the chat's session and conversation, which resume needs.
- **`SignalWorkerIO.reopen`'s branch guard and its live-tab check**: the guard is the reason a driven
  worker is resumed through it; 4d merges the openers.
- **`TaskLauncher.openTakenOverWindow` and its snapshot lookup**: 4e deletes Take Over's third kind;
  `ItermFocusControllerTests.aTakenOverTaskChecksForALiveWindowBeforeResuming` pins the lookup until then.
- **`RowFocus.peek` never opening**, `isRemoving`, `selfRaised` and the `LatestTask` staleness guard.
- **`RowFocus.onWindowGone`**: now the only way a gone window reaches `RowWindows`.
- **The `bringTab` branch** of `choose(task:)`: a driven task with a tab that asks brings that tab.

## Decisions already taken

- Choosing the Operator row while the Operator has no work selects it and opens nothing, as today.
- Choosing it with work opens the chat even while paused (`allowPaused: true`), as today.
- The chat's window closing clears `operatorSession.window`. Nothing reopens it on the next tick. It
  reopens when the person chooses its row, or when a wake is pending or unread (a worker ended, a
  question waits, a task blocked, a source failed): that is the Operator having to type into it.
- After iTerm2 restarts, the chat's window, like every row's, is adopted if iTerm2 restored it and
  otherwise stays closed until chosen or until a wake.
- During a keeper handover (`closing`, `revoking`, `opening`) `RowWindows` neither adopts nor clears the
  chat's window. Old and new chat windows carry the same tag, so adoption then would pick the wrong one.
- A tab tagged with the session's id of any agent adopts the chat's window (the chat's tab is a shell
  until Claude starts). Only the keeper's own lookups ask for a Claude tab.
- A worker reopen that fails is reported on the click, with the task as subject, and no longer as an
  Operator issue.
- The Operator row gets the same raise as any row (frame, activate, iTerm2 forward); today's chat open
  only activated the window. This is the uniform behaviour, not a regression.
- A row whose saved window turns out gone when raised (`not found`) has its window cleared through
  `onWindowGone` and opens nothing on that click; the next choose opens it. The Operator row's special
  re-ask goes. A window closing between the event and the click is too rare to handle.
- A notification's Open goes through `choose`, so a task without a window opens it.
- Restore from the Archive reaches the window through `AppController.choose`, after the restore's own
  work token has ended.

## Tests

Delete: none beyond 3a. `OperatorIssuesTests` uses `.openWindow` only as an example of a source the
person retries: switch it to `.takeOver`, which is also not retried.

Adjust:

- Every test that opens a row without a window through `controller.focus.select(...)` now calls
  `controller.choose(...)`: the windowless cases in `OpeningRowControllerTests`, `ClosedViewControllerTests`,
  `ResumingConversationsControllerTests`, and `OperationIssueControllerTests`' two "opening a task" cases.
  Cases where the row has a window (`ItermFocusControllerTests`, `SidebarInteractionTests`'s "old direct
  call", `AppControllerRaceTests.creatingATaskCancelsAnActivationStillInFlight`) keep `focus.select`.
- `ArchiveControllerTests.restoringBringsTheWorktreeAndRowBackAndItsWindowWithItsConversations` and
  `WorkBudgetTests.shelvingAndRestoringATaskSpawnsGit`: call `controller.restoreFromArchive(id)`; the
  restore failure and project-removal race cases keep calling `archiver.restore` and expect no selection.
- `SignalSessionKeeperTests` and `SignalOperatorLifetimeTests`: drop `windowIsOpen:` from the `Ports` they
  build; their `{ $0.window != nil }` is now the keeper's own rule.
- `SignalOperatorIssueTests.aTakeOverWhoseJournalCannotBeWrittenShowsAtOnceAndIsRepairedOnTheNextPass`:
  `try? await r.root.openChat()`; still no `window.createTask`.
- `SignalControllerTests.oneWorkloadKeepsOneOperatorAndServesSignalStatus`: unchanged; it must still send
  one `window.createTask` across two reconciles with no listed tab (the window is set, so it is open).
- `WindowPlanTests` and `WindowReconciliationTests`: the new signatures where they change.

Add:

- `WindowPlanTests`: the Operator chat takes the window a tab tagged with its session's id is in when it
  has none, or when its own is not among them; it plans nothing while a handover runs; a tab tagged with
  another session's id is ignored.
- `WindowReconciliationTests`: a connected snapshot without the chat's window clears it; a disconnected
  one does not; neither clears it during a handover. `ModelsTests`: `closeWindow` clears the chat's window
  only outside a handover.
- `SignalSessionKeeperTests`: `ensure()` on an established chat (conversation set, window nil, handover
  nil) opens nothing and reports nothing; `ensure(reopen: true)` opens it once, resuming its conversation;
  a new generation opens whatever `reopen` says.
- A controller suite `RowWindowsControllerTests` (new file `app/Tests/AiTermTests/RowWindowsTests.swift`):
  - choosing a driven task without a window resumes its worker through the guarded reopen (one
    `window.createTask` whose command carries the saved conversation and the branch guard) and raises it;
  - a driven worker reopen that fails puts "Couldn’t reopen the window." on the banner with the task as
    subject, and `signalController.issues.current` stays empty;
  - choosing a driven task still launching with no checkout selects it and sends nothing;
  - choosing the Operator row without a window opens the chat once and raises it; with no work it only
    selects;
  - the chat's `window.closed` clears `operatorSession.window`, and a reconcile with no wake opens no
    chat; after `signalController.native.onTurn(task)` the next reconcile reopens it once;
  - a tab tagged with the session's id in a new window (iTerm2 restored it) gives the chat that window
    without opening one; during `handover == .closing` it does not;
  - a notification's `.task` open on a task without a window opens and raises it.

## Proof

While iterating:
`scripts/test.sh swift -- --filter "RowWindowsControllerTests|OpeningRowControllerTests|ClosedViewControllerTests|ResumingConversationsControllerTests|ArchiveControllerTests|OperationIssueControllerTests|WorkBudgetTests|ItermFocusControllerTests|SidebarInteractionTests|SignalSidebarTests|SignalSessionKeeperTests|SignalOperatorLifetimeTests|SignalOperatorIssueTests|SignalFreshSessionTests|SignalControllerTests|OperatorIssuesTests|WindowPlanTests|WindowReconciliationTests|ModelsTests"`.
Then plain `scripts/test.sh` in the background.

Snapshots: `scripts/snapshots.sh build/refactor-3b`; every PNG equal to `build/refactor-before` (no view
draws differently; only what a click does changes).

## Done when

- `grep -rn "WindowReconciler\|setRestoreOwedRow\|setReopenOperatorWindow\|setReopenWorkerWindow\|owedRestore\|operatorWindowOwed\|operatedTaskOwed\|windowIsOpen\|openOperator()" app/ docs/architecture.md`
  returns nothing in `app/` (3e rewrites the docs).
- `grep -n "case openWindow\|case reopenWorker" app/Sources/AiTermCore/Operators/OperatorIssues.swift` returns nothing.
- `grep -n "180" app/Sources/AiTerm/Operators/SignalOperatorController.swift` finds only `statusIssue`'s line.
- `grep -rn "focus.select(" app/Sources` finds only `AppController` (in `choose` and `bringTab`).
- `RowFocus.swift` has no `Task`-returning closure property.
- Plain `scripts/test.sh` green; `docs/operators.md` line updated; snapshots equal.

## Not in this step

- The Operator row's fixed id and the payload-free selection case (`.operation(UUID)` stays here): 3c.
- `RowFlags`: 3c. The iTerm2 banner: 3d. `docs/windows.md` and the other window docs: 3e.
- One opener for manual and driven tasks, one restore, and the Operator's stage launch calling the same
  operations: 4d. Take Over's own opener and `prepareTakenOverRequest`: 4e.
- The keeper's chat lifecycle as one saved state: 5f. The other 180-second literals: 5e.
- `daemon.snapshot()` as a query in the keeper and the taken-over opener: 6c.
