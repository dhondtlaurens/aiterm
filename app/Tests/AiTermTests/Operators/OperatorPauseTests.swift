import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Your keys and clicks as a `PauseGate` reads them: `idle` gives each read in turn, its last one repeating;
/// every sleep runs `during` first, where a test looks at what has happened so far.
@MainActor final class ScriptedPause {
    var idle: [TimeInterval]
    var slept = 0
    var during: @MainActor () -> Void = {}
    /// Holds each sleep until it returns: a wait that outlasts whoever started it.
    var holding: (@MainActor () async -> Void)?
    init(_ idle: [TimeInterval]) { self.idle = idle }
    /// One gate, so its window turn is shared as the app's is.
    lazy var gate = PauseGate(pause: 5, idle: { [unowned self] in self.idle.count > 1 ? self.idle.removeFirst() : self.idle.first },
                              sleep: { [unowned self] _ in self.slept += 1; self.during(); await self.holding?() })
}

@Suite @MainActor struct OperatorPauseTests {
    @MainActor private struct Launch {
        let h: SignalHarness, id: UUID, daemon: RecordingDaemon, io: SignalWorkerIO, live: LiveSessions
        var task: TaskItem { get throws { try #require(h.workspace.state.task(id: id)) } }
        var record: SignalTask? { h.workspace.state.task(id: id)?.signalTask }
    }
    /// A launching stage whose task has `window`, holding `sessions`.
    private func launch(_ pause: ScriptedPause, window: String? = nil, sessions: (UUID) -> [SessionInfo] = { _ in [] }) throws -> Launch {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world)
        h.workspace.mutate { $0.updateSignalItem(id) {
            $0.worktreePath = h.folder.path; $0.windowId = window; $0.signalTask?.phase = .launching
            $0.signalTask?.launch = LaunchAttempt(number: 1, requestedAt: world.now.addingTimeInterval(-3600), workerPending: true)
        } }
        var ports = OperatorPorts.scratch(); ports.pause = pause.gate
        let now = world.now; ports.clock = OperatorClock(now: { now })
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        live.sessions = sessions(id)
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        return Launch(h: h, id: id, daemon: daemon, io: io, live: live)
    }
    private func cleanUp(_ launch: Launch) {
        launch.h.cleanUp(); try? FileManager.default.removeItem(at: launch.io.ports.home)
    }

    /// While you type, a worker that opens a window closes nothing, saves nothing and opens nothing; it says it waits.
    @Test func aWindowLaunchWaitsForYourPauseBeforeItClosesTheWorkerItReplaces() async throws {
        let pause = ScriptedPause([0, 0, 5])
        let l = try launch(pause, window: "w1") { [OperatorServiceFixtures.session("old", window: "w1", tag: $0, conversation: "c1")] }
        defer { cleanUp(l) }
        var words: [String] = []
        l.io.whilePausing = { said, wait in words.append(said); await wait() }
        pause.during = {
            #expect(l.daemon.requests("session.closeIdle").isEmpty && l.daemon.requests("window.createTask").isEmpty)
            #expect(l.record?.pendingReplies?["main"] == nil)
            // Saved so: a quit now, with the old worker still open, must not have recovery adopt it as launched.
            #expect((try? l.h.file.load().task(id: l.id)?.signalTask?.launch?.workerPending) == false)
            l.io.recoverLaunches()
            #expect(l.record?.phase == .launching)
        }
        _ = try await l.io.launch(try l.task, prompt: "Run.")
        #expect(l.record?.launch?.workerPending == true, "pending again from the save just before the window opened")
        #expect(pause.slept == 1)
        #expect(words.count == 1 && words[0].hasPrefix("waiting for your pause to open"))
        #expect(l.daemon.requests("session.closeIdle").count == 1 && l.daemon.requests("window.createTask").count == 1)
    }

    /// Typing resumed during the launch's daemon calls holds the window, with nothing saved yet; the opening grace then
    /// counts from the open.
    @Test func typingDuringTheLaunchsDaemonCallsHoldsTheWindowAndRestampsTheLaunch() async throws {
        let pause = ScriptedPause([5, 0, 0, 5])
        let l = try launch(pause, window: "w1") { [OperatorServiceFixtures.session("old", window: "w1", tag: $0, conversation: "c1")] }
        defer { cleanUp(l) }
        let before = try #require(l.record?.launch?.requestedAt)
        pause.during = {
            #expect(l.daemon.requests("session.closeIdle").count == 1 && l.daemon.requests("window.createTask").isEmpty)
            #expect(l.record?.pendingReplies?["main"] == nil)
        }
        _ = try await l.io.launch(try l.task, prompt: "Run.")
        #expect(pause.slept == 1)
        #expect(l.daemon.requests("window.createTask").count == 1)
        #expect(before < l.io.ports.now() && l.record?.launch?.requestedAt == l.io.ports.now())
    }

