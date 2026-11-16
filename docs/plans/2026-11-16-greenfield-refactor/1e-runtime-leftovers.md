# 1e. Operator runtime leftovers

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1b (removes `OperatorPorts.publisher`) and 1d (removes
`OperatorPorts.finishReplyBudget`, `StallWatch.isQuietWhileWorking`, `OperatorTiming.liveQuietMinutes`).
Comes from: RT F6.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The plan says 1d moves "the one live rule" of `StallWatch` into the transcript reader. It is not live: its
only caller is the open-call reader of `WorkerTranscript`, which nothing calls. This step therefore deletes the
open-call reader, `StallWatch.swift` (its last member, `isCallRunning`) and `OperatorTiming.openCallMinutes`
together; nothing is moved anywhere.

## Why

The Operator runtime lives in `app/Sources/AiTerm/Operators/`. Each broadcast-era feature that was removed
left a seam behind: ports for waits and budgets that no owner reads, a reader of a worker's still-running tool
calls whose watcher is gone, test hooks and read-numbering in the transcript locator for concurrent readers
that no longer exist, an unused tool-argument field, a poller callback only tests set, and convenience members
only tests call. They make the owners look busier than they are and hide which seams are real. After this step
every field of `OperatorPorts` and every member of these owners is read by production code, or is a test seam
that a test really uses.

## Today

Paths under `app/Sources/AiTerm/Operators/` unless stated. Run each grep before deleting.

- `OperatorPorts.swift`, after 1b and 1d:
  - `OperatorClock.sleep` and the enum `OperatorClock.Wait`: nothing in Sources calls `sleep`
    (`grep -rn "clock.sleep\|ports.clock" app/Sources` finds only `clock.now`). Tests set it once
    (`OperatorPorts.scratch` in `app/Tests/AiTermTests/Operators/OperatorFakes.swift`) and an extension
    `OperatorClock.overrideSleep` there is unused. `OperatorClock.now` is live (six test files set it, the
    controller reads `ports.now`).
  - `jiraSearchBudget` (its doc comment is also half of another comment), `challengeReplyBudget`,
    `wakeCoalesce`, `appVersion`: no reader. `grep -rn "ports.jiraSearchBudget\|challengeReplyBudget\|ports.wakeCoalesce\|ports.appVersion" app`
    finds nothing; the fixture passes `wakeCoalesce: .zero` to the initialiser. (`appVersion` is read as
    `Bundle.main...` at the `report_snag` call in `SignalOperatorToolHandler+Calls.swift`, not through ports.)
  - Live and staying: `home`, `claudeConfig`, `git`, `workerGuardExecutable`, `notifications`, `secondOpinion`,
    `clock.now`/`now`, `work`, `reconcileInterval`, `hostTimeout`, `hostCache`, `installedAgents`,
    `agentModels`, `installedVersions`, `profile`, `preferences`, and `live(...)`.
- `Operators/WorkerTranscript.swift`:
  - `WorkerTranscript.modified(_:)`, the struct `OpenCalls`, `callWindowBytes`, `openCalls(in:agent:after:now:windowBytes:)`
    and the `extension WorkerTranscript.OpenCalls` at the middle and end of the file (its `claude`, `codex`,
    `pruned`, date formatters). `grep -rn "openCalls(\|OpenCalls\|callWindowBytes\|WorkerTranscript.modified" app`
    finds nothing outside the file (the word `OpenCalls` also appears in a comment in `OperatorTiming.swift`).
    `OpenCalls.pruned` is the only caller of `StallWatch.isCallRunning`.
  - In `TranscriptLocator`: `keepReplies(of:)`, `holdBeforeKeeping(_:)` and the `beforeKeeping` mutex (no caller
    in Sources or Tests), the `fullRead` parameter of `reply(agent:conversation:fullRead:)` (never passed true;
    its second tuple value `read` is read by nobody), and the read-numbering inside `Replies` (`begun`,
    `running`, `last`), which served concurrent readers that no longer exist (the doc comments name
    `BranchWatch`, `WorkerTurnReader`, `WorkerQuietWatch`; none exists). Live: `file(agent:conversation:)`,
    `lastMessage`, `lastReply`, `Stamp`, the stamp-before-read rule, `WorkerTranscript.file`, `readReply`,
    `claudeReply`, `codexReply`, `Reply`, `TailRead`, `lastMessage(in:agent:)` and `lastReply(in:agent:)`
    (the static file readers are used by `CompatTranscriptTests` and `WorkerTranscriptTests`, which pin the
    transcript formats; leave them).
