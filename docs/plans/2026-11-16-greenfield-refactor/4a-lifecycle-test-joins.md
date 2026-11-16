# 4a. Task lifecycle operations return when their work is done

Implementer: Opus 5.5, high effort. Depends on: phase 3 (3a to 3e) merged to `main`. Audit finding: TS F4.

## Why

Archive, Restore, Remove, Remove's banner retries and removing an archived row each start their
work in an unstructured `Task` and hand that handle back. No product caller reads it: every view
already wraps the call in `Task { ... }` and drops the result. Only tests read it, through about two
hundred `?.value` joins and through `TaskRemover.waitForRemoval(of:)`, a join that exists for tests
alone. The owners were written to be called from key handlers and tested by awaiting their handle;
the Operator's owners later moved to a different rule (`OperatorWork` and `settled()`), the task
lifecycle did not. The end state: each lifecycle operation is an `async` function that returns once
its work is done, or at once when nothing starts. A view wraps it in a `Task`; a test awaits it; a
race test still holds the work at a port latch and runs the call in a task of the test's own. The
rest of phase 4 restructures these owners, and after this step that changes one call per test
instead of a join per test. Nothing a person sees changes. The plan's "one settled join" is realised
this way: the design notes rule out a new global join.

## Today

Describe and re-check the code as phase 3 left it. `WindowReconciler` is now `RowWindows`; the close
question, its Archive variant (`archiveInstead`, `offersArchive`), the restore queue and the per-row
"Couldn't reopen" state are gone. Phase 1 renamed `removeFromShelf` to `removeFromArchive` and
`shelfRows` to `archiveRows`. Phase 2 (2c) deleted the remover's second disk confirmation, its
`confirmations` dictionary and the `confirmsRemoval` port.

- `app/Sources/AiTerm/TaskArchiver.swift`:
  - `archive(task:) async -> Task<Void, Never>?`: checks, begins `.archiving` on the task, then
    returns a `Task` that runs the private `archive(_:in:holding:)` and reports failures. Nil when
    nothing started.
  - `restore(_:) -> Task<Void, Never>?`: begins `.restoring`, returns a `Task` that runs git's
    restore, moves the row back, ends the token and then chooses the row as a click does (whatever
    phase 3 left there; it hands back the activation's handle, which the restore drops today).
  - `confirmRemove(archived:) async -> Task<Void, Never>?`: asks, then returns a `Task` that forgets
    the row and releases its branch.
  - `archiveAutomatically(_:starting:) async throws` already returns when done. Leave it.
- `app/Sources/AiTerm/TaskRemover.swift`:
  - `confirmRemove(task:) async -> Task<Void, Never>?`: asks, begins `.removing`, returns the handle
    from the private `remove(_:from:deleteBranch:holding:before:) -> Task<Void, Never>`.
  - `keepBranch(of:) -> Task<Void, Never>?` and `deleteBranch(of:) async -> Task<Void, Never>?`: the
    banner's retries, through the same private `remove`.
  - `running: [UUID: Task<Void, Never>]`: each removal's or closing's handle, written in `remove` and
    `automaticallyForgetRemovedTask`, cleared in `end(_:of:)`, and read only by `waitForRemoval(of:)`.
  - `waitForRemoval(of:)`: awaits `running[id]` and `recordCleanups[id]`. No product caller:
    `grep -rn "waitForRemoval" app/Sources` finds only its definition.
  - `removeAutomatically(_:starting:stillAllowed:) async throws` already returns when done.
- `app/Sources/AiTerm/AppController.swift`:
  - `perform(_:) async -> Task<Void, Never>?` forwards the banner's actions (Keep Branch, Delete
    Branch…, Rebase). Its one product caller, `SidebarView` about line 284, wraps it in a `Task`.
  - `removeSelection() async -> Task<Void, Never>?`: ⌘⌫. `SidebarView` about line 143 wraps it in a
    `Task`. For a terminal it returns `terminals.close(terminal:)`'s handle.
  - `presentArchive()` hands `ArchiveSheetModel` a synchronous `restore` closure that calls
    `archiver.restore($0)` and drops the handle.
- Views: `SidebarRows.swift` (`TaskRowView` context menu and VoiceOver actions) call
  `archiver.archive(task:)` and `remover.confirmRemove(task:)` inside `Task { ... }`.
- Tests that join these handles. Re-run to list them:
  `grep -rnE "(archiver\.(archive|restore|confirmRemove)|remover\.(confirmRemove|keepBranch|deleteBranch|waitForRemoval)|\.perform\(|removeSelection\(\))" app/Tests`.
  Expect `ArchiveTests.swift`, `CheckoutCleanupTests.swift`, `ControllerRaceTests.swift`,
  `OperationIssueTests.swift`, `WorkBudgetTests.swift`, `SidebarProjectionTests.swift`,
  `PullDefaultTests.swift` (through `perform`) and any phase 3 window suite that still removes.

## Change

1. `TaskRemover`: make the private `remove(...)` an `async` function that does the work inline
   (its `defer` ends the token) instead of returning a `Task`. `confirmRemove(task:)`,
   `keepBranch(of:)` and `deleteBranch(of:)` become `async` with no result: they return when the
   removal has finished, or at once when nothing started. Drop `@discardableResult` where it no
   longer applies.
2. `TaskRemover`: delete `waitForRemoval(of:)` and the `running` dictionary. The checkout cleanup's
   closing (`automaticallyForgetRemovedTask`) stays an unstructured `Task` started by a checkout pass,
   as today, but is no longer stored. `recordCleanups` stays (it de-duplicates; 4c folds it).
