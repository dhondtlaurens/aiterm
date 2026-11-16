# 5a. Every phase change goes through the stage machine; one claim check

Implementer: Opus 5.5 high. Depends on: phases 1 to 4, in particular 1h (the earlier choice-block
upgrade is gone), 2f (launch recovery is "a tagged tab with the planned agent, else block") and 4e
(Take Over removes the task's `signalTask`; there is no `takeOver` action and no `takenOver` field).
Audit findings: RT F5, OC F2 (the stage-machine half; the session lifecycle half is 5f).

## Why

A driven task's stage has one state machine, Core `SignalTransitions.apply`, which checks that an
edge is allowed and resets what the edge implies. Owners still write `phase` by hand in five places,
so a launch error can overwrite a stage that something else already blocked, and a recovered worker
is adopted without the machine having a say. The machine came with signals; the hand writes came
later with launch recovery and failed-launch detection, written beside it. It also kept a `stopped`
phase that no code can enter, a `stop` action nothing applies, and an edge log (`edges`) that is
saved, trimmed twice and never read. Separately, every effect owner spells its own "may I still act"
conjunction of workspace, pause, signal on, claim and cancellation; the pause check alone appears
about thirteen times. End state: no `phase` assignment outside `SignalTransitions`, two new actions
for the two edges that had none (a launch that failed, a worker recovered after a lost launch
reply), no `stopped`, `stop`, `SignalEdge` or `edges`, and one `SignalClaim.allows(in:)` that every
effect owner asks. Nothing a person or the Operator sees changes. A wrong change adds a guard, a
fallback write, or a second way to decide authority.

## Today

As the code stands after phases 1 to 4. Re-run each grep first.

- Core `Operators/Signals/SignalTransitions.swift`, `apply(_:to:at:workerIsWorking:)`. Throws on an
  `.unknown` phase. Edges: `workerStarted` launching to working; `workRequested` from working, done
  or watching to working; `matched` continues or queues; `watch` and `finish` from working; `block`
  from an active phase (`TaskPhase.isActive`: launching or working); `needChoice` launching to
  choosing; `chosen` choosing to launching; `resume` blocked to launching; `archive` when
  `canRunThen`; `stop` to `stopped`. After every action it appends a `SignalEdge` when phase or
  stage changed and trims `edges` to `SignalTask.edgeLimit` (100).
- `SignalAction.swift`, `TaskPhase.swift` (cases include `stopped`; decoding maps an unknown kind to
  `.unknown(raw)`), `SignalEdge.swift`, `SignalTask.edges`, `SignalTask.edgeLimit`. If
  `SignalAction.takeOver` or `SignalTask.takenOver` still exists, 4e is not done: stop and report.
- Grep for direct writes: `rg -n 'phase = ' app/Sources --glob '!**/Snapshots/**'`. Expected hits
  and what each becomes:

| Site | From phase | Becomes | Machine allows it today? |
| --- | --- | --- | --- |
| `StageRunner.run`, the `catch` (about line 84): blocked, reason, `currentAct = nil` | launching | new `.launchFailed(reason)` | Only through `.block`, which also accepts working; no action names it |
| `SignalWorkerIO.recoverLaunches`, adopt branch: hand-appended edge, working, `launch.openedAt`, `workerPending = false`, `currentAct = nil`, `blockedReason = nil` | launching, or blocked with a pending unopened launch | new `.adopted` | No: `workerStarted` only leaves launching and clears neither the reason nor the launch fields |
| `SignalWorkerIO.recoverLaunches`, block branch ("A terminal is already open from an interrupted launch...") | launching (the branch skips blocked) | `.launchFailed(reason)` | Through `.block` |
| `SignalWorkerIO.refreshTurns`, failed opening ("Its worker did not start after its saved launch...") | active (`needsWorkerReads`) | `.block(reason)` | Yes while still active |
| `SignalWorkerIO.refreshTurns`, unanswered saved message ("Its worker has not replied to the saved message...") | active | `.block(reason)` | Yes while still active |
| `ItemRouter.apply`, `.continueTask`, the `else` that blocks with `AgentChoiceNeed.unavailableReason` | launching | deleted: unreachable | n/a |
| Core `TaskItem.prepareLaunch` (`TaskItem+AgentChoice.swift`), the `.unavailable` case | launching (guarded) | `.block(AgentChoiceNeed.unavailableReason)` | Yes |

  The `ItemRouter` branch is unreachable: a stage reaches `.launching` there either as a new record
  (configuration set from the matched signal) or through `.matched`, which installs a stage whose
  configuration `configured` set from a signal that just matched (the `guard let signal =
  stage.configuration` above it). `SidebarProjection.refresh` sets `visible.phase` on a drawn copy;
  that is not a state write and stays. Snapshot fixtures under `Snapshots/` stay.
- `.stopped` readers: `rg -n '\.stopped\b|case stopped|"stopped"' app/Sources/AiTermCore/Operators app/Sources/AiTerm/Operators app/Sources/AiTerm/SignalSidebar.swift app/Sources/AiTerm/AppController+Operators.swift`.
  Hits: `SignalClaim.canAct`, `SignalTask.keepsOperatorSession`, `AppState.isCurrentOperatorQuestion`
  and `operatorMayStartWork`, `SignalSidebar` (the held filter and the status switch),
  `AppController.reveal`, `TaskPhase` itself. Only tests apply `.stop`
  (`rg -n 'apply\(\.stop' app`). `TaskRemoval.stopped`, `HelperLink` and `DaemonSupervisor` have
  unrelated `.stopped` cases: leave them.
- Edge readers: `rg -n 'SignalEdge|\.edges\b|edgeLimit' app/Sources app/Tests`. Sources: the
  machine, `recoverLaunches`, and `SignalOperatorController.prune` (trims `edges`). No reader in the
  digest, `run_status`, the sidebar or `read_task`.
- `SignalClaim` (app, `Operators/SignalClaim.swift`): task, signal, stage, ownership. `holds(in:)`
  compares identity. `canAct(in:)` adds: not paused, live signal not switched off, phase not unknown
  (and not stopped), stage configuration supported and valid. No test names it.
- Repeated authority checks: `rg -n 'paused != true|canAct' app/Sources/AiTerm/Operators`. Each
  owner adds its own conjunction: `StageRunner.run`, `resume`, `choose`, `finish` and `holds`;
  `ThenRunner.apply` and its `allowed`; `RequestWatch.pass` and `allowed`; `SignalHostIO.merge`;
  `SignalWorkerIO.require`; `AgentChoiceRounds.decide`; `QuestionRounds.answer` and its
  `stillAsks`; the tool handler's `perform` and its `allowed`.
- Tests: `SignalDomainTests` (transitions), `SignalRetentionTests.repeatedStagesRetainOnlyTheNewestTransitionTail`,
  `SignalWorkerIOTests` (`anInterruptedLaunchAdoptsItsGuardedWorkerWithoutRepeatingThePrompt`,
  `anAcceptedLaunchWithoutAWorkerEventuallyRequiresInspection`, `anApiFailureBlocksTheStageInsteadOfReusingAnEarlierQuestion`),
  `SignalEngineTests`, `SignalOperatorLifetimeTests.completedTasksAndTheirOldQuestionsCannotKeepNeedsYouVisible`
  (takes `.stopped` as an argument), `SidebarProjectionTests.journalEdgesAndReplyIntentsDoNotDeriveOrInvalidateDrawnRows`
  (appends an edge), `SignalSavedFormatTests` and the `operator-signals/state.json` fixture (holds
  `"edges" : []`).

## Change

1. In `SignalTransitions.apply` add two actions to `SignalAction`:
   - `launchFailed(String)`: allowed only from `.launching`; sets `.blocked`, the reason, clears
     `currentAct`. Any other phase throws `invalidEdge`.
   - `adopted`: allowed from `.launching`, and from `.blocked` only when `launch.workerPending ==
     true` and `launch.openedAt == nil` (a launch whose reply was lost). Sets `.working`, clears
     `blockedReason` and `currentAct`, sets `launch.openedAt` to `at` and `launch.workerPending` to
     false. Anything else throws `invalidEdge`. Ownership does not change, as today.
2. Delete `SignalAction.stop`, `TaskPhase.stopped` with its decode and encode arms, `SignalEdge.swift`,
   `SignalTask.edges`, `SignalTask.edgeLimit`, the edge append and trim at the end of `apply`, and
   the trim loop in `SignalOperatorController.prune`.
3. Replace each direct write from the table. `StageRunner.run`'s catch keeps its existing guard and
   then applies `.launchFailed`; if the machine refuses because the stage is no longer launching,
   it writes nothing and does not call `changed`. `recoverLaunches` applies `.adopted` and still
   writes `windowId` and the conversation on the task itself; its block branch applies
   `.launchFailed`. The two `refreshTurns` sites apply `.block` only while the phase is active, the
   same `try?` shape the `stoppedOn` site beside them already uses; each keeps whatever else it wrote
   (the failed-opening site clears `currentAct`, the unanswered-message site does not). Delete the
   unreachable `ItemRouter` branch. `prepareLaunch` applies `.block`.
4. Remove `.stopped` from every switch and filter listed under Today; `.unknown` arms stay.
5. In `SignalClaim`, replace `canAct(in:)` with `allows(in workspace: WorkspaceStore) -> Bool`: the
   workspace can change, `holds`, not paused, the live signal not switched off, the stage
   configuration supported and valid, the phase not unknown, and the current task not cancelled.
   Every caller of `canAct` and every hand-written conjunction listed under Today asks `allows`
   instead and drops the parts it covers. What is not about the claim stays at its owner:
   `StageRunner.holds` keeps `isStopped`, its generation and `phase == .launching`; `ThenRunner`
   keeps `canRunThen` and `workerIsWorking`; `RequestWatch.allowed` keeps `workerIsWorking`;
   `SignalWorkerIO.require` keeps `enabled()`; `QuestionRounds.stillAsks` keeps the question and the
   Operator session checks; the tool handler keeps `requireSession` and, for read-only tools,
   `holds`. `RequestWatch.pass` keeps only its `running` guard at entry. `QuestionRounds.answer`
   drops the pause conjunct at entry; the handler's `requireSession` refuses a paused mutating call
   before it runs, and its later claim check covers a direct call.
6. Docs: in `docs/architecture.md`, "one hundred edges/snags" becomes "one hundred snags", and
   "stage edges" in the owners table stays. In `docs/operators.md`, drop "stopped" from "Completed,
   archived, stopped or taken-over tasks do not keep it" (keep whatever 4e left of the rest).

## Keep

- `.unknown` phase handling in the machine, the claim and the sidebar: the workspace tolerates what
  it does not know (dev builds and the installed app share one `state.json`).
- `SignalClaim.holds(in:)`: identity only, used where pause must not stop the work (clearing
  `currentAct` after an effect, worker reads, recovery, the read-only tools, the host details cache).
- Pause checks that are not claim checks: `requireSession` (the Operator session's authority),
  `SignalPauseSignaller.paused` (it acts because of the pause), `OperatorSessionKeeper`'s
  `allowPaused`, the controller's poller and reconcile gates, the save check in
  `SignalHostIO.deleteMergedBranch` (its task is already gone, so there is no claim),
  `AppState.operatorMayStartWork` (Backpack Mode) and `FreshStartPolicy`.
- `finish_stage`'s blocked and failed outcomes already reach the machine through
  `StageRunner.finish(.block)`.
- The `stoppedOn` block in `refreshTurns`: already through the machine.

## Decisions already taken

- A launch error that arrives after the stage moved on (blocked by `refreshTurns`, paused, taken
  over): the first reason stands. No write, no `changed`, no new issue.
- `.adopted` from a blocked stage without a pending unopened launch cannot happen through
  `recoverLaunches` (its filter requires both); the machine refuses it anyway.
- Two tabs of one task both past the grace in one `refreshTurns` pass: the first blocks the stage;
  the second finds it blocked and leaves it.
- A workspace saved earlier with `"stopped"` decodes it as `.unknown`, which the claim, the sidebar
  and `keepsOperatorSession` already treat as inert. No migration. An old `edges` key is ignored on
  decode and dropped on the next save.
- `allows` checks `Task.isCancelled`; owners that checked it beside `canAct` drop their copy. An
  entry point called from a cancelled task returns early, as `StageRunner.holds` already made it.
- Do not add a `TaskPhase.isLive` helper or merge the three "live phase" lists; that is not this step.

## Tests

- Delete `SignalRetentionTests.repeatedStagesRetainOnlyTheNewestTransitionTail`: the edge history is
  deleted. Its ownership count is covered by the resume test below.
- Adjust `SignalDomainTests`: drop the `edges.count` line in
  `activeStageQueuesFoldsAndPendingWorkOutranksThen`; in `blockResumeStopAndTakeoverRespectAuthority`
  (rename to `blockAndResumeRespectAuthority`) drop the `stop` lines and keep the ownership check;
  in `aStageWaitsInChoosingUntilTheOperatorChoosesThenLaunchesUnderANewOwnership` drop the `edges`
  and `stop` lines. Drop `.stopped` from the arguments of
  `SignalOperatorLifetimeTests.completedTasksAndTheirOldQuestionsCannotKeepNeedsYouVisible`. In
  `SidebarProjectionTests`, drop the appended edge and the word from the test's name.
- Add to `SignalDomainTests`: a launch failure is accepted only from launching; adoption is accepted
  from launching and from a blocked stage with a pending unopened launch, refused from a blocked
  stage without one, and leaves the stage working with its launch opened and no reason; a saved
  `stopped` phase decodes as unknown and round-trips.
- Add `SignalClaimTests` (app, `Operators/`): a current claim is allowed; it is not when the Operator
  is paused, its signal is switched off, the store has not loaded, its stage or ownership moved, its
  phase is unknown, or inside a cancelled task.
- Add to `SignalEngineTests` or `SignalWorkerIOTests`: a launch whose port first blocks the stage
  through the machine and then throws leaves the first reason.
- The moved writes stay covered by `anInterruptedLaunchAdoptsItsGuardedWorkerWithoutRepeatingThePrompt`
  (both arguments), `anAcceptedLaunchWithoutAWorkerEventuallyRequiresInspection` and
  `anApiFailureBlocksTheStageInsteadOfReusingAnEarlierQuestion`; they must pass unchanged.
- Re-record `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json` with
  `AITERM_RECORD_SIGNAL_STATE=1 scripts/test.sh swift -- --filter SignalSavedFormatTests` (the
  `edges` keys go) and add to its `PROVENANCE.md`: "5a (greenfield refactor): re-recorded; the
  unread `edges` history left the saved task record."

## Proof

- While iterating: `scripts/test.sh swift -- --filter SignalDomainTests`, then the same with
  `SignalClaimTests`, `SignalWorkerIOTests`, `SignalEngineTests`, `SignalAgentChoiceTests`,
  `SignalWatchTests`, `SignalToolHandlerTests`, `SignalQuestionRoundsTests`, `SignalControllerTests`,
  `SignalOperatorLifetimeTests`, `SidebarProjectionTests`, `SignalSavedFormatTests`.
- Then plain `scripts/test.sh`, started in the background. No view changes, so no snapshot capture.

## Done when

- `rg -n 'SignalEdge|\.edges\b|edgeLimit|apply\(\.stop|case stop\b' app/Sources app/Tests` is empty.
- `rg -n '\.stopped\b|"stopped"' app/Sources/AiTermCore/Operators app/Sources/AiTerm/Operators app/Sources/AiTerm/SignalSidebar.swift app/Sources/AiTerm/AppController+Operators.swift app/Tests/AiTermCoreTests/Operators app/Tests/AiTermTests/Operators`
  shows only the new decode test's input.
- `rg -n 'phase = ' app/Sources --glob '!**/Snapshots/**'` shows only `SidebarProjection.refresh`'s
  drawn copy.
- `rg -n 'canAct' app` is empty. `rg -n 'paused != true|paused == true|\.paused\b' app/Sources/AiTerm/Operators`
  shows only `SignalClaim.allows`, the tool handler's `requireSession`, `SignalPauseSignaller`,
  `OperatorSessionKeeper`, `SignalHostIO.deleteMergedBranch` and the controller.
- The suites above and plain `scripts/test.sh` are green; the fixture and its provenance line are in
  the change; the two doc lines are updated.

## Not in this step

- Making `configuration` non-optional, `SignalTask.current`, the `configuration ??` fallbacks: 5b.
- The Oracle uses and their in-flight markers: 5c. Splitting the controller: 5d.
- One in-flight set per task, `busy` without side effects: 5e.
- The session lifecycle flags (`startingFresh`, `finishing`, `handover`) and `currentAct` leaving
  the saved record: 5f.
- One Core rule for "this task is under the Operator", read by the sidebar: 8a.
