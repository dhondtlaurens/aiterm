# 4d. One restore, one worker checkout, one window opener

Implementer: Opus 5.5, high effort. Depends on: 4c. Audit findings: TL F3, RT F4.

## Why

A signal task re-implements what a manual task already has. Restoring an archived row exists twice:
`TaskArchiver.restore` for a click, and `StageRunner` plus `SignalWorkerIO.restore` for the
Operator, which does git's restore and then its own `moveFromArchive`, without the checkout refresh
or the `.worktreeinclude` report. A worker's checkout for an item is written twice:
`SignalWorkerIO.prepare` (with two strategies for a request, one per ownership) and the taken-over
opener's copy in `TaskLauncher.openTakenOver`. A task's window is opened by several code paths whose
commands are decided in each: the manual opener resumes `resumeCommands`, `SignalWorkerIO.reopen`
resumes the first worker under its guard through a different daemon call. They grew this way because
signals were built beside the manual task instead of on it. The end state: one restore on
`TaskLauncher` (git, then the row back from the archive; choosing it and the toast only when a person
asked), one "worker checkout for an item" on `TaskLauncher` (a request's source branch, or a new
branch from git's default branch) that the stage launch uses, and one window opener on `TaskLauncher`
whose commands come from one function of ownership: a manual task resumes its conversations plainly, a
driven task resumes its worker under the guard. The Operator reaches restore and checkout the way it
already reaches archive and remove: ports the app sets to the lifecycle owner's operations.

## Today (after 4c)

Phase 3 (3b) gave every row kind one `RowWindows.open(row)` that picks an opener; `AppController.choose`
alone decides what choosing a row does. Phase 1j renamed `operated:` to `worker:` and
`SignalOperatorCommand` to `OperatorLaunch`. Phase 2f kept `SignalWorkerIO.prepare`'s late
checkout save (a checkout that finishes after the Operator lost its claim still saves its folder on
the task) and added a test for it; this step moves that rule into the one checkout.

- Restore:
  - `app/Sources/AiTerm/TaskArchiver.swift` `restore(_:) async` (all that is left of the archiver):
    guard, `.restoring` token, `TaskWorkflow.restore`, on failure the alert "“<title>” can’t be
    restored" with `OperationIssue.reason(of:)`; then re-checks the workspace, the archived row and its
    project, moves the row back and opens its project in one mutation, `checkouts.refresh()`, flush,
    `TaskLauncher.report(made.worktreeInclude, ...)`, ends the token, chooses the row (opening its
    window, as phase 3 left it) and toasts "<Kind> restored." Called by the Archive sheet through
    `AppController.presentArchive()`.
  - `app/Sources/AiTerm/Operators/StageRunner.swift` `run(_:)`: for an archived row, `ports.restore`,
    then its own `moveFromArchive` and `worktreePath` update. `Ports.restore` is wired in
    `SignalOperatorController` (`stages`) to `SignalWorkerIO.restore`, which checks the claim
    (`require`), begins `.restoring` and runs `TaskWorkflow.restore`.
- Worker checkout:
  - `SignalWorkerIO.prepare(_:signal:)`: claim check, `.opening` on the task and `.openingTaskWindow`
    on the project; a request item through `requestCheckout` (reads `connections`, the existing
    request from the branch, refuses a fork with "The request's source branch is unavailable in this
    repository. Open it yourself to choose its checkout.", then `TaskCreator.createReview` from a
    draft); otherwise git's default branch and `TaskWorkflow.checkOutWorker`. Wired as
    `StageRunner.Ports.prepare` in `SignalOperatorController`.
  - `SignalWorkerIO.prepareTakenOverRequest` and the taken-over branch inside `requestCheckout`
    (`addReviewWorktree` on the request's source branch).
  - `TaskLauncher.openTakenOver`: for a taken-over task without a checkout, the same two branches
    again (its `prepareRequest` port, or default branch plus `checkOutWorker`), then saves the path.
- Window opening:
  - `RowWindows.open(row)` (3b), task rows: a manual task through the opener that came from
    `WindowReconciler.open` (folder check, `task.resumeCommands`, `TaskLauncher.openWindow` for the
    first, a tab per further command, "Reopened the window, but not every conversation." on a failed
    tab); a driven task through `SignalOperatorController.reopenWorker` and `SignalWorkerIO.reopen`
    (one guarded command for the first worker conversation through `SignalWorkerIO.command(for:...)`,
    `daemon.openWorkerWindow` titled `task.title`, refusal "Its worker has no saved conversation to
    reopen."); a taken-over task through `TaskLauncher.openTakenOverWindow`. Re-check the shape with
    `grep -rn "reopenWorker\|openTakenOverWindow\|resumeCommands" app/Sources/AiTerm`.
  - `SignalOperatorController.reopenWorker` reports failure through `OperatorIssues.Source.reopenWorker`
    unless 3b moved it to the click; check with `grep -rn "reopenWorker" app/Sources`.
  - `TaskLauncher.openWindow(for:command:with:)`: `createTaskWindow` titled the branch, adopted by the
    row, closed again if the row went. Used by create and by the manual opener.
- `SignalWorkerIO.command(for:prompt:slot:conversation:)`: checks the signal permits the row, then
  builds `AgentCommand.build(..., worker: true, promptFile:, publishing: true, resuming:)` and wraps
  it with `WorkerGuardLaunch.command(..., slot:, publishes: kind != .review)`, off the main actor.
- `AppController.init` builds the launcher before the `OperatorPorts` (which holds `home` and
  `workerGuardExecutable`); `agents` is built before both.
- Tests: `ArchiveTests` restore tests, `SignalEngineTests.anArchivedItemIsRestoredAndContinuedInItsOriginalTask`,
  `SignalWorkerIOTests` (line about 69 wires `native.prepare` and `native.restore` as StageRunner
  ports), `ItermFocusTests` (taken-over openings), phase 3's driven-row opening tests
  (`grep -rln "reopenWorker\|openWorkerWindow" app/Tests`).

## Change

1. `TaskLauncher.restore(_ id:) async throws -> TaskItem?`: nil when nothing starts (workspace
   locked, row not archived, its project gone, the row busy). Begins `.restoring`; git's restore;
   re-checks the workspace, the archived row and its project (else returns nil, leaving the row
   archived; the next restore adopts the worktree, as today); moves the row back; `checkouts.refresh()`;
   flush; reports the `.worktreeinclude` outcome on the row; ends the token; returns the row. It
   chooses nothing, opens no project, shows no toast. Git's refusal throws.
2. A person's restore: `AppController.restoreFromArchive(_ id:) async` (the Archive sheet's restore
   closure): `launcher.restore`; on a thrown error the existing alert "“<title>” can’t be restored"
   with the reason; on a row, open its project (`collapsed = false`), toast "<Kind> restored." when
   nothing failed to save, then choose the row as a click does and await it. Delete `TaskArchiver`
   and its property; `AppController` and the tests use `launcher.restore` and
   `restoreFromArchive`.
3. `TaskLauncher.checkOutWorker(_ task:, stillAllowed:) async throws -> (task: TaskItem, includes: WorktreeInclude.Outcome)`:
   holds `.opening` on the task and `.openingTaskWindow` on its project ("This task's project is
   busy." when it cannot); for a task with a request reads the connections, finds the request from
   its branch and refuses a fork (sentence above), then makes the review-style worktree on the
   request's source branch with its target as base; otherwise reads git's default branch and calls
   `TaskWorkflow.checkOutWorker(... reserved:)`. It calls `stillAllowed` after every await and throws
   "The task changed while its worktree was made." when it says no. It saves the result itself: once
   git has made the worktree, if the task still exists on the same project and branch and has no
   checkout, its worktree path and base branch are saved and flushed, whatever `stillAllowed` says
   then; only after that does a refusing `stillAllowed` throw. A checkout made for a task is that
   task's, whoever asked for it. This is the late checkout save of `SignalWorkerIO.prepare`, now in
   one place; without it a task taken over during a request's checkout would have no folder, and its
   next checkout would be refused because the branch is already checked out. Callers save nothing.
   Put the git half of the request path in Core as a `TaskWorkflow` function beside `checkOutWorker`
   (one strategy: `addReviewWorktree` with the review slug and `.worktreeinclude` copied). The
   draft-based `TaskCreator.createReview` call for a worker goes.
   `TaskLauncher` gets a settable connections reader, set by `AppController` once the signal
   controller exists to `signalController.connections()`.
4. The Operator reaches 1 and 3 through two ports on `SignalOperatorController`, set by
   `AppController` beside `archive` and `remove`: `restore` (calls `launcher.restore`, nil becomes
   "The task is busy.") and `checkout` (calls `launcher.checkOutWorker`). `StageRunner.Ports.prepare`
   is wired to `checkout` with the claim check `SignalWorkerIO` performs today (enabled, workspace
   changeable, not paused, claim can act, not cancelled) as `stillAllowed`, checked once before the
   call too. `StageRunner.Ports.restore` is wired to `restore` after that claim check, and now means
   "the row is back in the sidebar": `StageRunner.run` drops its own `moveFromArchive` and path
   update and keeps its `holds(...)` check after the await. Delete `SignalWorkerIO.prepare`,
   `requestCheckout`, `prepareTakenOverRequest`, `restore`, and `connections` if nothing else reads it.
5. The taken-over opener (still here until 4e): `TaskLauncher.openTakenOver`'s checkout block calls
   `checkOutWorker` with its `current(task)` check as `stillAllowed`; its `prepareRequest` parameter
   and the `RequestCheckout` typealias go. Its guarded resume commands stay until 4e.
6. Core: move the body of `SignalWorkerIO.command` after its permission check into one
   `WorkerGuardLaunch` function that takes the task, the prompt, the conversation to resume, the slot,
   the remote, `home`, the worker guard executable and git, and returns the guarded command line.
   `SignalWorkerIO.command` keeps its permission check and calls it.
7. `TaskLauncher.open(_ id:) async throws`, the one opener for a manual or driven task with a
   checkout and no window: `.reopening` token; the folder check and missing-worktree handling exactly
   as `RowWindows`' manual opener has it after phase 3; commands from `openCommands(for:)`; the first
   through `openWindow(for:command:with:)`, each further one in a tab, a failed tab reported as
   "Reopened the window, but not every conversation." on the row. `openCommands(for:)` is the one
   function of ownership: a task with no signal record, `task.resumeCommands`; a driven task, one
   command, its first worker conversation resumed with an empty prompt through Change 6 on slot
   "main" (no conversation: throw "Its worker has no saved conversation to reopen."). Built off the
   main actor. `TaskLauncher` takes `home` and the worker guard executable from `OperatorPorts`;
   build the `OperatorPorts` before the launcher in `AppController.init`.
8. `RowWindows.open(row)`: a manual or driven task goes to `launcher.open`; a taken-over task still
   goes to `openTakenOverWindow` (4e). Delete the manual opener body moved into Change 7,
   `SignalWorkerIO.reopen`, `SignalOperatorController.reopenWorker` and, if nothing else produces it,
   `OperatorIssues.Source.reopenWorker` with its label. A failed open is reported where phase 3
   reports a failed open of any row.
9. Docs: `docs/operators.md`, the failure-source list (about line 135), drops "reopening a worker" if
   the source went; `docs/windows.md` names `TaskLauncher.open` where it names the openers.

## Keep

- `SignalWorkerIO.launch` and its `openWorkerWindow`/`openWorkerTab`: the Operator's launch of a new
  turn with a prompt is not an open. Its permission check, delivery check and pending-reply intent stay.
- `StageRunner`'s "persist intent before effects" order and its `holds` checks after every await
  (`SignalEngineTests.aCompleteMatchSavesItsStageBeforePreparingAndLaunchingAWorker` pins it).
- `TaskWorkflow.checkOutWorker`'s adoption of an earlier attempt's worktree or branch and its
  baseline (`mergeBase`).
- The test 2f added in `SignalWorkerIOTests` (a Take Over that lands while a request task's checkout
  is running leaves the task with the finished checkout's folder and launches no worker). Point it at
  `TaskLauncher.checkOutWorker`; it must keep passing.
- The fork refusal: a fork's source branch is not in this repository.
- `TaskLauncher.openWindow`'s closing of a window whose row went while it opened.
- The restore's `.restoring` token, which `ProjectActions` reads to refuse removing a project
  mid-restore (`aProjectCannotBeRemovedWhileOneOfItsArchivedRowsIsRestoring`).

## Decisions already taken

- Once git has restored the worktree, the row comes back even if the Operator lost its claim
  meanwhile (a pause, a Take Over): a restored worktree belongs in the sidebar. `StageRunner` then
  stops at its `holds` check, as today.
- The Operator's restore now reports a `.worktreeinclude` shortfall on the row and refreshes the
  checkouts, as a click's does. That is the point of sharing it.
- A driven task reopened by a click opens through `createTaskWindow`, titled by its branch like a
  manual task's window, instead of `openWorkerWindow` titled by its task title. Its guarded command
  is the one `SignalWorkerIO.reopen` built. Say so in the commit body.
- A driven task's click no longer checks that the Operator is running: opening a window and
  resuming its own worker's conversation is the person's.
- The request checkout for a worker now uses the plain review-worktree path for both ownerships;
  `TaskCreator.createReview`'s title and model checks never applied to a worker in practice (its
  title and model come from the signal).
- A live tagged tab for a driven task without a window is adopted by `RowWindows` (3b); the opener
  needs no "activate the existing session" branch.

## Tests

- `ArchiveTests`: restore tests call `restoreFromArchive` (person) and keep their assertions; add
  "`launcher.restore` brings the row back saved, neither chosen nor toasted, its project fold
  untouched".
- `SignalEngineTests.anArchivedItemIsRestoredAndContinuedInItsOriginalTask`: its `restore` stub moves
  the row back itself, as the real port now does. Other `restore: { $0 }` stubs are unchanged.
- `SignalWorkerIOTests` (the test about line 51 wiring `native.prepare` and `native.restore`): wire
  `prepare: { task, _ in task }` and the stub restore; the task already has a worktree.
- Add: a stage launch for a request item checks out the request's source branch and refuses a fork,
  through `launcher.checkOutWorker` (move the fork assertions from `ItermFocusTests.aTakenOverRequestOpensItsSourceBranchAndRefusesAFork`
  only if that test cannot stay as is until 4e).
- Add: choosing a driven task without a window opens one in its worktree, its first worker
  conversation resumed under the guard (the recorded scope names its ownership), and a click on a
  manual task still resumes every conversation plainly.
- Delete phase 3's tests of `reopenWorker` failure as an Operator issue, if any; survivor: the
  failed-open-on-the-click test phase 3 added.

## Proof

- `scripts/test.sh swift -- --filter ArchiveControllerTests`, then `SignalEngineTests`,
  `SignalWorkerIOTests`, `ItermFocusControllerTests`, the phase 3 row-opening suites,
  `SignalJourneyTests`, `WorkBudgetTests` (restore spawns: must not rise), `TaskWorkflowTests`.
- `scripts/snapshots.sh build/4d`: equal to 4c's.
- Plain `scripts/test.sh`.

## Done when

- `grep -rn "TaskArchiver\|prepareTakenOverRequest\|requestCheckout\|func reopen(\|reopenWorker\|RequestCheckout" app/Sources`
  returns nothing.
- `grep -rn "moveFromArchive" app/Sources/AiTerm/Operators` returns nothing.
- `grep -rn "TaskCreator.createReview" app/Sources/AiTerm/Operators` returns nothing.
- The suites above and plain `scripts/test.sh` are green.

## Not in this step

- Take Over becoming an ordinary task, and deleting the taken-over opener and its guarded resume
  commands: 4e.
- The Operator's in-flight sets and one tick: 5e. The Oracle: 5c.