- `Operators/ToolCall.swift`: `ToolCall.MarkOutcome` and `markOutcome` (no reader), and two orphan doc
  comments with no declaration under them ("Any tool of a broadcast that has ended." in `ToolRefusal`,
  "The tool by its name; nil for a name AiTerm has no tool for." in `ToolCall`).
- `Operators/SecondOpinionRunner.swift`: `static var cancelled` (no caller; the dead-looking doc names a
  board and a spec section).
- `Operators/ThenRunner.swift`: `isRunning(_:)` (`grep -rn "\.isRunning(" app/Sources/AiTerm/Operators` shows
  only `stages.isRunning` for `StageRunner`, whose own `isRunning` is live).
- `Operators/SignalPoller.swift`: the callback `onRead` and its one invocation in `tick(host:)`; assigned only
  in `app/Tests/AiTermTests/Operators/SignalPollerTests.swift` (three tests). `onPass` and `onFailure` are live.
- `Operators/ItemRouter.swift`: `apply(signals:read:)`, a two-line wrapper over `apply(observations:)`. The
  controller calls only `apply(observations:)`; about forty test call sites in `SignalEngineTests`,
  `SignalSelectionTests`, `SignalAgentChoiceTests`, `SignalWorkerIOTests`, `SignalControllerTests`,
  `SignalOperatorLifetimeTests` use the wrapper.
- Core: `StallWatch.swift` (`isCallRunning` only, after 1d), `OperatorTiming.openCallMinutes`,
  `OperatorTiming.wakeCoalesce` (read only by the port field above and by `OperatorTimingTests`).

How to tell dead names from live ones:

- `reply`: dead is `TranscriptLocator.reply(agent:conversation:fullRead:)` (folded into `lastReply`). Live and
  untouched: `WorkerTranscript.Reply`, `lastReply`, `QuestionRounds`/`AgentChoiceRounds` `.reply` outcomes,
  `ChallengeRecord.reply`, `DaemonClient.replyToOperator`.
- `modified`: dead is `WorkerTranscript.modified(_:)`; `Stamp.modified` inside `TranscriptLocator` is live.
- `cancelled`: dead is `SecondOpinionRunner.cancelled`; live and untouched: `DaemonClient` state `cancelled`,
  `FixRefusal.cancelled`, `Task.isCancelled`.
- `isRunning`: dead is `ThenRunner.isRunning`; live: `StageRunner.isRunning`, `OperatorActivityTracker.isRunning`,
  `WorkInFlight.isRunning`, `MessagingChecks.isRunning`, `Process.isRunning`.
- `sleep`, `Wait`: dead is `OperatorClock.sleep` and `OperatorClock.Wait`; `Task.sleep` and `Thread.sleep` are
  everywhere and stay. `now`: `OperatorClock.now` stays.
- `onRead`: dead is `SignalPoller.onRead`; `ReviewThreadsWatcher.selectionRead` is unrelated.
- `publisher`: already deleted by 1b.

## Change

1. `OperatorPorts.swift`: delete `OperatorClock.sleep` and `Wait` (leaving `OperatorClock` with `now`),
   `jiraSearchBudget`, `challengeReplyBudget`, `wakeCoalesce`, `appVersion` and their doc comments. Fix any
   comment left with half a sentence.