    /// You keep typing and take the task over meanwhile: the wait ends at once, so the launch lets go of the task.
    @Test func aTaskThatChangedHandsDuringTheWaitOpensNoWindow() async throws {
        let pause = ScriptedPause([0])
        let l = try launch(pause)
        defer { cleanUp(l) }
        pause.during = { l.h.workspace.mutate { $0.takeOver(l.id) } }
        await #expect(throws: (any Error).self) { try await l.io.launch(try l.task, prompt: "Run.") }
        #expect(pause.slept == 1)
        #expect(l.daemon.requests("window.createTask").isEmpty && l.record?.pendingReplies?["main"] == nil)
    }

    /// iTerm2 keeps a background tab in an open window unselected and behind: a tab never waits.
    @Test func aTabInAnOpenWindowNeverWaits() async throws {
        let pause = ScriptedPause([0, 5])
        let l = try launch(pause, window: "w1") { id in
            var shell = OperatorServiceFixtures.session("shell", window: "w1", tag: id, agent: .shell); shell.tabIndex = 0
            return [shell]
        }
        defer { cleanUp(l) }
        _ = try await l.io.launch(try l.task, prompt: "Run.")
        #expect(l.daemon.requests("tab.create").count == 1 && l.daemon.requests("window.createTask").isEmpty)
        l.h.workspace.mutate { $0.updateSignalTask(l.id) { $0.phase = .working; $0.pendingReplies = nil } }
        _ = try await l.io.openTab(try l.task, key: "check", choice: SignalWorld.agent, prompt: "Inspect.", why: "Second", allowed: { true })
        #expect(l.daemon.requests("tab.create").count == 2)
        #expect(pause.slept == 0)
    }

    private func keeper(_ h: SignalHarness, _ pause: ScriptedPause, wanted: @escaping @MainActor () -> Bool = { true },
                        opened: @escaping @MainActor () -> Void) -> OperatorSessionKeeper {
        var ports = OperatorSessionKeeper.Ports(canOpen: { true }, close: { _ in }, revoke: { _ in }, open: { _ in opened(); return "chat-window" })
        ports.pause = pause.gate; ports.wanted = wanted
        return OperatorSessionKeeper(workspace: h.workspace, now: { Date() }, ports: ports)
    }

    /// The Operator's own reconcile awaits `ensure`: while you type it returns at once, and the chat opens after your
    /// pause from a retry of its own, with no failure.
    @Test func aChatTheOperatorOpensWaitsForYourPauseWithoutHoldingEnsure() async throws {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal()); world.state.operatorSession = nil
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let pause = ScriptedPause([0, 0, 5]), resume = TestLatch()
        pause.holding = { await resume.wait() }
        var opened = 0, failures: [String] = []
        let keeper = keeper(h, pause) { opened += 1 }
        keeper.failed = { failures.append($0) }
        await keeper.ensure()
        let retry = try #require(keeper.pausedRetry)
        #expect(opened == 0 && h.workspace.state.operatorSession?.lifecycle == .opening)
        resume.signal(); await retry.value
        #expect(opened == 1 && h.workspace.state.operatorSession?.window == "chat-window")
        #expect(failures.isEmpty && keeper.pausedRetry == nil)
    }