3. `TaskArchiver`: `archive(task:)`, `restore(_:)` and `confirmRemove(archived:)` become `async`
   with no result and do their work inline. `restore` awaits the activation handle of the choosing it
   ends with, so it returns once the row's window has opened (or the choosing gave up). This is a
   product read of that handle, not a test one.
4. `AppController`: `perform(_:)` and `removeSelection()` become `async` with no result.
   `removeSelection` awaits the terminal close's handle for a terminal row. `presentArchive()` wraps
   the restore in a `Task` inside the closure it hands the sheet. `removeFromArchive(_:)` already
   awaits; it now awaits the whole removal.
5. Views: no change beyond what the compiler asks; they already call inside `Task { ... }`.
6. Tests: convert every join (see **Tests**). No assertion changes, except that an assertion on a nil
   handle becomes an assertion on the effect.
7. `docs/testing.md`, the paragraph that says to join Operator work with `settled()`: add one
   sentence that a task lifecycle operation (archive, restore, remove, remove from the Archive) is
   awaited itself, and a race test holds it at a port latch and runs it in a task of its own.

## Keep

- `RowFocus.select`, `peek` and their `LatestTask` handles: product code reads them (`bringTab`
  awaits the raising; a new selection cancels the old activation).
- `OperatorWork` and the Operator's `settled()`: a different, existing rule for the Operator.
- `CheckoutMonitor.refresh()` returning its pass: tests and product both use it to drive passes.
- `RowWindows`' open and the handles it hands `RowFocus`: product reads them to raise the window.
- `recordCleanups`, `outcomes`, `removals`, `rows`: 4c reshapes them; do not touch them here.
- `TaskLauncher.createTask`/`createReview` (already `async throws`) and
  `SignalOperatorController.takeOver` (already `async`).

## Decisions already taken

- When nothing starts (workspace locked, row gone, busy, question declined), the function returns at
  once. No Bool or "started" result: no product code ever branched on the nil.
- Re-entrancy is unchanged. In `aRemovalStartedDuringTheAlertIsTheOnlyOneThatRuns`, the nested
  Remove started from `ScriptedPrompter.whileAsking` now runs to its end inside the first alert,
  then the first answer finds the task gone and returns. The test drops its "the outer call returned
  nil" expectation and keeps "one window close, two questions, no banner".
- Nothing cancels these operations (a view's `Task` is never cancelled). Add no cancellation
  handling.
- Awaiting the whole removal holds the view's `Task` longer. That is invisible.
- A refused second operation (busy) now shows only as the absence of a second effect; that is the
  assertion to write.

## Tests

No test is deleted. Convert, using these patterns:

- `await (await x.archive(task: t))?.value` and `await x.confirmRemove(task: t)?.value` become a
  plain `await x.archive(task: t)` and `await x.confirmRemove(task: t)`.
- Held at a port: `let archiving = await x.archive(task: t)` followed by
  `try await server.received("window.close")` becomes `let archiving = Task { await x.archive(task: t) }`,
  then the latch, then `server.release()`, then `await archiving.value`.
- "Twice at once" (`archivingTwiceAtOnceArchivesOnce`, `restoringTwiceAtOnceRestoresOnce`): start
  the first in a test task, wait for its port latch (for restore, hold `worktree add` with a held git
  runner, or `window.createTask`), await the second call (it returns at once), release, await the
  first, then expect one archived row (one restored row) and one window close (one window open).
- `#expect(await perform(...) == nil)` becomes an expectation that nothing changed (row, branch,
  banner as before).
- `controller.remover.waitForRemoval(of:)` in `CheckoutCleanupTests`: after
  `await controller.checkouts.refresh().value` the closing has begun its `.closing` work token
  synchronously, so wait with `await eventually(describing:) { controller.work.operation(onTask: id) == nil }`,
  or on the visible end state (`controller.state.tasks.isEmpty`). For
  `theCleanupForgetsGitsLockedRecordOfADeletedCheckout`, wait until the task is gone and
  `git worktree list --porcelain` no longer names the path.
- `SidebarProjectionTests.aRemovedTaskLeavesTheBadgeOnce`: `try #require(await confirmRemove(...))`
  plus `.value` becomes one `await`.

## Proof

- While iterating: `scripts/test.sh swift -- --filter ArchiveControllerTests`, then
  `CheckoutCleanupControllerTests`, `AppControllerRaceTests`, `OperationIssueControllerTests`,
  `WorkBudgetTests`, `SidebarProjectionTests`, `PullDefaultTests`, `SignalAutomaticCleanupTests`.
- Then plain `scripts/test.sh`, started in the background.

## Done when

- `grep -rnE "func (archive|restore|confirmRemove|keepBranch|deleteBranch|perform|removeSelection)\(.*-> Task<" app/Sources/AiTerm`
  returns nothing.
- `grep -rn "waitForRemoval" app` returns nothing.
- `grep -rnE "(archiver|remover)\.[A-Za-z]+\(.*\)\)?\?\.value" app/Tests` returns nothing.
- Every converted suite is green and plain `scripts/test.sh` passes.
- `docs/testing.md` has the sentence of Change 7.

## Not in this step

- Remove asking everything up front, and the retry state going: 4b.
- One teardown owner and per-row state: 4c.
- Restore moving to `TaskLauncher`: 4d.
- Handles outside the task lifecycle (`ProjectActions.pullDefault`/`rebaseDefault`,
  `TerminalActions.newTerminal`/`close`, `HelperLink.setMatchItermBackground`,
  `SidebarTiling.setInterfaceSize`): not lifecycle operations; leave them.
