# 4e. Take Over makes an ordinary task

Implementer: Opus 5.5, high effort. Depends on: 4d. Audit findings: RT F4, TL F3.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.


1. The design note says that on Take Over "its guard scope is removed, as today". Today the guard
   scope is not removed: `SignalOperatorController.repairTakeOver` re-writes each recorded scope
   (`WorkerGuardLaunch.recordedScope`, then `prepare`) with the raised ownership, so a launch already
   past its last claim check cannot write a scope with the old ownership
   (`WorkerGuardLaunchTests.aStaleLaunchCannotRestoreAuthorityAfterTakeOver`). Deleting the scope
   folder would also take the guard from a worker still running, whose `PATH` and `core.hooksPath`
   point into it, which contradicts "a worker still running keeps the guard it was launched with". This
   brief keeps today's refresh with the raised ownership and never deletes the folder.
2. A task taken over without a checkout (a queued or blocked stage whose worker never started) has no
   worktree, and the taken-over opener that made one on the first click goes. An ordinary task always
   has a worktree, so this brief makes the worktree at Take Over, through 4d's one worker checkout.
3. Take Over leaves `SignalOperatorController` for `TaskLauncher` (design note 5d: "Take Over already
   left in phase 4"). Its failures therefore go to the banner on the task, and
   `OperatorIssues.Source.takeOver` goes. Its journal line ("The person took over this task.") goes
   too: nothing reads a task's journal once its signal record is gone.

## Why

A taken-over task is a third kind of task. It keeps its `signalTask` with `takenOver = true`, so the
Operator skips it in about twenty places, the window code skipped it, and it needs an opener of its
own (`TaskLauncher.openTakenOver`) with a copy of the worker checkout and guarded resume commands
(`SignalWorkerIO.takenOverResumeCommands`). This happened because Take Over was added as a flag on the
Operator's record rather than as a hand-over to the task lifecycle. The person who takes a task over
means "this is mine now". The end state: Take Over removes the task's `signalTask`, sets a small
sparse mark on the task so `MatchDecision` never continues it, withdraws the Operator's questions for
it and raises its worker guard's ownership as today. From then on it is an ordinary task: opened,
archived, restored and removed like one, its conversations resumed with plain commands. A worker
still running keeps the guard it was launched with until it ends. This is a listed visible change,
and the saved format changes (`signalTask` loses `takenOver`; a task gains the mark).

## Today (after 4d)

Phase 2f reduced the Take Over repair loop to one attempt and one reported issue, and kept the
late checkout save, which 4d moved into `TaskLauncher.checkOutWorker`. 4d made
`TaskLauncher` own restore, `checkOutWorker(_:stillAllowed:)` and `open(_:)`, with `home` and the
worker guard executable. Re-run `grep -rn "takenOver\|takeOver\|TakenOver\|TakeOver\|taken over\|taken-over" app daemon docs`
before you start; the readers are:

Core, `app/Sources/AiTermCore/`:
- `Operators/Signals/SignalTask.swift`: the `takenOver` field; `canRunThen`, `needsWorkerReads`,
  `keepsOperatorSession` exclude it.
- `Operators/Signals/SignalTransitions.swift`: the guard refusing any action on a taken-over record,
  and `case .takeOver` (raises ownership, sets the flag). Only tests apply `.takeOver`.
- `Operators/Signals/SignalAction.swift` `.takeOver`; `SignalTransitionError.takenOver`.
- `Operators/Signals/MatchDecision.swift` about line 42: a matching task is continued unless taken over.
- `Operators/Signals/AppState+Signals.swift`: `isCurrentOperatorQuestion`, `operatorMayStartWork`.
- `Operators/Signals/OperatorDigest.swift` about lines 98 and 108 (`run_status` leaves them out).
- `Operators/WorkerTabs.swift` `isLaunching`.
- `Operators/OperatorIssues.swift` `Source.takeOver` and its label "Take Over".
- `Sidebar/OperatorLine.swift` comment ("its card says `taken over`"), if the file still exists.
- `Daemon/AppState+WindowPlan.swift` comment, if phase 3 left it.
- `Models.swift` `TaskItem` (hand-written coding; `signalTask` encoded only when present).

App, `app/Sources/AiTerm/`:
- `Operators/SignalOperatorController.swift` `takeOver(_:)` (one mutation: flag, ownership + 1,
  `currentAct` nil, the project opened, questions and paused workers for the task removed; then the
  guard refresh and journal line, one attempt each, failures to `.takeOver`) and `prune()`'s two
  `!record.takenOver` terms.
- `AppController+Signals.swift` `takeOver(_:)`: calls the controller, then toasts
  "<ticket key or title> is yours. The Operator let go of it.".
- `TaskLauncher.swift`: `takenOverOpenings`, `openTakenOverWindow`, `openTakenOver`.
- `RowWindows` (3b): its taken-over branch to `openTakenOverWindow`.
- `Operators/SignalWorkerIO.swift`: `takenOverResumeCommands`; `command(for:...)` permits any row and
  passes `worker: !record.takenOver`.
- `Operators/SignalClaim.swift` init; `Operators/StageRunner.swift` `resume` and the header comment;
  `Operators/RequestWatch.swift` about line 50; `Operators/QuestionRounds.swift` about line 164;
  `Operators/SignalPauseSignaller.swift` about lines 23 and 41.
- `SignalSidebar.swift` (`held`), `PerRow.swift` (`dropGone`), `SidebarProjection.swift` (drawn copy),
  `RowFocus.swift` (`row(id:)`, the queued check wherever 3b put it), `ProjectActions.swift` about
  lines 241 and 280, `AppController+Operators.swift` (`reveal`), `Views/SidebarRows.swift` (the Take
  Over menu item), `Snapshots/SignalSidebarSnapshots.swift` (the "taken-over" pose).

Tests: `SignalSidebarTests`, `ItermFocusTests` (four taken-over tests), `SidebarRowRedrawTests`,
`Operators/SignalEngineTests`, `SignalQuestionRoundsTests`, `SignalControllerTests`,
`SignalToolHandlerTests`, `SignalOperatorIssueTests`, `SignalAgentChoiceTests`, `SignalWorkerIOTests`,
Core `OperatorIssuesTests`, `WorkerGuardLaunchTests`, `SignalDomainTests`, `SignalSavedFormatTests`
and its fixture `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json`.

## Change

1. Core `TaskItem`: add `takenOver: Bool`, saved under the key `takenOver`, written only when true and
   read as false when absent. It is the mark that a person took the task over from a signal.
2. Core `AppState.takeOver(_ id:) -> SignalTask?` in `AppState+Signals.swift`, mutating: for a sidebar
   task with a signal record, removes the record, sets the mark, opens the task's project, removes
   the Operator's questions about the task and its paused-worker entries; returns the removed record
   (nil, and nothing changed, otherwise).
3. Core: delete `SignalTask.takenOver` and its terms in `canRunThen`, `needsWorkerReads` and
   `keepsOperatorSession`; `SignalAction.takeOver`; `SignalTransitionError.takenOver`; the guard and
   case in `SignalTransitions`; `OperatorIssues.Source.takeOver`. `MatchDecision`: a task that matches
   the item and carries the mark gets no decision (it is neither continued nor adopted). Every other
   Core reader drops its `takenOver` term: a task the person took over has no record.
4. `TaskLauncher.takeOver(_ id:) async`: guard the workspace can change and the task has a record;
   apply `AppState.takeOver` and flush (a failed save stops here, as today). Then, one attempt, off
   the main actor: re-write each recorded guard scope of the task (slot "main" and each extra tab key
   of the removed record) with the record's ownership plus one; on failure report on the banner, with
   the task as subject, "The task is yours, but its branch guard couldn’t be refreshed." and the
   error. Then, if the task has no checkout and no checkout for it is in flight (its `.opening`
   token is free): `checkOutWorker` with a `stillAllowed` that the row is still there, still marked,
   on the same project and branch (4d's checkout saves the path and base branch itself); refresh the
   checkouts and report the `.worktreeinclude` outcome; on failure report "The task is yours, but
   its worktree couldn’t be made." with the error (a save failure keeps today's sentence "The checkout
   could not be saved. Recover the workspace before opening its window.").
5. `AppController+Signals.takeOver(_:)` calls `launcher.takeOver`, and toasts as today when the task
   then carries the mark. Delete `SignalOperatorController.takeOver` and whatever 2f left of its
   repair.
6. Delete `TaskLauncher.takenOverOpenings`, `openTakenOverWindow`, `openTakenOver`; `RowWindows.open`
   sends every task to `launcher.open`. `TaskLauncher.openCommands(for:)` needs no third case: a task
   without a record resumes `task.resumeCommands`.
7. `SignalWorkerIO`: delete `takenOverResumeCommands`; `command(for:...)` always checks the signal's
   rows and always passes `worker: true`.
8. App readers: `SignalClaim` needs only a record; `StageRunner.resume`, `RequestWatch`,
   `QuestionRounds`, `SignalPauseSignaller`, `SignalOperatorController.prune` drop the term;
   `SignalSidebar.held` keeps tasks whose record is not `.stopped`; `PerRow.dropGone` keeps every
   record's signal id; `SidebarProjection` stops copying the flag; `RowFocus.row(id:)` matches any
   task's record signal; the queued check reads the record's phase and checkout only;
   `ProjectActions` uses "has a record" / "has none"; `AppController+Operators.reveal` drops the
   term; the Take Over menu item shows for any task with a record.
9. `SignalSidebarSnapshots`: the "taken-over" pose applies `AppState.takeOver` to its task.
10. `docs/operators.md`: rewrite the Take Over paragraph (about lines 126 to 130) to: "**Take Over**
    on a driven task makes it an ordinary task in its project. The Operator lets go of it and of its
    questions, and later signals never continue it. Its worktree, branch and conversations stay; a
    worker still running finishes its turn under its branch guard. If its worker never started, Take
    Over makes its worktree first; a merge-request task checks out the request's source branch. From
    then on it opens, archives, restores and removes like any task, and its conversations resume
    without a branch guard. There is no Hand Back." Drop "Take Over" from the failure-source list
    (about line 135); in the "Session recovery" paragraph say tasks you took over are no longer the
    Operator's.

## Keep

- The ownership raise on the recorded guard scopes and `WorkerGuardLaunch.prepare`'s refusal of a
  lower ownership: they stop a launch already past its claim check.
- The scope folder itself: a running worker's shims and hooks live there.
- `SignalClaim`: a removed record makes every late completion's claim fail, which is what keeps Take
  Over safe mid-launch, mid-Oracle and mid-merge (`SignalEngineTests.aTakeoverWhileCheckoutIsPreparedPreventsTheLaunch`,
  `SignalToolHandlerTests.aSuspendedReadCannotAnswerForATaskTakenOverInTheMeantime`,
  `SignalAgentChoiceTests.aTakeOverDuringTheOracleRoundRefusesTheLateChoice`).
- `MatchDecision`'s other matching rules, and its adoption of an unmarked manual task.
- The toast wording, and Take Over opening the task's project.
- `PreservedFields` on `TaskItem`: an older build keeps the new key it does not know.

## Decisions already taken

- The mark is a plain flag, not the item's identity: a signal task always carries its item as
  `jira` (ticket items) or `mr` (request items), which `MatchDecision.matchesItem` finds without the
  record. (1d removed branch items.)
- An archived task keeps its mark; `MatchDecision` reads the archive too, so it is never continued.
- Take Over of a task the Operator is preparing at that moment (a request's checkout can run for
  seconds to a minute): authority goes at once with the record, and the launch in flight fails its
  claim and starts no worker. The checkout in flight still finishes and saves its folder on the task
  (4d's rule), so the task gets its worktree. Take Over therefore starts no checkout of its own when
  one is in flight, and reports nothing. The test 2f added for this case must keep passing.
- A taken-over task without a checkout whose checkout failed stays an ordinary row without a worktree;
  choosing it reports the missing worktree as for any task; Remove handles a row without a checkout.
- Conversations only an extra tab's record named (never shown in the task's window) are not resumed,
  as today.
- `OperatorActivityTracker` no longer shows "releasing <task>": Take Over is not the Operator's act.

## Tests

Delete, each with its survivor:
- `ItermFocusControllerTests.aTakenOverWindowOpeningFollowsTheLatestClick`: phase 3's latest-click
  test for an ordinary task covers the same guard. `aTakenOverTaskChecksForALiveWindowBeforeResuming`:
  phase 3's "a tagged window is adopted" journey.
- `SignalOperatorIssueTests.aTakeOverWhoseJournal…` (as 2f left it): behaviour deleted.
- `SignalDomainTests`: the `.takeOver` transition expectations (about lines 256 and 284); behaviour
  deleted, replaced by the Core tests below.

Rewrite:
- `ItermFocusControllerTests.clickingATakenOverTaskOpensItsWindowAndBringsItermForward`: Take Over
  (through `controller.takeOver`) then choose. `notStarted`/`queued`: Take Over makes the worktree on
  the task branch; `shell`: the window opens with no command; `conversations`: both resume with plain
  commands (`guardedWorkerCommand` finds none) and no new scope is written. iTerm2 comes forward once.
- `aTakenOverRequestOpensItsSourceBranchAndRefusesAFork`: Take Over of the request task checks out the
  source branch; a fork is refused with the banner and leaves no checkout.
- `SignalControllerTests.takeOverRevokesTheStageAndWithdrawsItsQuestions`: a controller test through
  `AppController.takeOver`: record gone, mark set, questions gone, recorded scope ownership raised,
  toast shown.
- Every test that simulated Take Over by setting `takenOver` (and `ownership += 1`) applies
  `AppState.takeOver` instead: `SignalSidebarTests`, `SidebarRowRedrawTests`, `SignalEngineTests`,
  `SignalQuestionRoundsTests`, `SignalToolHandlerTests`, `SignalAgentChoiceTests`, `SignalWorkerIOTests`.
- Core `OperatorIssuesTests`: use another source where it used `.takeOver`.

Add (Core): `AppState.takeOver` removes the record, sets the mark, opens the project, withdraws the
task's questions and paused workers, and returns the record; `MatchDecision` gives no decision for a
marked task matching by ticket and by request, live or archived; the mark round-trips and is absent
from a task that has none.

Fixture: add one taken-over task to the `SignalSavedFormatTests` builder, then re-record with
`AITERM_RECORD_SIGNAL_STATE=1 scripts/test.sh swift -- --filter SignalSavedFormatTests`, check the
diff (every `"takenOver" : false` inside a record gone, one `"takenOver" : true` on the new task),
and add to `operator-signals/PROVENANCE.md`: "Re-recorded in step 4e of the greenfield refactor: Take
Over removes a task's signal record and marks the task `takenOver`; `signalTask` no longer has a
`takenOver` key."

## Proof

- `scripts/test.sh swift -- --filter SignalSavedFormatTests` (normal run, after re-recording), then
  `SignalDomainTests`, `SignalEngineTests`, `SignalControllerTests`, `ItermFocusControllerTests`,
  `SignalSidebarTests`, `SidebarRowRedrawTests`, `SignalToolHandlerTests`, `SignalAgentChoiceTests`,
  `SignalQuestionRoundsTests`, `SignalWorkerIOTests`, `WorkerGuardLaunchTests`, `OperatorIssuesTests`,
  `SignalJourneyTests`.
- `scripts/snapshots.sh build/4e`: the "taken-over" pose and every other PNG equal to 4d's.
- Plain `scripts/test.sh`.

## Done when

- `grep -rn "takenOver" app/Sources` finds only `TaskItem`'s mark and its coding, `AppState.takeOver`,
  `MatchDecision`, `TaskLauncher.takeOver` and `AppController+Signals`.
- `grep -rn "takeOver" app/Sources` finds only `AppState.takeOver`, `TaskLauncher.takeOver`,
  `AppController+Signals.takeOver` and the row menu's call to it.
- `grep -rn "openTakenOver\|takenOverResumeCommands\|takenOverOpenings\|apply(.takeOver" app` returns
  nothing.
- The fixture is re-recorded with its provenance line; the suites, snapshots and plain
  `scripts/test.sh` are green; `docs/operators.md` says what Change 10 says.

## Not in this step

- One Core accessor for "this task is under the Operator": 8a.
- The `.stopped` phase: 5a. The controller's other owners: 5d.
- The release notes' reset command: 9b.
