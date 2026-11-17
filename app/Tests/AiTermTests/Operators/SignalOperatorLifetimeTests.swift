import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalOperatorLifetimeTests {
    @Test func aFreshChatNeverReceivesQuestionsFromCompletedWorkInItsFirstDigest() async throws {
        var world = SignalWorld(); let signal = world.signal(), done = world.workingTask(signal: signal)
        _ = world.workingTask(signal: signal)
        world.state.updateSignalTask(done) { $0.phase = .done; $0.thenApplied = true }
        let askedAt = world.now
        world.state.operatorSession?.questions = [.init(id: "obsolete", task: done, text: "Old scope?", openedAt: askedAt)]
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        var counts: [Int] = []
        root.keeper = OperatorSessionKeeper(workspace: h.workspace, now: { world.now }, oracleOn: { false }, ports: .init(
            canOpen: { true }, close: { _ in }, revoke: { _ in },
            open: { _, digest in counts.append(digest.waitingOnYou); return "operator-window" }))
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        #expect(counts == [0])
        root.stop()
    }

    @Test func configuredSignalsPollWithoutOpeningAnEmptyChat() async throws {
        var world = SignalWorld(); _ = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        let reader = EmptySignalReader()
        root.sourceRegistrations = { signals in signals.map { signal in
            SignalPoller.Registration(id: signal.id, sourceHost: "jira.example", readKey: "tickets", isJira: true, reader: reader)
        } }
        root.tabsKnown = true; root.start(); await ports.work.settled()
        await root.reconcile(); await ports.work.settled()
        #expect(await reader.reads > 0)
        #expect(daemon.requests("window.createTask").isEmpty)
        #expect(!SignalOperatorRowValue.make(state: h.workspace.state, sessions: []).shown)
        root.stop()
    }

    @Test func finishingTheLastTaskClosesRevokesAndLeavesSignalsWatching() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        var session = OperatorSession(createdAt: world.now); session.window = "operator-window"; session.conversation = "old-chat"
        session.questions = [.init(id: "old-question", task: task, text: "Already finished?", openedAt: world.now)]
        world.state.operatorSession = session
        world.state.updateSignalTask(task) { $0.phase = .done; $0.thenApplied = true }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "old-chat")]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        await root.reconcile(); await ports.work.settled()
        let names = daemon.requests.map(\.method)
        let close = try #require(names.firstIndex(of: "session.closeIdle"))
        let revoke = try #require(names.firstIndex(of: "operator.revoke"))
        #expect(close < revoke)
        #expect(daemon.requests("window.createTask").isEmpty)
        #expect(h.workspace.state.operatorSession?.window == nil)
        #expect(h.workspace.state.operatorSession?.conversation == nil)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 0)
        #expect(h.workspace.state.signals.count == 1 && h.workspace.state.tasks.count == 1)
        #expect(!SignalOperatorRowValue.make(state: h.workspace.state, sessions: live.sessions).shown)
        root.stop()
    }

    @Test(arguments: [TaskPhase.done, .archived])
    func completedTasksAndTheirOldQuestionsCannotKeepNeedsYouVisible(phase: TaskPhase) {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        world.state.updateSignalTask(task) { $0.phase = phase; $0.thenApplied = true }
        let askedAt = world.now
        world.state.operatorSession?.questions = [.init(id: "obsolete", task: task, text: "A finished question", openedAt: askedAt)]
        let row = SignalOperatorRowValue.make(state: world.state, sessions: [])
        #expect(!row.shown && row.status != .needsInput)
        #expect(SignalQuestionNotification.make(state: world.state) == nil)
    }

    @Test func aMatchDuringTheLastChatsCloseStartsFreshAndIsNotLost() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        var session = OperatorSession(createdAt: world.now); session.window = "operator-window"; session.conversation = "old-chat"
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "old-chat")]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        h.workspace.mutate { $0.updateSignalTask(task) { $0.phase = .done; $0.thenApplied = true } }
        let closing = TestLatch(), release = TestLatch()
        daemon.beforeReply = { method in if method == "session.closeIdle" { closing.signal(); await release.wait() } }
        let pass = Task { await root.reconcile() }
        await closing.wait()
        let newIDs = root.router.apply(signals: [signal], read: SignalRead(items: [world.ticket("PAY-2")], complete: true))
        #expect(newIDs.count == 1)
        release.signal(); await pass.value; await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.generation == 2)
        #expect(h.workspace.state.operatorSession?.conversation == nil)
        #expect(h.workspace.state.operatorSession?.window == "reopened")
        #expect(h.workspace.state.task(id: newIDs[0])?.signalTask?.keepsOperatorSession == true)
        let names = daemon.requests.map(\.method)
        #expect(try #require(names.firstIndex(of: "session.closeIdle")) < #require(names.firstIndex(of: "operator.revoke")))
        #expect(try #require(names.firstIndex(of: "operator.revoke")) < #require(names.firstIndex(of: "window.createTask")))
        root.stop()
    }

    @Test func aScheduledRealCadenceReconcileRetiresAfterTheLastTask() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        var session = OperatorSession(createdAt: world.now); session.window = "operator-window"; session.conversation = "chat"
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        var ports = OperatorPorts.scratch(); let clock = TestClock(world.now)
        ports.clock.now = { clock.now }
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let tab = OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "chat")
        live.sessions = [tab]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        h.workspace.mutate { $0.updateSignalTask(task) { $0.phase = .done; $0.thenApplied = true } }
        clock.advance(by: 60)
        root.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [tab], usage: .empty)))
        await ports.work.settled()
        #expect(daemon.requests("session.closeIdle").count == 1)
        #expect(h.workspace.state.operatorSession?.window == nil)
        root.stop()
    }

    @Test func anIdlePausedOperatorCanResumeWithoutCreatingAnEmptyChat() async throws {
        var world = SignalWorld(); _ = world.signal()
        var session = OperatorSession(createdAt: world.now); session.paused = true
        session.window = "operator-window"; session.conversation = "chat"; world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "chat")]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.window == nil && h.workspace.state.operatorSession?.paused == true)
        await root.setPaused(false); await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.paused == false)
        #expect(daemon.requests("window.createTask").isEmpty)
        root.stop()
    }
}

private actor EmptySignalReader: SignalSourceReader {
    var reads = 0
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        reads += 1
        return SignalRead(items: [], complete: true)
    }
}