    /// Choosing the chat's row is activity itself: that open never waits.
    @Test func aChatYouChoseOpensAtOnceWhileYouType() async throws {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal()); world.state.operatorSession = nil
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let pause = ScriptedPause([0])
        var opened = 0
        let keeper = keeper(h, pause) { opened += 1 }
        await keeper.ensure(allowPaused: true, reopen: true, chose: true)
        #expect(opened == 1 && pause.slept == 0 && keeper.pausedRetry == nil)
    }

    /// Typing resumed while the chat was prepared and registered holds its window: no failure, no issue, and it opens
    /// after your pause.
    @Test func typingDuringTheChatsPreparationDefersItWithoutAnIssue() async throws {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal()); world.state.operatorSession = nil
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let pause = ScriptedPause([5]), daemon = RecordingDaemon()
        var ports = OperatorPorts.scratch(); ports.pause = pause.gate
        defer { try? FileManager.default.removeItem(at: ports.home) }
        var typed = false
        daemon.beforeReply = { method in
            guard method == "operator.register", !typed else { return }
            typed = true; pause.idle = [0, 0, 5]
        }
        pause.during = { #expect(daemon.requests("window.createTask").isEmpty) }
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        #expect(typed && pause.slept == 1)
        #expect(daemon.requests("operator.register").count == 2 && daemon.requests("window.createTask").count == 1)
        #expect(root.log.issues.current.isEmpty)
        root.stop()
    }

    /// Its workload ended while the chat waited (a Take Over of its only task): the wait ends and nothing opens.
    @Test func aHeldChatWhoseWorkloadEndedNeverOpens() async throws {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal()); world.state.operatorSession = nil
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let pause = ScriptedPause([0])  // you never pause
        var wanted = true, opened = 0
        pause.during = { wanted = false }
        let keeper = keeper(h, pause, wanted: { wanted }) { opened += 1 }
        await keeper.ensure()
        await keeper.pausedRetry?.value
        #expect(opened == 0 && pause.slept == 1 && keeper.pausedRetry == nil)
    }

    /// Pause Operator while its first chat waits for your pause, then choose its row: the chat opens.
    @Test func aHeldChatYouChooseOpensThoughTheOperatorIsPaused() async throws {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal()); world.state.operatorSession = nil
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let pause = ScriptedPause([0]), resume = TestLatch()
        pause.holding = { await resume.wait() }
        var opened = 0
        let keeper = keeper(h, pause) { opened += 1 }
        await keeper.ensure()
        h.workspace.mutate { $0.operatorSession?.paused = true }
        await keeper.ensure(allowPaused: true, reopen: true, chose: true)
        #expect(opened == 1 && h.workspace.state.operatorSession?.window == "chat-window")
        #expect(keeper.pausedRetry == nil, "the chat opened: the wait and its line end")
        resume.signal()
    }

    /// The first chat stays opening for as long as you type: its row says it waits for your pause, not "starting fresh".
    @Test func theRowOfAChatHeldForYourPauseSaysSo() {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal())
        var session = OperatorSession(createdAt: world.now); session.lifecycle = .opening
        world.state.operatorSession = session
        // A worker's wait began after the chat's: the chat's still shows on its row.
        let waiting = OperatorActivity(line: OperatorLine("waiting for your pause to open PAY-1’s worker", look: .acting), chatWaitsForPause: true)
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: [], activity: waiting).line.text == OperatorSessionKeeper.pauseWords)
        #expect(SignalOperatorRowValue.make(state: world.state, sessions: []).line.text == "starting fresh")
    }

    /// resume_task answers once the stage is saved launching; its launch, which may wait for your pause far longer than
    /// the Operator's request, runs as a job of its own.
    @Test func aStageAToolResumesLaunchesAsAJobOfItsOwn() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.operatorSession = .open(createdAt: world.now)
        world.state.updateSignalTask(id) { $0.phase = .blocked; $0.blockedReason = "Its worker did not start." }
        world.state.updateSignalItem(id) { $0.windowId = nil }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var launched = 0, later: [UUID] = []
        let stages = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in
                h.workspace.mutate { $0.updateSignalItem(task.id) { $0.worktreePath = h.folder.path } }
                h.workspace.flush(); return try #require(h.workspace.state.task(id: task.id))
            }, launch: { _, _ in launched += 1; return "window" }, restore: { $0 }))
        stages.launchSoon = { later.append($0) }
        try await stages.resume(id)
        #expect(launched == 0 && later == [id] && h.workspace.state.signalItem(id: id)?.signalTask?.phase == .launching)
        await stages.run(id)
        #expect(launched == 1)
    }

    /// Pause Operator while a stage's replacement waits for your pause, its previous worker still open: on Resume the
    /// stage launches with its prompt again, and recovery does not take the old worker for the new stage's.
    @Test func aReplacementPausedDuringItsWaitIsNotAdoptedAsLaunched() async throws {
        let pause = ScriptedPause([0])  // you keep typing
        let l = try launch(pause, window: "w1") { [OperatorServiceFixtures.session("old", window: "w1", tag: $0, conversation: "c1")] }
        defer { cleanUp(l) }
        pause.during = { l.h.workspace.mutate { $0.operatorSession?.paused = true } }
        await #expect(throws: (any Error).self) { try await l.io.launch(try l.task, prompt: "Run.") }
        #expect(l.daemon.requests.allSatisfy { $0.method != "session.closeIdle" && $0.method != "window.createTask" })
        #expect(l.record?.launch?.workerPending == false && l.record?.phase == .launching)
        l.h.workspace.mutate { $0.operatorSession?.paused = false }
        l.io.recoverLaunches()
        #expect(l.record?.phase == .launching, "the old worker was not adopted as the new stage's")
    }

    /// Windows released by the same pause queue for the one window turn; typing resumed by then holds the next one until
    /// your next pause, instead of letting the daemon open it under your keys.
    @Test func typingResumedWhileAWindowWaitsForItsTurnHoldsItUntilYourNextPause() async throws {
        // Quiet at the launch's two looks; in the turn you type again; then you pause.
        let pause = ScriptedPause([5, 5, 0, 0, 0, 5])
        let l = try launch(pause)
        defer { cleanUp(l) }
        pause.during = {
            #expect(l.daemon.requests("window.createTask").isEmpty && l.record?.pendingReplies?["main"] == nil)
            #expect(l.record?.launch?.workerPending == false)
        }
        _ = try await l.io.launch(try l.task, prompt: "Run.")
        #expect(pause.slept == 1 && l.daemon.requests("window.createTask").count == 1)
        #expect(l.record?.pendingReplies?["main"] != nil && l.record?.launch?.workerPending == true)
    }

    /// Pause Operator while a launch waits for the window turn, then switch to another app: its turn comes with you
    /// "paused", but the launch lost its claim, so it saves no pending reply and opens nothing.
    @Test func aLaunchThatLostItsClaimBeforeItsTurnSavesNothing() async throws {
        let pause = ScriptedPause([5])
        let l = try launch(pause)
        defer { cleanUp(l) }
        let held = TestLatch(), release = TestLatch()
        let holder = Task { await pause.gate.turn.take { held.signal(); await release.wait() } }
        await held.wait()
        let launching = Task { try await l.io.launch(try l.task, prompt: "Run.") }
        #expect(await eventually { pause.gate.turn.isWaitedOn })
        l.h.workspace.mutate { $0.operatorSession?.paused = true }
        release.signal(); await holder.value
        await #expect(throws: (any Error).self) { try await launching.value }
        #expect(l.daemon.requests("window.createTask").isEmpty && l.record?.pendingReplies?["main"] == nil)
    }

    /// The Operator's chat waits for the window turn behind a worker's window and you go back to typing; then you choose
    /// its row. That open goes ahead without your pause, the click does not fail, and nothing waits for a retry.
    @Test func choosingAChatHeldForTheWindowTurnOpensIt() async throws {
        var world = SignalWorld(); _ = world.workingTask(signal: world.signal()); world.state.operatorSession = nil
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let pause = ScriptedPause([5])
        var keeperRef: OperatorSessionKeeper?, opened = 0, failures: [String] = []
        var ports = OperatorSessionKeeper.Ports(canOpen: { true }, close: { _ in }, revoke: { _ in }, open: { _ in
            // As `OperatorChat.open` does in the turn.
            try await pause.gate.turn.take {
                guard keeperRef?.chosenMeanwhile == true || pause.gate.isQuiet else { throw OperatorOpenDeferred() }
                opened += 1; return "chat-window"
            }
        })
        ports.pause = pause.gate
        let keeper = OperatorSessionKeeper(workspace: h.workspace, now: { Date() }, ports: ports)
        keeperRef = keeper; keeper.failed = { failures.append($0) }
        let held = TestLatch(), release = TestLatch()
        let holder = Task { await pause.gate.turn.take { held.signal(); await release.wait() } }
        await held.wait()
        let automatic = Task { await keeper.ensure() }
        #expect(await eventually { pause.gate.turn.isWaitedOn })
        pause.idle = [0]  // you type again
        let chosen = Task { await keeper.ensure(allowPaused: true, reopen: true, chose: true) }
        #expect(await eventually { keeper.chosenMeanwhile })
        release.signal(); await holder.value; await automatic.value; await chosen.value
        #expect(opened == 1 && h.workspace.state.operatorSession?.window == "chat-window")
        #expect(failures.isEmpty && keeper.pausedRetry == nil && !keeper.chosenMeanwhile)
    }
}
