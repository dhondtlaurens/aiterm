# 0b. One signal journey, from a Jira match to an archived task

Implementer: Opus 5.5 at high effort. Depends on: 0a. Findings: TS section 4 ("Missing: signal
match to done to archive as one chain").

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The design notes name `SignalWorld`, `SignalHarness`, `RecordingDaemon` and `GitFixture` as the
fakes to reuse. Two of them cannot carry this journey:

- `SignalWorld` puts its project at `/synthetic/shop`, which is not a repository, so no worker
  checkout can be made and no worktree can be shown gone.
- `SignalHarness` makes its own `WorkspaceStore`, while the archive that Then runs is the app's
  (`AppController` wires `signalController.archive` to its archive owner over its own workspace,
  window lock and live sessions).

The brief therefore builds on `RaceFixture` (a real repository made with `GitFixture` and a real
`AppController` over it), `RecordingDaemon`, `OperatorPorts.scratch()`, `TestClock`, `StubSession`,
`OperatorServiceFixtures.session` and `SignalWorld.agent`. It reuses the app's own archive wiring
rather than naming an archive owner. Everything else follows the design notes.

## Why

Each Operator owner is tested alone through its ports: the router, the stage runner, the watch,
Then and the automatic archive each have their suite, but nothing joins them. Phases 4 and 5
restructure exactly those joins (one lifecycle, one tick, one claim check, new owners for waking,
the chat and the Oracle). Without a test that drives the whole chain, those phases can leave every
unit suite green while a signal no longer gets from a match to its archived task. This step adds
that one journey, driven only through entry points that survive phase 5 and with fakes only at the
edges the app cannot own in a test: the daemon, HTTP to Jira, git (hermetic, but real), the clock
and the agent's transcript on disk. A right test fails when any link of the chain breaks and names
no internal owner. A wrong one calls the router, the stage runner, the watch or Then directly, or
fakes an owner of the app.

## Today

- `SignalOperatorController` (`app/Sources/AiTerm/Operators/SignalOperatorController.swift`)
  composes the Operator. Its entry points: `init(workspace:live:work:ports:daemon:frame:automatic:)`,
  `start()`, `stop()`, `handle(_ event: DaemonEvent)` and `reconcile()`. `start()` loads the profile,
  configures the poller (one read per source, at most once a minute by the ports' clock) and
  reconciles. A connected `.snapshot` event sets `tabsKnown` and schedules a reconcile.
  `reconcile()` reads worker turns (`native.refreshTurns()`), runs saved stage launches, runs Then
  for finished stages and, when a minute of the ports' clock has passed since the last one,
  schedules the request watch (`hostDue`), which reads the done condition and then runs Then.
  Every job it starts goes through `ports.work` (an `OperatorWork`), so `await ports.work.settled()`
  joins all of it.
- `automatic: true`, the default, adds a `PollLoop` that runs `reconcile()` immediately and then on
  a real-time interval, plus one real-time poll loop per source host. The only product caller,
  `AppController.init` (about line 181 today), uses the default. Every controller suite builds its
  own controller with `automatic: false` (`grep -rn "SignalOperatorController(" app/Tests`).
- `AppController.init` (about lines 184 to 186) wires `signalController.readConnections` (Settings'
  Jira, GitLab and GitHub), `signalController.archive` (the app's automatic archive) and
  `signalController.remove`. `readConnections` feeds both the source readers and the done-condition
  reads (`SignalHostIO.read`). `ItermFocusTests` already replaces `readConnections` with a
  `StubSession`.
- `sourceRegistrations` is a test-only seam (only tests assign it:
  `grep -rn "sourceRegistrations" app/Sources app/Tests`). The journey does not use it.
- `RaceFixture` (`app/Tests/AiTermTests/RaceFixture.swift`) makes a real repository with
  `GitFixture.initRepo`, one project over it (provider git, no remote) and an `AppController` built
  with the scratch ports, `ScriptedPrompter` and hermetic git. Its controller is not started; tests
  attach a daemon with `controller.helper.setDaemonClient(_:)` and send events with
  `controller.helper.handle(_:)`, which reaches `LiveSessions` first and then every hook.
- `RecordingDaemon` (`app/Tests/AiTermTests/RecordingDaemon.swift`) records each request with its
  parameters, answers `window.createTask` with `reopened`, then `reopened-2` and so on, approves both
  agents in `delivery.policy`, and delivers every `session.deliver` and `session.closeIdle`.
- `OperatorPorts.scratch()` (`app/Tests/AiTermTests/Operators/OperatorFakes.swift`) gives a scratch
  home, both agents installed with short model lists (Claude `claude-opus-5-5` at `high` among
  them), versions the recording daemon vouches for, a profile and scratch defaults. Its
  `clock.now` can be replaced (`SignalOperatorLifetimeTests.aScheduledRealCadenceReconcileRetiresAfterTheLastTask`
  does it with a `TestClock`).
- Worker turns: after a launch the task holds a pending reply for tab `main`, so it counts as busy
  until its transcript shows a new reply. `SignalWorkerIOTests.anEndedWorkerQuestionKeepsItsStageBusyUntilAnAgreedAnswerIsSent`
  shows where a Claude transcript goes: a `<conversation>.jsonl` file under
  `ports.claudeConfig.directory(home: ports.home)`, in any folder under `projects/`, with one
  assistant line whose text is the reply. A reply that ends in a question keeps the task busy.
- The done condition `.ticketStatus("Done")` reads the ticket through Jira's search endpoint
  (`POST /rest/api/3/search/jql`), the same endpoint the source reader polls. The stub answer shape
  that works for both is in `SignalHostIOTests.ticketStatusNeedsOnlyItsJiraReadAndNeverRequiresARequest`.
- Suites covering the pieces today: `SignalEngineTests`, `SignalWatchTests`,
  `SignalAutomaticCleanupTests`, `SignalControllerTests`, `SignalPollerTests`, `SignalWorkerIOTests`.

## Change

Add one suite, `SignalJourneyTests`, in `app/Tests/AiTermTests/Operators/SignalJourneyTests.swift`,
marked `@MainActor` and `@Suite(.blocking)` (it runs git), with one test,
`aJiraMatchRunsToItsDoneConditionAndThenArchivesItsTask`. Its steps:

1. Set up the world.
   - `RaceFixture()`; a `RecordingDaemon`; attach it with `fixture.controller.helper.setDaemonClient`.
   - In `fixture.controller.workspace`, link the fixture's project to Jira project `PAY` on site
     `https://jira.example` (`jiraProjects`), and append one signal: Jira source with empty
     `JiraConditions`, prompt `/psg:plan`, agents `[SignalWorld.agent]`, done when
     `.ticketStatus("Done")`, Then `.archive`, created at the clock's start. Flush and expect true.
   - Ports: `OperatorPorts.scratch()`, with `clock.now` reading a `TestClock` started at a fixed date.
   - A `StubSession` whose handler answers every request with HTTP 200 and one Jira search page:
     one issue `PAY-1` with a summary, a plain-string description, issue type `Task` and the
     status name read from a `Mutex<String>` that starts at `To Do`, and `isLast` true. The handler
     runs off the main actor, hence the mutex. Links: `SignalConnections` with a `JiraConfig` for
     `https://jira.example` (fake email and token) and the stub's session.
2. Build the controller under test: `SignalOperatorController` over `fixture.controller.workspace`,
   `fixture.controller.live` and `fixture.controller.work`, with the ports above, `daemon` returning
   the recording daemon, a fixed frame and `automatic: false`. Then:
   - set its `readConnections` to return the links;
   - set its `archive` to `fixture.controller.signalController.archive`, the app's own wiring, so
     the test names no archive owner;
   - register it for helper events, as the app does: `fixture.controller.helper.onEvent` handing
     each event to the controller's `handle`.
3. Act 1, the match. Call `start()`, send a connected snapshot with no sessions through
   `fixture.controller.helper.handle`, then `await ports.work.settled()`. Expect:
   - exactly one task in `state.tasks`, under the signal (its saved record names the signal), on
     item `PAY-1` from `https://jira.example`, with Jira key `PAY-1`;
   - its saved phase is `.working`, its worktree exists on disk and the window it saved is set;
   - exactly one `window.createTask` request whose `taskId` is the task's id (the Operator's own
     chat may open another window with its session's id; do not count that one);
   - one seen entry for the signal and `PAY-1` with disposition `.started`.
4. Act 2, the ticket is done while the worker still works. Send a connected snapshot holding one
   worker tab: `OperatorServiceFixtures.session("worker", window: <the task's saved window>, tag:
   <task id>, state: .working, conversation: "journey-worker", cwd: <worktree>)`; settle. Set the
   stub's status to `Done`, advance the clock by 61 seconds, `await reconcile()`, settle. Expect the
   phase still `.working`, the task still in `state.tasks`, and no `window.close` request.
5. Act 3, the turn ends. Write the transcript first: `journey-worker.jsonl` in a folder under
   `projects/` of the ports' Claude directory, one assistant line saying the plan is written, with
   no question. Then send the same snapshot with the worker tab `.done`; settle. Advance the clock
   by another 61 seconds, `await reconcile()`, settle. Expect:
   - `state.task(id:)` is nil and `state.archived(id:)` holds the task, its saved record's phase
     `.archived`;
   - the worktree folder no longer exists, and `git branch --list <branch>` in the repository still
     lists the branch (run git off the main actor with `BackgroundWork.run`);
   - one `window.close` request for the worker's window;
   - no unresolved question for the task in `state.operatorSession`;
   - `fixture.controller.savedWorkspace()` holds the archived row.
6. Tear down in `defer`: `stop()` the controller, `fixture.controller.shutdown()`,
   `fixture.cleanUp()`, remove `ports.home`.
7. In `docs/testing.md`, in the paragraph that starts "`SignalWorld`/`SignalHarness` cover routing"
   (about line 102 today), add one sentence: `SignalJourneyTests` drives one signal from a Jira
   match through its worker's turn and done condition to its archived task, through the
   controller's own entry points, with fakes only at the daemon, HTTP, git and the clock; it must
   pass after every phase.

## Keep

- `SignalWorld`, `SignalHarness`, `RaceFixture`, `RecordingDaemon` and `OperatorFakes.swift`
  unchanged: about twenty suites share them. If the journey needs something they lack, build it
  inside the new file.
- No product change. No new seam, no `internal` widened for the test, no change to `AppController`.
- The total clock advance stays under 180 seconds: past that, a launch whose worker shows no reply
  is blocked as failed and the Operator's own window counts as not opened.

## Decisions already taken

- The test calls only `start()`, `stop()`, `reconcile()`, the controller's initialiser and its
  `readConnections` and `archive` properties, plus the helper's `handle` and `onEvent`. It never
  names `router`, `stages`, `then`, `watch`, `native`, `host`, `keeper`, `poller`, `tabsKnown`,
  `sourceRegistrations`, `ItemRouter`, `StageRunner`, `ThenRunner`, `RequestWatch`, `TaskArchiver`
  or `TaskRemover`. Assertions read only saved state, the disk, git and recorded daemon requests.
- A later step that renames `reconcile()` (5e may call it a tick), moves the `archive` port, or
  moves the phase inside the saved record updates the one call or read here and nothing else. Say
  so in that step's report.
- The Operator chat: the controller may open it (another `window.createTask`, an
  `operator.register`). The journey lists no Operator tab and asserts nothing about the chat; its
  lifetime has its own suites (`SignalOperatorLifetimeTests`, `SignalSessionKeeperTests`,
  `SignalFreshSessionTests`).
- Every snapshot after the launch lists the worker's tab in the window the task saved, so no window
  rule (today's or phase 3's) treats it as closed.
- The worktree must stay clean: the transcript lives under the scratch home, never in the worktree,
  or the archive keeps the checkout as unsaved work.
- If the chain fails for a product reason (not the harness), stop and report the step and the saved
  state you saw. Phase 0 changes no product code.
- Flakiness: run the filtered suite at least three times. A failure that comes and goes is a harness
  ordering problem: settle after every event and every reconcile; do not add sleeps.

## Tests

- Added: `SignalJourneyTests.aJiraMatchRunsToItsDoneConditionAndThenArchivesItsTask`.
- Deleted or changed: none. No fixture changes.

## Proof

- `scripts/test.sh swift -- --filter SignalJourneyTests`, three times, all green.
- Show the journey catches breaks, then revert each: with Then `.keep` it must fail at the archive
  expectations; with the stub's status left at `To Do` it must fail at the same place.
- Plain `scripts/test.sh` before reporting.

## Done when

- The suite passes three filtered runs and the plain gate.
- `grep -nE "\.(router|stages|watch|native|keeper|poller|tabsKnown|sourceRegistrations)\b|ItemRouter|StageRunner|ThenRunner|RequestWatch|TaskArchiver|TaskRemover|\.archiver|\.remover" app/Tests/AiTermTests/Operators/SignalJourneyTests.swift`
  prints nothing.
- `docs/testing.md` names the journey.
- `git status` shows only the new test file and `docs/testing.md`.

## Not in this step

- Moving tests onto the shared builders (0c).
- The phase 3 window journeys (adopt a tagged window, a closed window leaves its row, choosing a
  row without a window opens it once, a failed open is reported on the click): 3a and 3b.
- The lifecycle tests' single settled join (4a).
