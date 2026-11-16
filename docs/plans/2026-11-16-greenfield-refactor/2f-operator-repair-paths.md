# 2f. Operator repair paths: one attempt, one reported issue

Implementer: Codex `gpt-6.1-sol`, high. Depends on: phase 1 (1d, 1e and 1h removed dead Operator
members and `normalizeEarlierChoiceBlocks`; 1j renamed the vocabulary), and 2a to 2e before it in
phase 2. Audit: RT F10.

## Why

The Operator's app side grew recovery machinery for failures that do not plausibly happen on one
person's Mac: an in-memory queue of up to 200 activity-log entries rewritten in order after a failed
write to AiTerm's own support folder; a Take Over whose guard refresh and journal line are retried on
every reconcile; a runtime copy of the saved source failures kept only to avoid writing the same
reason twice; a read of a task's ticket
and request descriptions with its own timeout, in-flight sharing and a ten-field cache key; and a
launch recovery that reads the guard's scope file and compares five fields before adopting a worker.
Each of these has a simpler correct form. The end state: where a queue or repair loop goes, the
action is tried once and a failure is reported once through the existing `OperatorIssues` tracking;
where a mirror or cache exists, the saved state or a short cache answers. No saved format, wire or
tool contract changes.

## Today

Read `app/Sources/AiTerm/Operators/SignalOperatorController.swift`, `SignalWorkerIO.swift` and
`SignalHostIO.swift` completely first. Line numbers are from before phase 1.

- **Activity log.** `SignalOperatorController.recordActivity` calls `writeActivity(_:)` (about line
  321), which chains a job after `lastActivity`, writes `unwrittenActivity` plus the new entry
  through `ActivityLog.append`, keeps what failed (`unwrittenActivityLimit` 200), then calls
  `fail(.activity, ...)` or `succeed(.activity)`. `record(_:)` (about line 347) writes each
  `OperatorIssues.Transition` to the log, except an `.activity` start or change, which it parks in
  `unwrittenActivity`. `reconcile()` calls `writeActivity(nil)` when entries are parked.
- **Take Over.** `takeOver(_:)` (about line 748) saves `takenOver`, the ownership bump and the
  withdrawn questions, flushes, then sets `takeOverRepairs[id]` and calls `repairTakeOver(_:)`
  (about line 764): it rewrites each recorded guard scope with the new ownership
  (`WorkerGuardLaunch.recordedScope`, `prepare`) and appends "The person took over this task." to
  the journal; each failure is `fail(.takeOver, ...)`, and what failed stays in `takeOverRepairs`
  for `reconcile()` to retry; when none remain, `succeed(.takeOver)`. `keeper.finished`'s comment
  mentions those repairs.
- **Source failures.** `sourceErrors: [UUID: String]` (about line 15) is filled in `init` from
  `operatorSession.sourceFailures`, written in `poller.onFailure` (only when the reason changed:
  saved, logged as `signal_read`, `wake(.signalFailed)`), cleared in `poller.onPass` and filtered
  in `prune()`. Nothing else reads it: `rg -n "sourceErrors" app/Sources` lists only the
  controller.
  `SignalSidebar`, `SidebarProjection` and `OperatorDigest` read the saved `sourceFailures`.
- **Late checkout save.** `SignalWorkerIO.prepare` (about lines 191 to 197): after the checkout, if
  the claim no longer holds (Take Over came during it) and the task has no checkout, it saves the
  worktree path and base branch anyway. No test covers it
  (`rg -n "late completion|made before Take Over" app/Tests` is empty). **It stays** (see Keep):
  the audit listed it as speculative, but a review of the plan showed what it prevents.
