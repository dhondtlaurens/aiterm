# 5b. A task's record holds its current stage whole

Implementer: Opus 5.5 high. Depends on: phases 1 to 4 and 5a (no `edges`, no `stopped`, one
`SignalClaim.allows(in:)`). Audit findings: OC F7 part b (with the duplicated pending-question rule
named there).

## Why

A driven task's saved record (`SignalTask`) repeats the four fields of a stage (`signal`, `item`,
`configuration`, `prompt`), and continuing to the next stage copies them over one by one.
`configuration`, the stage's snapshot of the signal it runs under, is optional, although every
producer has set it since the first signal commit. So about seventeen call sites read
`record.configuration ?? state.signal(id: record.signal)`, three more read `configuration` alone,
and the two readings could disagree. The question "is this Operator question still pending" is also
written twice. End state: `SignalTask.current` is a `SignalStage` held whole, its `configuration` is
never missing, continuing a stage assigns the pending stage, every reader asks
`record.current.configuration`, and one `OperatorSession.Question.isPending` answers the pending
rule. Behaviour does not change: a running stage still uses the configuration it started with, and a
removed signal's tasks still carry on under it. A wrong change starts reading the live signal where
the stage's snapshot was read, or keeps a fallback.

## Today

As the code stands after phases 1 to 4 and 5a. Re-run each grep first.

- Core `Operators/Signals/SignalStage.swift`: `signal`, `item`, `configuration: Signal?`,
  `prompt: String?`, `matchedAt`.
- Core `SignalTask.swift`: `signal`, `item`, `configuration: Signal?`, `prompt: String?` beside the
  stage-scoped fields (`candidateProjects`, `choosableRows`, `choice`, `phase`, `stage`,
  `startedAt`, `pendingStages`, `pendingReplies`, `launch`, `extraTabs`, `watchedRequest`,
  `waitingOn`, `thenApplied`, `operatorJudged`, `currentAct`, `ownership`, `blockedReason`,
  `journal`). `init(signal:item:startedAt:)`. Codable is synthesized.
- Core `SignalTransitions.apply`, local `continueStage(_:)`: copies `signal`, `item`,
  `configuration`, `prompt` from the stage, then resets the rest.
- Core `MatchDecision.decide` builds `SignalStage(signal:item:matchedAt:)` without a configuration,
  although it holds the matching `Signal` in its `signals` argument.
- App `ItemRouter.apply`: local `configured(_:)` sets `configuration = state.signal(id:)` and the
  prompt from the read's item; `.continueTask` builds a new record for a task with no record and sets
  `configuration` and `prompt` by hand; `makeTask` does the same.
