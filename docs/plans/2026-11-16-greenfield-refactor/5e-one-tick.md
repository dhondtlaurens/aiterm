# 5e. One tick, one in-flight set per task

Implementer: Opus 5.5, high effort. Depends on: phases 1 to 4 and steps 5a, 5b, 5c, 5d. Audit
findings: operator-runtime F2 and F13 (`docs/research/2026-11-16-greenfield-audit/operator-runtime.md`).

## Why

The Operator's runtime has five timers and about seventeen re-entrancy guards where one 60-second
tick would do. Source polling grew first as its own owner with a loop per source host ("additive
until activation"), so today sources are read by two paths: the poller's own loops and the
controller's settings check, which ends by ticking the poller. Each owner that does something to
a task (launching its stage, applying Then, typing to its worker, running an Oracle round) keeps its
own "already running for this task" set, so two owners can act on one task at once and the sets
disagree about what "busy" means. `SignalWorkerIO.busy` looks like a question but inserts into a
set as it answers, so whether a "worker ended" wake fires depends on which owner happened to ask
first. The 180-second grace is written as a bare literal in four places. The end state: one tick
(the controller's reconcile) on one 60-second loop plus the event triggers that exist today, whose
steps each ask "am I due"; one in-flight set keyed by task that every Operator effect on a task
claims; `busy` as a pure question; the live-work set computed once per tick; one name for the
grace. Nothing a person sees changes, and no saved byte changes.

## Today

Described as after 5d. The controller (`SignalOperatorController`, `app/Sources/AiTerm/Operators/`)
is construction plus one ordered reconcile, and composes `OperatorWaker` (wake slot and delivery),
`OperatorChat` (the chat's window and session, wrapping `OperatorSessionKeeper`), `ActivityWriter`
and `OracleConsult` (5c, every Oracle use). Retention is Core `AppState.pruneOperator(at:)`. Every
phase change goes through `SignalTransitions` and one `SignalClaim.allows(in:)` covers workspace,
pause, signal enabled, claim and cancellation (5a). Re-read every symbol below before you change it;
line numbers are from before 5a to 5d and have drifted.

Timers and loops:

- Controller `loop: PollLoop` every `ports.reconcileInterval` (`OperatorTiming.reconcileInterval`,
  60 s), started in `start()` only when `automatic` is true; calls `reconcile()`.
- `SignalPoller.replace` starts one `PollLoop` per source host (`loops[host]`, 60 s, only when
  `automatic`), each calling the private `tick(host:)`.
- Inside `reconcile()`: `settingsDue` (60 s) runs retention, `loadProfile()` and `configure()`;
  `configure()` ends with `poller.tick()` (about line 426 today). `daemonAttached()` resets
  `settingsDue` to `distantPast`.
- Inside `reconcile()`: `hostDue` (60 s) schedules `watch.pass()` (`RequestWatch`).
- Inside the poller: per read key `Progress.next` (60 s after a complete read, 300 s after a
  failure) and the Jira full sweep after 600 s (`lastFull`).

Re-entrancy guards and in-flight sets:

- Controller `reconciling` (the tick's own guard; triggers that arrive while it runs are dropped).
- Controller `reconcileIfIdle()`: the filter that lets workspace and activity changes trigger a
  tick only while no work remains and the chat has a window (for prompt retirement).
- Controller `configuration` UUID: a newer `configure()` supersedes an older one's late result.
- `TickPass` (`TickPass.swift`): one polling pass per host at a time, plus a `generation` so a late
  pass cannot release a replacement. Its only user is `SignalPoller`; prove it with
  `rg -n 'TickPass' app/Sources app/Tests` (only `TickPass.swift` and `SignalPoller.swift`).
- `SignalPoller.generation`: `replace` and `stop` drop late reads.
- `RequestWatch.running`: one host-watch pass at a time.
- `SignalWorkerIO.reading`: one `refreshTurns()` at a time. Its only source caller is the
  controller's reconcile (`rg -n 'refreshTurns\(' app/Sources`).
- `SignalWorkerIO.inFlight`: set by `launch`, `message` and `openTab`; read by `busy`, `question`,
  `recoverLaunches` and those three effects' own guards.
- `SignalWorkerIO.awaitingLiveWork`: written by `busy` as a side effect (about line 43 today) and
  by `refreshTurns`, which fires `onTurn` (a `worker_ended` wake) for a task whose live work ended.
- `StageRunner.running` with `isRunning(_:)`; the controller passes
  `native.recoveryAllowed = { !stages.isRunning($0) }` so `recoverLaunches` skips a running stage.
  `StageRunner.generation` and `isStopped` make `stop()` invalidate late completions.
- `ThenRunner.running`.
- The worker-answer round's "a round is already running for this question" set
  (`QuestionRounds.activeQuestions`, keyed by the full question binding, held from the round's start
  through delivery) and the agent-choice round's (`AgentChoiceRounds.active`, keyed by task, stage
  and ownership). 5c kept both where they are and left `OracleConsult` a runtime count of consults
  (`isIdle`) only. Find them with
  `rg -n 'activeQuestions|active\.insert|inFlight|running' app/Sources/AiTerm/Operators`.
- `QuestionRounds.running` (keyed by `answer_worker:<key>`): goes in 5g, not here.
- `SignalOperatorToolHandler.running` (keyed by the handler ledger key): stays, it is the ledger's
  pending rule.
- `SignalPauseSignaller.running`: one pause pass at a time; called from the tick, from `save` and
  from `setPaused`.
- `OperatorSessionKeeper.pass`: one chat handover pass at a time.
- `OperatorWaker`'s `pending` and `waking`, `OperatorChat`'s open-in-flight record, the
  controller's `activeTools` and `OracleConsult.isIdle`: 5f's.
- `WorkInFlight` tokens (`work.begin(.opening, onTask:)` and friends in `SignalWorkerIO`): the
  app-wide per-task operation registry shared with manual tasks and the teardown owner.

The 180-second grace: `OperatorTiming.firstWorkerOpening` (read by `TaskItem.workerTabs(in:now:)`
in `WorkerTabs.swift`) and bare `180` in `SignalWorkerIO.refreshTurns` (failed opening, about line
114, and an unanswered saved message, about line 146) and in `OperatorChat` (`sessionIssue`'s "did
not start in its window", and the chat's window grace if 3b left a timer). Find them with
`rg -n '\b180\b' app/Sources/AiTerm/Operators`.

`busy(_:)` (`SignalWorkerIO`) is passed as `workerIsWorking` to `ItemRouter`, `StageRunner`,
`ThenRunner`, `RequestWatch` and others. Tests: `SignalPollerTests`, `SignalWorkerIOTests`,
`SignalEngineTests`, `SignalWatchTests`, `SignalQuestionRoundsTests`, `SignalAgentChoiceTests`,
`SignalToolHandlerTests`, `SignalControllerTests`, `SignalOperatorLifetimeTests`,
`SignalFreshSessionTests`, `SignalOperatorIssueTests`, `SignalJourneyTests` (0b),
`OperatorTimingTests`.

## Change

1. **Name the grace once.** Rename `OperatorTiming.firstWorkerOpening` to
   `OperatorTiming.openingGrace` and write its doc as what it is: how long AiTerm waits for an
   opened window, launched worker or delivered message to show its agent or reply before it treats
   the launch or delivery as failed. Use it in `WorkerTabs`, at both `refreshTurns` sites and in
   every 180-second check in `OperatorChat` (`sessionIssue`, and the chat window grace if 3b kept
   one).
   No bare 180 for this grace remains. `challengeTimeout` (also 180) is a different concept; leave it.
2. **Add the in-flight set.** New `OperatorInFlight` in `app/Sources/AiTerm/Operators/` (one small
   main-actor class): the tasks an Operator effect is running on. It answers whether a task is held,
   claims a task (returning false when it is already held) and releases it. The controller creates
   one and passes it to `StageRunner`, `ThenRunner`, `RequestWatch`, `SignalWorkerIO`, the
   worker-answer round owner, the agent-choice round owner and the tool handler at construction.
   Each takes it as an initialiser parameter that defaults to a fresh instance, so tests that build
   one owner alone keep compiling.
3. **Claim at the outermost entry of each effect**, release on exit (a `defer`), and never claim
   inside a call that already holds the task:
   - `StageRunner.run`: claims instead of `running`; a failed claim returns quietly as today. It
     holds the claim through restore, prepare and launch. `isRunning(_:)` goes.
   - `ThenRunner.apply`: claims instead of `running`. It releases its claim before its trailing
     "advance a pending stage" call (`stages.finish(id, action: .advancePending)`), which must run
     outside the claim because that stage's launch claims the task itself.
   - The worker-answer round: claims for the whole round, from beginning the round through
     delivering the agreed answer; a failed claim returns `{"status": "pending"}` as the
     per-question set does today. That set goes.
   - The agent-choice round: claims around its Oracle round and releases before it returns its
     outcome (the caller then runs `StageRunner.choose`, whose launch claims); a failed claim
     returns `pending` as today. Its set goes.
   - The tool handler: claims around `ports.message` for `message_task` and around `ports.openTab`
     for `open_tab` (after the choice round, which claims and releases on its own). A failed claim
     refuses with today's words: "This worker is not idle and ready for a message." for
     `message_task`, "This task is busy." for `open_tab`.
   - `RequestWatch`: claims a task from the merge veto through the merge and the confirming read,
     and releases before `stages.finish` and `then.apply`; a failed claim skips that task this pass.
   - `SignalWorkerIO.launch`, `message` and `openTab` no longer touch any set: their callers hold
     the claim. `inFlight` goes. `recoverLaunches` skips a task the set holds; the
     `recoveryAllowed` port goes.
4. **Make `busy` pure.** `SignalWorkerIO.busy(_:)` keeps every clause about the worker (live
   sessions, open questions, paused workers, pending replies, worker tabs, a stopped worker, an
   asking reply) and loses the `inFlight` clause and the `awaitingLiveWork` insertion. It changes
   nothing when called.
5. **Who treats a held claim as work.** Owners that do not hold the claim ask "busy, or held by
   someone else": the `workerIsWorking` the controller gives `ItemRouter` is that combination;
   `StageRunner.finish`, `resume` and `choose` check the set themselves beside their port;
   `RequestWatch` skips a task that is busy or held. Owners that hold the claim (`StageRunner.run`
   after claiming, `ThenRunner.apply`'s `allowed`) ask `busy` only, or they would refuse themselves.
6. **`question(_:tab:)` drops its in-flight check.** A pending reply (`markPending`, saved before
   any typing) and the claim at the entry of `answer_worker` and `message_task` already cover what
   it guarded. The round's own "is this question still asked" check would otherwise fail against
   its own claim.
7. **Live work once per tick.** `refreshTurns()` computes the set of tasks with live work once
   (from `live.sessions`, as its local `liveWork` does today), keeps last tick's set, and fires
   `onTurn` for each task in last tick's set that has none now. `awaitingLiveWork` becomes that
   kept set and nothing else writes it. `reading` goes (the tick's `reconciling` guard covers it).
8. **Polling becomes a tick step.** `SignalPoller` loses its loops, the `automatic` flag and
   `TickPass`. Its `tick()` stays as the poll step: for each source host with no pass still reading,
   it starts one pass (through `OperatorWork.start`, so tests settle on it) over the read keys whose
   `Progress.next` has come, keeping the shared reads, the cursor, the five-minute back-off and the
   ten-minute Jira sweep exactly as today. A per-host "reading" set replaces `TickPass.running`;
   `generation` stays and still drops a read that finishes after `replace` or `stop`. Delete
   `TickPass.swift`.
9. **Order the tick.** `reconcile()` runs, in order: the settings step when due (retention,
   profile, `configure()`); the poll step (skipped while paused or stopped, as `canPoll` today);
   then the existing `guard tabsKnown` and everything after it as 5d left it, with the host-watch
   step where `hostDue` is today. The poll step sits before `guard tabsKnown` on purpose: polling
   never needed iTerm2, and today's poller loops kept polling while it was disconnected.
10. **`configure()` stops polling.** It replaces registrations (refreshing edited signals' keys)
    and returns. `save(_:)` and `setPaused(false)` call the poll step themselves right after
    `configure`, because a save that lands while a tick runs must not wait a minute for its first
    read. `start()` already runs `configure()` then `reconcile()`.
11. **The host watch is due when the interval has passed and the last pass has ended.** The
    controller keeps the running pass's task handle beside `hostDue`; `RequestWatch.running` goes.
    `watch.pass()` remains callable directly (its tests do).
12. **Keep the rest of the guards** listed under Keep, and write the table below into the commit
    body so the reviewer can check each guard's fate.

| Today | After 5e |
| --- | --- |
| controller `PollLoop` | the one tick |
| poller loops per host | gone; poll step in the tick |
| `settingsDue`, `hostDue` | due checks of the settings and host steps |
| `Progress.next`, Jira sweep | the poll step's per-key due check, unchanged |
| `configure()` ticking the poller | gone; `save` and `setPaused(false)` run the poll step |
| `TickPass` | gone; per-host reading set in the poller |
| poller `generation` | kept |
| `reconciling`, `reconcileIfIdle`, `configuration` | kept |
| `RequestWatch.running` | gone; the host step's "last pass ended" |
| `SignalWorkerIO.reading` | gone |
| `SignalWorkerIO.inFlight`, `StageRunner.running`, `ThenRunner.running`, round sets | one `OperatorInFlight` |
| `awaitingLiveWork` side effect in `busy` | gone; per-tick live-work set |
| `recoveryAllowed` port | gone |
| `SignalPauseSignaller.running`, keeper `pass`, handler `running`, `WorkInFlight` | kept |
| `QuestionRounds.running` | 5g |
| waker `pending`, `waking`, `leftUnsent`; the chat's open record; `activeTools`; `OracleConsult.isIdle` | 5f |

## Keep

- `reconciling` and the drop-while-running behaviour: the tick mutates the workspace, and
  `workspace.onChange` would otherwise re-trigger it forever. Do not add a "run once more" flag.
- `reconcileIfIdle()` and its conditions: it is the existing workspace and activity trigger, and
  its filter is what keeps ordinary workspace changes from running a full tick.
- `SignalPauseSignaller.running`: `save` and `setPaused` call `pause.reconcile()` directly, outside
  the tick, so a pause reaches workers even while a tick runs. The pause notes are not a task
  effect in the shared set (they type into a working worker, never an idle one).
- `OperatorSessionKeeper.pass`: the chat handover's single flight, called from the tick and from
  `openOperator`.
- The handler's `running` set: same key twice in flight answers `pending`; the ledger rule.
- `WorkInFlight`: app-wide and shared with manual tasks and the teardown owner. The Operator's set
  is separate because Then's archive itself begins a `WorkInFlight` operation on the task.
- `StageRunner.generation` and `isStopped`, and the poller's `generation`: late completions after
  `stop()` must not write.
- `OperatorWork`: every started read and job goes through it so `settled()` in tests waits for them.
- The `automatic` flag on the controller (tests construct it with `automatic: false` to get no
  timer). Only the poller's copy goes.

## Decisions already taken

- **`busy` reads live state, not the per-tick set.** Live sessions change on daemon events between
  ticks; a stale set could let a stage finish while its worker started working. Only the wake on
  "work ended" uses the per-tick set.
- **A refused call followed by a short burst of work.** Today a refusal because a companion tab is
  working records the task for a wake even if no tick saw the work. After this step the tick that
  every tool reply already triggers (`respond` ends with `reconcile()`) observes it. If a tick was
  already running, that trigger is dropped and the next tick observes work still running. Work that
  starts and ends entirely between two ticks with nothing observing it is not plausible enough to
  handle.
- **Two questions on two tabs of one task** are answered one at a time: the second
  `answer_worker` gets `pending` and the Operator retries. Real but rare; `pending` is already a
  documented reply.
- **A merge veto in flight now refuses `message_task` for that task.** Typing into a worker while
  AiTerm merges its head is wrong; the refusal is today's "not idle" wording.
- **Polling while the workspace cannot change** stops: the poll step is inside the tick, after the
  top `canChangeWorkspace` guard. Today reads advanced cursors that the router then discarded.
- **Interval constants.** The poll step and the settings and host steps use
  `OperatorTiming.reconcileInterval` for their minute; the five-minute back-off and ten-minute sweep
  stay as named constants inside `SignalPoller`. Values do not change.
- **A poll pass finishing during a tick** routes its observations at once through the existing
  `onPass` (router, then scheduled stage runs and a scheduled tick), as today.
- **`stop()`** cancels jobs as today; a cancelled claim holder's `defer` still releases its task,
  and nothing claims after `isStopped`, so a plain set needs no tokens.

## Tests

- Delete nothing that tests a kept behaviour. `TickPass` has no tests of its own; its behaviour
  (overlapping ticks start no duplicate read, stop drops a late read) stays covered by
  `SignalPollerTests.stopDropsALateReadAndOverlappingTicksStartNoDuplicate`.
- Adjust `SignalPollerTests` to build the poller without `automatic`.
- Adjust `SignalWorkerIOTests.aRefusedFinishIsWokenWhenAnUnkeyedCompanionBecomesIdle`: call
  `refreshTurns()` once after the refused finish and before the companion ends (the tick every
  reply triggers); it still proves exactly one wake.
- Rename `firstWorkerOpening` in `OperatorTimingTests`; the value stays 180.
- Add, test first:
  - The tick polls a configured source with iTerm2 not connected (`tabsKnown` false), through the
    controller with `automatic: false`.
  - A save while a tick is running still reads the edited signal's source before the next minute.
  - While a worker-answer round holds a task, `message_task` on that task is refused with "This
    worker is not idle and ready for a message." and the stage launch for it does not start.
  - While Then runs for a task, a pending stage for it waits, and starts after Then releases.
  - Calling `busy` twice changes nothing; a task observed with live work by one tick and without it
    by the next gets one `worker_ended` wake.

## Proof

- Iterate: `scripts/test.sh swift -- --filter 'SignalPollerTests|SignalWorkerIOTests|SignalEngineTests|SignalWatchTests|SignalQuestionRoundsTests|SignalAgentChoiceTests|SignalToolHandlerTests|SignalControllerTests|SignalOperatorLifetimeTests|SignalFreshSessionTests|SignalOperatorIssueTests|SignalJourneyTests|OperatorTimingTests'`.
- Then plain `scripts/test.sh`, started in the background.
- No snapshot, wire or fixture change is expected; `SignalSavedFormatTests` must pass untouched.

## Done when

- `rg -n 'TickPass|PollLoop' app/Sources/AiTerm/Operators` finds only the controller's one loop.
- `rg -n 'firstWorkerOpening|awaitingLiveWork\.insert|recoveryAllowed|isRunning\(' app/Sources/AiTerm/Operators`
  returns nothing, and `rg -n '\b180\b' app/Sources/AiTerm/Operators` returns nothing.
- `rg -n 'inFlight|activeQuestions|private var running|private var active' app/Sources/AiTerm/Operators`
  shows only `OperatorInFlight`, the handler's ledger `running`, the pause signaller's `running` and
  `QuestionRounds.running` (5g).
- The suites above and plain `scripts/test.sh` are green.
- `docs/architecture.md`: the sentence naming `TickPass` (about line 53 today) says polling passes
  run from the Operator's tick, one per host; the `SignalPoller` row and the controller row still
  read true.

## Not in this step

- The waker's slot and `waking`, the chat's open record, `activeTools`, `OracleConsult.isIdle` and
  one idle rule: 5f.
- `QuestionRounds.running` and its ledger: 5g.
- Moving files in Core `Signals/`: 5h.