- **Details read.** `SignalHostIO.details(_:)` (about line 137) builds a `DetailBasis` (claim,
  Jira and request refs, watched request, branch, remote, three connection configs, the URL
  session's identity), serves `detailsCache` within `hostCache`, joins a `DetailFlight` in
  progress, else runs `uncachedDetails` in a task group raced against `hostTimeout`, rechecks the
  claim and remote, caches and returns. `cancelReads()` is called from the controller's `stop()`.
  `hostTimeout` and `hostCache` are set from `OperatorPorts.hostTimeout`/`hostCache`
  (`OperatorTiming.hostReadTimeout` 8 s, `hostReadCache` 30 s). Only caller: the controller's
  `tools` read port, which turns an error into `sourceError`.
- **Launch recovery.** `SignalWorkerIO.recoverLaunches()` (about line 67), called by `reconcile()`:
  for a task in `launching` or `blocked` with `launch.workerPending`, no `openedAt`, a live tab
  tagged with it, no stage run in progress (`recoveryAllowed`) and not in flight, it reads the
  guard scope off the main actor, rechecks the claim, then adopts the first worker (window, edge,
  phase `working`, `openedAt`, conversation) when its agent is the task's and the scope's task,
  ownership, stage, worktree and branch all match; otherwise it blocks with "A terminal is already
  open from an interrupted launch. Inspect it before resuming this stage."
- Issue tracking: Core `OperatorIssues` (one issue per source; `.activity` is retried, so it needs
  you after three failures in a row; `.takeOver` needs you at once), surfaced as the Operator row's
  "needs you", the activity log and `run_status`'s `appIssues`.

## Change

1. **Activity log: one attempt per entry.** `writeActivity` takes a non-optional entry. It keeps
   the `lastActivity` chain (entries land in the order they were recorded) and writes that one
   entry; success is `succeed(.activity)`, failure `fail(.activity, "Its activity could not be
   saved: " + reason)`. The entry that failed is dropped. Delete `unwrittenActivity`,
   `unwrittenActivityLimit` and the `writeActivity(nil)` line in `reconcile()`. `record(_:)` writes
   every transition except an `.activity` start or change, which it does not write (that write would
   fail too); the `.activity` recovery is written. Fix both doc comments.
2. **Take Over: one attempt.** After its flush, `takeOver(_:)` refreshes the guard scopes and
   appends the journal line once, inline. Each failure calls `fail(.takeOver, ...)` with today's
   sentence; when both steps succeed it calls `succeed(.takeOver)`. Delete `takeOverRepairs`,
   `TakeOverRepair`, `repairTakeOver(_:)` and its loop in `reconcile()`; fix the `keeper.finished`
   comment.
3. **Source failures: the saved record only.** Delete `sourceErrors` and its `init` load. In
   `poller.onFailure`, the "same reason" check reads `operatorSession?.sourceFailures?[id.uuidString]`;
   everything after it (create the session record when missing, save, log `signal_read`, wake) is
   unchanged. In `onPass`, only the saved entry is cleared. In `prune()`, delete the
   `sourceErrors = ...filter` line; the saved filter stays.
4. **Late checkout save: unchanged.** Leave the block in `SignalWorkerIO.prepare` that saves the
   worktree after the claim was lost exactly as it is. Add the test named under Tests so it is no
   longer uncovered.
5. **Details: a short cache by task and claim.** `SignalHostIO.details(_:)` keeps one private
   dictionary from task id to (claim, value, time). A hit is an entry for this task whose claim
   equals `SignalClaim(task)` and whose age is under `OperatorTiming.hostReadCache`. A miss calls
   `uncachedDetails` directly; afterwards, if the claim no longer holds in the workspace it throws
   today's "The task changed while its source was read.", else it stores and returns the value.
   Entries for tasks that are no longer signal tasks are dropped on each call, as today. Delete
   `DetailBasis`, `DetailCache`, `DetailFlight`, `detailFlights`, the task group and its timeout,
   `cancelReads()` (and its call in the controller's `stop()`), `hostTimeout`, `hostCache`,
   `OperatorPorts.hostTimeout`/`hostCache`, the controller line that copies them, and
   `OperatorTiming.hostReadTimeout`. Reword `hostReadCache`'s comment to "how long `read_task` keeps
   a task's source descriptions".
6. **Launch recovery: a tagged tab with the planned agent, else block.** In `recoverLaunches`, drop
   the scope read, `BackgroundWork` and the recheck after it. Keep the outer guard (enabled,
   workspace changeable, `recoveryAllowed`, not in flight, a claim exists, the pending-launch and
   phase conditions, a live tab tagged with the task). Adopt when `task.firstWorker(in:)` exists and
   runs `task.agent`; otherwise block as today. With no await left, make it a plain synchronous
   method and drop the `await` at its call site in `reconcile()` and in the test.
7. In `docs/operators.md`, the sentence "Every failure and recovery is written to the Operator's
   activity log..." gains: a failure to write the log itself is not written, only its recovery.

## Keep

- `OperatorIssues` and its rules (retried sources need you after three failures; a clicked action
  at once), the row's "needs you", the `app_issue` log lines and `appIssues` in `run_status`.
- The `lastActivity` chain: it keeps log lines in order for `run_status` readers.
- Take Over's saved mutation, flush, guard refresh and journal line: only their retry goes. The
  guard refresh raises the recorded ownership so a late Operator launch cannot overwrite it.
- `poller.onFailure`'s wake and `signal_read` log line on a new reason; `sourceFailures` in the
  saved session (the sidebar and `run_status` read it).
- `SignalHostIO.binding` and every origin and repository check before a host read or merge: merge
  safety. `merge`, `read`, `additionalContext`, `deleteMergedBranch` are untouched.
- `recoverLaunches`' outer guards and its block sentence; the stage runner's `isRunning` check
  (`recoveryAllowed`): a launch in progress is not a lost one.
- `SignalClaim`: the one value that makes late completions safe.
- The late checkout save in `SignalWorkerIO.prepare`. A person can press Take Over while a
  request's branch is still being fetched and checked out, which takes seconds to a minute. The
  checkout finishes after the claim is lost. Without the save the task has no folder; opening it
  then runs the taken-over request checkout (`prepareTakenOverRequest`, which adds a worktree for
  the same branch), and git refuses because that branch is already checked out in the worktree the
  interrupted checkout made. The task would be stuck until someone fixes it by hand.

## Decisions already taken

- A Take Over whose guard refresh or journal line fails shows "Take Over: ..." as needs you until
  the next Take Over succeeds or AiTerm relaunches (issues are runtime). Its task is the person's
  either way; the next worker launch prepares its guard again.
- An activity entry whose write failed is lost. The issue clears at the next entry that is written.
- An unchanged source failure seen after relaunch is not logged or woken again: the saved record
  answers, as the loaded mirror did.
- Take Over during a checkout: the finished checkout's folder is still saved on the task, as today.
  Do not replace the save with a lookup of an existing worktree; step 4d gives every checkout one
  path and decides then.
- Two `read_task` calls for one task at the same moment each read the host. A host that hangs is
  bounded by the clients' own 15 s request timeout; a call that outlives the daemon's request
  timeout is retried by the Operator and replayed from the ledger.
- A connection or remote changed in Settings can serve descriptions up to 30 s old. Accepted.
- A tagged tab whose agent differs from the task's blocks the stage. One with the planned agent is
  adopted whatever its guard scope says: the ownership changes only through Take Over, which
  removes the claim, so recovery never reaches such a task; a stage change cannot happen while a
  launch is pending.

## Tests

- Adjust `SignalOperatorIssueTests.anUnwrittenActivityEntryLandsLaterWithItsOwnTimeAndTheWriteFailureIsLogged`:
  rename to `aFailedActivityWriteIsReportedAndTheNextWrittenEntryClearsIt`. With the log path a
  folder, a failing wake reports `.activity`; after removing the folder, an Operator tool call
  (`r.request("run_status")`) writes an entry, `.activity` clears, "The Operator's activity log
  recovered." is in the log, and "Waking the Operator failed." from the failed pass is not.
- Adjust `aTakeOverWhoseJournalCannotBeWrittenShowsAtOnceAndIsRepairedOnTheNextPass`: rename to
  `aTakeOverWhoseJournalCannotBeWrittenShowsAtOnce`; keep "shows at once" and "opening the Operator
  starts no chat"; after the folder is fixed a pass does not write the journal line and the issue
  stays.
- Adjust `SignalWorkerIOTests.anInterruptedLaunchAdoptsItsGuardedWorkerWithoutRepeatingThePrompt`:
  the argument becomes whether the tagged tab runs the task's agent (`.claude`) or another
  (`.codex`, via `OperatorServiceFixtures.session(..., agent:)`); no scope file is written; adopted
  versus blocked as before; no daemon request either way.
- Delete `SignalHostIOTests.aStatusReadHasItsOwnBudgetAndNeverCachesATimedOutAnswer` (behaviour
  deleted). `repeatedStatusDetailsReuseTheHostReadButAChangedAuthorityDoesNot` stays unchanged: it
  proves the cache by claim.
- Add, test first, in `SignalControllerTests`: "a source that keeps failing with one reason is saved,
  logged and wakes once; a new reason does it again; a pass clears it" (call `poller.onFailure` and
  `poller.onPass` on a started controller; read `sourceFailures` and the activity log).
- Add, in `SignalWorkerIOTests`: a Take Over that lands while a request task's checkout is running
  leaves the task with the finished checkout's folder and base branch, and no worker is launched
  (hold the checkout with a latch at the git port, take over, release, then read the task).
- No fixture changes.

## Proof

- `scripts/test.sh swift -- --filter 'SignalOperatorIssueTests|SignalControllerTests|SignalWorkerIOTests|SignalHostIOTests|OperatorIssuesTests|SignalJourneyTests'`
- Then plain `scripts/test.sh`, started in the background.

## Done when

- `rg -n "unwrittenActivity|takeOverRepairs|TakeOverRepair|repairTakeOver|sourceErrors|DetailBasis|DetailFlight|detailFlights|cancelReads|hostTimeout|hostReadTimeout" app/Sources app/Tests/AiTermTests/Operators` returns nothing (`UpdateCheckTests.sourceErrorsPassThrough` is unrelated).
- `rg -n "recordedScope" app/Sources/AiTerm/Operators/SignalWorkerIO.swift` returns nothing.
- `rg -n "hostCache" app/Sources` returns nothing.
- The suites above and plain `scripts/test.sh` are green; the `docs/operators.md` sentence updated.

## Not in this step

- Moving the activity writer, wake policy and chat I/O out of the controller: 5d.
- Take Over as an ordinary task, removing `takenOver` and its opener: 4e.
- The 180-second grace, `busy` with a side effect, one tick: 5e. Every phase change through the
  stage machine (the edge written by recovery): 5a.
- One `HostRepository` and the single status read: 7a, 7c.