- The fallbacks: `rg -n 'configuration \?\?' app/Sources`. Expected sites: `StageRunner` (run,
  resume, choose, finish), `SignalHostIO` (read, additionalContext), `SignalWorkerIO.command`,
  `ThenRunner.apply`, `SignalClaim.allows`, `RequestWatch.pass`, the tool handler's calls (open_tab
  rows, finish_stage, choose_agent need, `choice(_:task:)`), `ItemRouter.apply`
  (`startingConfiguration`), Core `OperatorDigest` and `AppState.operatorMayStartWork`. Readers of
  `configuration` alone: `rg -n '\.configuration\b' app/Sources | grep -v '??'`; among them
  `SignalHostIO.merge` and `deleteMergedBranch`, `SignalWorkerIO.launch` (the fallback-row switch),
  `SignalSidebar.init` (a removed signal's heading), `SidebarProjection.refresh` (the drawn copy),
  `AppController.toggleCollapsed` (folds a removed signal by writing its saved configuration) and
  the snapshot fixtures.
- Core `TaskItem.prepareLaunch(configuration:candidates:at:)` and `choiceNeed(configuration:)`: every
  caller passes the record's own configuration.
- Constructors: `rg -n 'SignalTask\(signal' app` (about thirty sites in sources, snapshots, tests and
  `AiTermTestSupport/SignalWorld.swift`); `rg -n 'SignalStage\(' app`.
- The pending-question rule ("open, or a worker question answered and not yet delivered") is written
  in `OperatorDigest.init` (the `questions` filter) and `OperatorSession.prune` (local `pending`).
- Tests that pin the saved shape: `SignalSavedFormatTests` with
  `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json`.

## Change

1. `SignalStage.configuration` becomes a non-optional `Signal`; its initializer requires it.
2. `SignalTask` replaces `signal`, `item`, `configuration` and `prompt` with `current: SignalStage`.
   Its initializer takes the current stage and `startedAt`. Add no forwarding properties: every
   reader writes `record.current.signal`, `record.current.item`, `record.current.configuration`,
   `record.current.prompt`. `startedAt` (when this stage started) stays on `SignalTask`; `matchedAt`
   (when its item matched) is the stage's.
3. In `continueStage`, assign the stage to `current` and keep every other reset as it is.
4. `MatchDecision.decide` gives each stage it produces the matching signal as its configuration, for
   `.start`'s pending stages and for `.continueTask`. `ItemRouter`'s `configured` then only fills the
   prompt; the `guard let signal = stage.configuration` goes; a task with no record gets
   `SignalTask(current: stage, startedAt:)`; `makeTask` builds its record from a stage the same way;
   `startingConfiguration` becomes `record.current.configuration`.
5. Every fallback and every lone read listed under Today reads `record.current.configuration`. The
   `guard let` branches that only existed for a missing configuration go with their refusals ("Its
   signal is missing." in `SignalHostIO.read`, "The task's signal is missing." in `finish_stage`):
   they are unreachable.
6. `TaskItem.prepareLaunch` and `choiceNeed` read the record's own configuration and lose the
   parameter; `StageRunner.finish`, `ItemRouter` and the tool handler stop passing it.
7. `OperatorDigest.TaskLine` is filled from `current`; its JSON keys (`signal`, `item`, `prompt`,
   `finish`, `permittedAgents`) and `PendingLine` stay exactly as they are, so `run_status` does not
   change.
8. `SidebarProjection.refresh` builds its drawn copy's `current` from the record's signal and
   configuration with an unknown item, `.distantPast` as `matchedAt` and no prompt (it already
   blanks the item and the start time so they cannot cause a redraw). `SignalSidebar` reads
   `record.current.configuration` for a removed signal. `AppController.toggleCollapsed` writes
   `current.configuration.collapsed`.
9. Add `OperatorSession.Question.isPending` (Core) with today's rule; `OperatorDigest` and
   `OperatorSession.prune` use it.
10. Update the snapshot fixtures (`SignalSidebarSnapshots`, `ReadmeDesktop`) and
    `AiTermTestSupport/SignalWorld.workingTask` to build records through a stage.

## Keep

- The stage snapshot: a running stage reads the configuration it was started with, never the live
  signal. Editing a signal changes only stages that start later; removing a signal leaves its tasks
  running "with their saved instructions" (`docs/operators.md`).
- Reads of the live signal that ask about the person's current switch, not the stage's instructions:
  `SignalClaim.allows` (`state.signal(id:)?.enabled != false`), `SignalPauseSignaller.paused`,
  `operatorMayStartWork`'s enabled check, `SignalSidebar`'s list of definitions,
  `SignalHostIO.deleteMergedBranch`'s save check. They stay on `state.signal(id:)`.
- `prompt` stays optional with its existing `?? configuration.work.prompt` reading in
  `StageRunner.run`; making it required is not this step.
- Field names in `run_status` and the digest; `SignalTask` keeps synthesized Codable.
- `PreservedFields`, `.unknown` cases and lenient raw decoding elsewhere in the workspace.

## Decisions already taken

- Saved shape: under each task's and archived task's `signalTask`, the keys `signal`, `item`,
  `configuration` and `prompt` move into `current` (with `matchedAt`). Only `signalTask` changes,
  which the plan allows. No migration and no second decoding: a record in the old flat shape no
  longer decodes, and the release notes' reset command removes every `signalTask` before upgrading.
  Do not add a custom decoder, a `try?` decode or a default.
- A pending stage saved without a configuration cannot exist after this step; the same reset rule
  covers older saves.
- A match for a signal removed between the read and the route cannot happen: `MatchDecision` only
  makes stages for the runnable signals it is given.
- `SignalStage` equality now includes its configuration; `.matched` still deduplicates queued stages
  by `signal` alone, as today.
- The deleted refusals were unreachable; nothing replaces them.

## Tests

- Mechanical: every constructor under Today, `SignalStatusBudgetTests` (`$0.item = item` becomes
  `$0.current.item = item`), tests that set `record.configuration` or read `signalTask?.signal`.
  `SignalDomainTests` builds `SignalStage` values with the helper's `signal()` as configuration. No
  assertion changes except the shape-specific ones below.
- Add to `SignalDomainTests`: continuing a stage makes the first pending stage the current one whole
  (its signal, item, configuration and prompt), with the stage number and ownership one higher;
  `MatchDecision` gives a started item's pending stages and a continued task's stage their signal's
  configuration.
- Add a Core test for `Question.isPending`: an open question; a resolved worker question with an
  answer not delivered (pending); the same once delivered (not pending); a resolved question that
  was not a worker's (not pending).
- `SignalSavedFormatTests`: keep its expectations; re-record
  `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json` with
  `AITERM_RECORD_SIGNAL_STATE=1 scripts/test.sh swift -- --filter SignalSavedFormatTests`, read the
  diff (only the `signalTask` records may change: the four keys move under `current` with
  `matchedAt`), and add to `PROVENANCE.md`: "5b (greenfield refactor): re-recorded; a task's record
  holds its current stage whole under `current`, with a configuration that is always present."

## Proof

- While iterating: `scripts/test.sh swift -- --filter SignalDomainTests`, then `SignalSavedFormatTests`,
  `SignalFreshDigestTests`, `SignalStatusBudgetTests`, `SignalRetentionTests`, `SignalEngineTests`,
  `SignalAgentChoiceTests`, `SignalWatchTests`, `SignalHostIOTests`, `SignalWorkerIOTests`,
  `SignalToolHandlerTests`, `SignalControllerTests`, `SignalAutomaticCleanupTests`,
  `SidebarProjectionTests`, `SidebarRowRedrawTests`, `ModelsTests`, `WindowPlanTests`,
  `ItermFocusTests`.
- The drawn copy changes: run `scripts/snapshots.sh build/5b-before` before you change anything and
  `scripts/snapshots.sh build/5b-after` at the end, and compare every signal sidebar and Operator
  row PNG: equal pixels. (Earlier phases changed some views on purpose, so compare with your own
  before capture, not with `build/refactor-before`.)
- Then plain `scripts/test.sh`, started in the background.

## Done when

- `rg -n 'configuration \?\?' app/Sources` is empty.
- `rg -n 'record\.signal\b|record\.item\b|record\.configuration\b|record\.prompt\b|signalTask\??\.(signal|item|configuration|prompt)\b' app/Sources`
  is empty (every reader goes through `current`).
- `rg -n 'var configuration: Signal\?' app/Sources` is empty.
- `rg -n 'deliveredAt == nil' app/Sources/AiTermCore` shows only `Question.isPending`.
- The suites above and plain `scripts/test.sh` are green; the fixture and its provenance line are in
  the change; the snapshots match.

## Not in this step

- The Oracle owner and its saved rounds: 5c. Splitting the controller and moving retention to Core:
  5d. `currentAct` leaving the saved record: 5f.
- Regrouping `Signals/` into about fourteen files and the kind-tagged enum helper: 5h.
- Making `prompt` required; the sidebar's row values that stop copying `SignalTask`: 8b; the
  removed signal's fold no longer written into task records: 8c.