2. `OperatorTiming.swift`: delete `wakeCoalesce` and `openCallMinutes`. Keep `jiraSearchBudget`
   (`JiraClientTests.searchHasAResourceDeadline` reads it: it pins the Jira request deadline inside the
   daemon's wait). `StallWatch.swift`: delete the file.
3. `WorkerTranscript.swift`: delete `modified`, `OpenCalls`, `callWindowBytes`, `openCalls` and the whole
   `OpenCalls` extension. Rewrite `TranscriptLocator`: keep `home`, `claudeConfig`, the `found` cache, `Stamp`,
   `file`, `lastMessage`; `lastReply(agent:conversation:)` becomes the one reader: find the file, resolve
   symlinks, stamp it, return the kept reply when the stamp is unchanged, else read the tail with
   `WorkerTranscript.readReply` and keep `(stamp, reply)` for the next ask; a file that could not be read is
   kept as nothing so the next ask reads it. The stamp is taken before the read (a write in between is read
   again next time). Replace `Replies` and its numbering by a single dictionary of `Kept` under the mutex.
   Delete `keepReplies`, `holdBeforeKeeping`, `beforeKeeping`, `fullRead` and the `(reply, read)` tuple. Rewrite
   the doc comments of the type so they name what exists (`SignalWorkerIO`'s turn reading and `read_task`).
4. `ToolCall.swift`: delete `MarkOutcome`, `markOutcome` and the two orphan doc comments. `SecondOpinionRunner`:
   delete `cancelled`. `ThenRunner`: delete `isRunning(_:)`. `SignalPoller`: delete `onRead` and the
   `self.onRead(...)` line in the success path.
5. `ItemRouter.swift`: delete `apply(signals:read:)`. In `app/Tests/AiTermTests/Operators/OperatorFakes.swift`
   add the same wrapper as a test-only extension of `ItemRouter` (identical signature, `@discardableResult`,
   body `apply(observations: [SignalObservation(signals: ids, read: read)])`); the forty call sites do not
   change.
6. Fixtures and fakes in `OperatorFakes.swift`: in `OperatorPorts.scratch` drop `wakeCoalesce: .zero` and the
   `ports.clock.sleep = ...` block with its comment; delete `extension OperatorClock { overrideSleep }`.
7. `OperatorTimingTests.theTimingsAreTheContractsValues`: remove the `wakeCoalesce` row. Keep the other rows
   and the daemon-agreement tests.
8. `SignalPollerTests`: three tests assign `onRead`. Move them to `onPass`: a pass publishes its observations
   once at the end of a tick, so the equal-queries test reads `batches.first` (the signals of the one
   observation) where it read `published.first`; the two tests that count publications count passes instead
   (`published += 1` inside `onPass`). Expected numbers stay the same because each of those ticks makes at
   most one observation. If one of these tests then cannot detect what it detected before, stop and report
   which.

## Keep

- `jiraSearchBudget` constant, `reconcileInterval`, `hostTimeout`, `hostCache`, `challengeTimeout`,
  `firstWorkerOpening`, `hostReadTimeout`, `hostReadCache`, `gateTimeout`, `operatorRequestTimeout`.
- `WorkerTranscript.lastMessage(in:agent:)`, `lastReply(in:agent:)`: they are only called by tests today
  but those tests (`CompatTranscriptTests`, `WorkerTranscriptTests`) are the contract for the agents'
  transcript formats; do not delete a reader the compat suite needs.
- `TranscriptLocator.file`'s cache and the stamp rule. Without the stamp every `refreshTurns` tick would read
  512 KB of every worker's transcript.
- `SignalPoller.onPass`, `onFailure`, `canPoll`, `TickPass` (step 5e decides on them), `ActivityLog.read`
  (5h), `OperatorWork`, `OperatorActivityTracker`.
- `ThenRunner` and `StageRunner` public surfaces other than `isRunning` of `ThenRunner`.
- Stale comments elsewhere in the lane ("spec §4.4", "TabOpener", "P3 1A", "additive until activation"): step
  1j rewrites them. Only comments in lines you delete or touch are fixed here.
- `OperatorTiming.finishReplyBudget` and `OperatorPorts.finishReplyBudget`: already gone (1d). If either is
  still present, stop and report: the earlier step did not run.

## Decisions already taken

- The locator no longer drops replies for conversations that ended (`keepReplies` had no caller, so nothing
  ever pruned them). One reply of a few kilobytes per conversation for the app's life is not worth a pruning
  rule. Real, then likely: no.
- Overlapping reads of one file may now both keep a result. Each keeps a consistent (stamp, reply) pair, an
  older pair at worst makes the next ask read again. No numbering is needed.
- A same-length, same-second rewrite of a transcript is not detected (it was only detected by the `fullRead`
  path nobody used). Cannot happen with the agents' append-only transcripts.
- `ItemRouter.apply(signals:read:)` survives as test support, not as product API; it is not "kept for
  compatibility".
- `OperatorClock` stays a struct with one field so the six tests that set `ports.clock.now` do not change.

## Tests

- No test file is deleted. Deleted behaviour has no test (`openCalls`, `keepReplies`, `holdBeforeKeeping`,
  `StallWatch.isCallRunning`, `markOutcome`, `cancelled`, `isRunning` have none).
- Adjusted: `SignalPollerTests` (three tests, `onRead` to `onPass`), `OperatorTimingTests` (one row),
  `OperatorFakes.swift` (see Change 5 and 6).
- Survivors that detect a locator regression: `WorkerTranscriptTests.onlyTheEndOfALongTranscriptIsRead`,
  `aReplyBeforeTheTailWindowIsNotRead`, `aTailThatStartsMidRecordDropsThePartialLineAndStillFindsTheReply`,
  `claudesLastReplyIsItsLastAssistantTextNotItsToolCall`, `codexsLastReplyIsItsLastAgentMessage`,
  `claudesConversationIsReadFromTheConfiguredFolder`, `aConversationIdThatIsAPathFindsNothing`, plus
  `SignalWorkerIOTests` for the turn reading. Add one test to `WorkerTranscriptTests`,
  `aReplyIsReadAgainOnlyWhenItsFileChanged`: append a first reply to a transcript, ask `lastReply` twice
  through one `TranscriptLocator` and then append a second reply and ask again; assert the first two answers
  are equal and the third is the new reply. (It pins the stamp rule that survives; it passes before and
  after.)
- No fixture is re-recorded.

## Proof

- Iterate: `scripts/test.sh swift -- --filter SignalPollerTests`, `WorkerTranscriptTests`,
  `OperatorTimingTests`, `SecondOpinionRunnerTests`, `SignalWorkerIOTests`, `SignalEngineTests`,
  `SignalSelectionTests`, `SignalAgentChoiceTests`, `SignalControllerTests`, `SignalOperatorLifetimeTests`,
  `SignalWatchTests`, `CompatTranscriptTests`, `JiraClientTests`.
- Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rnwE "OpenCalls|openCalls|callWindowBytes|keepReplies|holdBeforeKeeping|beforeKeeping|markOutcome|MarkOutcome|StallWatch|openCallMinutes|wakeCoalesce|challengeReplyBudget|overrideSleep|onRead" app`
  returns nothing, and `grep -rn "jiraSearchBudget" app/Sources/AiTerm` and `grep -rn "clock.sleep\|ports.appVersion" app`
  return nothing.
- `grep -rn "func cancelled\|static var cancelled" app/Sources/AiTerm/Operators` and
  `grep -n "func isRunning" app/Sources/AiTerm/Operators/ThenRunner.swift` return nothing.
- `app/Sources/AiTermCore/Operators/StallWatch.swift` is gone; suites above and plain `scripts/test.sh` green.

## Not in this step

- The poller's loops, `TickPass`, the 180-second grace (5e); the controller split (5d); the activity writer
  queue and the other repair paths (2f); `OperatorPorts` fields that 2f or 5d replace.
- The comment sweep for broadcast words and spec sections (1j); the shell gate wording (1j).
- `OperatorModels`, `OperatorLine`, `WorkerTabs`, `ActivityLog` members and the other unread `OperatorTiming`
  constants (1d).
