import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalControllerTests {
    @Test(arguments: [TaskPhase.done, .archived, .watching(.operatorJudges)])
    func aQueuedStageStartsAfterACompanionsTurnEndsWithoutAnotherMatch(phase: TaskPhase) async throws {
        var world = SignalWorld(); let original = world.signal(), id = world.workingTask(signal: original)
        let next = world.signal()
        world.state.updateSignalTask(id) { $0.phase = phase; $0.thenApplied = true }
        if phase == .archived { world.state.moveToArchive(taskId: id, branch: "feat/pay-1", at: world.now) }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        var companion = OperatorServiceFixtures.session("companion", tag: id, state: .working, conversation: "companion")
        companion.agent = .codex; companion.tabIndex = 1
        live.sessions = [OperatorServiceFixtures.session("primary", tag: id, state: .done, conversation: "primary"), companion]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        var launches = 0
        root.stages = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: root.native.busy, prepare: { task, _ in task },
            launch: { _, _ in launches += 1; return "worker" }, restore: { task in
                // As the app's restore does: the row back in the sidebar.
                h.workspace.mutate { $0.moveFromArchive(id: task.id) }
                return task
            }))
        root.tabsKnown = true; root.sourceRegistrations = { _ in [] }; root.start(); await ports.work.settled()
        _ = root.router.apply(signals: [next], read: SignalRead(items: [world.ticket()], complete: true))
        await root.reconcile(); await ports.work.settled()
        #expect(launches == 0 && h.workspace.state.signalItem(id: id)?.signalTask?.pendingStages.count == 1)
        live.sessions[1].state = .done
        await root.reconcile(); await ports.work.settled()
        #expect(launches == 1)
        #expect(h.workspace.state.task(id: id)?.signalTask?.current.signal == next)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        #expect(h.workspace.state.task(id: id)?.signalTask?.pendingStages.isEmpty == true)
        await root.reconcile(); await ports.work.settled()
        #expect(launches == 1)
        root.stop()
    }
    @Test func aSourceFailureIsSavedLoggedAndWokenOnlyWhenItsReasonChangesAndAPassClearsIt() async throws {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        let session = OperatorSession.open(createdAt: world.now)
        world.state.operatorSession = session
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("operator", window: "operator-window", tag: session.id, state: .done, conversation: "op")]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.sourceRegistrations = { _ in [] }; root.tabsKnown = true; root.start(); await ports.work.settled()
        defer { root.stop() }
        func entries() -> [ActivityEntry] {
            ActivityLog.read(folder: OperatorLaunch.folder(home: ports.home)).entries.filter { $0.tool == "signal_read" }
        }
        for _ in 0..<2 {
            root.poller.onFailure([signal], "The source is unavailable.")
            await root.reconcile(); await ports.work.settled()
        }
        #expect(h.workspace.state.operatorSession?.sourceFailures?[signal.uuidString] == "The source is unavailable.")
        #expect(entries().map(\.result) == ["The source is unavailable."])
        #expect(daemon.requests("session.deliver").count == 1)
        root.poller.onFailure([signal], "The connection was refused.")
        await root.reconcile(); await ports.work.settled()
        #expect(h.workspace.state.operatorSession?.sourceFailures?[signal.uuidString] == "The connection was refused.")
        #expect(entries().map(\.result) == ["The source is unavailable.", "The connection was refused."])
        #expect(daemon.requests("session.deliver").count == 2)
        root.poller.onPass([SignalObservation(signals: [signal], read: SignalRead(items: [], complete: true))])
        #expect(h.workspace.state.operatorSession?.sourceFailures?[signal.uuidString] == nil)
        await root.reconcile(); await ports.work.settled()
        #expect(entries().count == 2 && daemon.requests("session.deliver").count == 2)
    }
    /// Polling needs no iTerm2: the tick reads a configured source while it is not connected.
    @Test func theTickPollsAConfiguredSourceWhileITerm2IsNotConnected() async throws {
        var world = SignalWorld(); _ = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var ports = OperatorPorts.scratch(); let clock = TestClock(world.now)
        ports.clock.now = { clock.now }
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(),
            ports: ports, daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        let reader = CountingSignalReader()
        root.sourceRegistrations = { signals in signals.map {
            SignalPoller.Registration(id: $0.id, sourceHost: "jira.example", readKey: "tickets", isJira: true, reader: reader)
        } }
        root.start(); await ports.work.settled()
        defer { root.stop() }
        #expect(!root.tabsKnown)
        #expect(await reader.calls.count == 1)
        clock.advance(by: 61)
        await root.reconcile(); await ports.work.settled()
        #expect(await reader.calls.count == 2)
    }
    /// A save that lands while a tick runs reads the edited signal's source at once, not a minute later.
    @Test func aSaveWhileATickRunsReadsTheEditedSignalBeforeTheNextMinute() async throws {
        var world = SignalWorld(); _ = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var ports = OperatorPorts.scratch(); let clock = TestClock(world.now)
        ports.clock.now = { clock.now }
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(),
            ports: ports, daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        let reader = CountingSignalReader(), entered = TestLatch(), release = TestLatch()
        var holdNext = false
        root.sourceRegistrations = { signals in
            if holdNext { holdNext = false; entered.signal(); await release.wait() }
            return signals.map { SignalPoller.Registration(id: $0.id, sourceHost: "jira.example", readKey: "tickets", isJira: true, reader: reader) }
        }
        root.tabsKnown = true; root.start(); await ports.work.settled()
        defer { root.stop() }
        #expect(await reader.calls.count == 1)
        // A reattached helper makes the settings step due at once; the tick holds there.
        holdNext = true; root.daemonAttached()
        let tick = Task { await root.reconcile() }
        await entered.wait()
        var edited = h.workspace.state.signals[0]; edited.name = "Plan tickets again"
        try await root.save(edited); await ports.work.settled()
        #expect(await reader.calls.map(\.full) == [true, true], "The edit reads its source again in full, with the clock unchanged.")
        release.signal(); await tick.value; await ports.work.settled()
        #expect(await reader.calls.count == 2)
    }
    @Test func unsupportedPersistedSettingsCannotBeCreatedThroughTheSignalSaveBoundary() async throws {
        var world = SignalWorld(); _ = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let ports = OperatorPorts.scratch(); defer { try? FileManager.default.removeItem(at: ports.home) }
        let root = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace), work: WorkInFlight(),
            ports: ports, daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        var invalid = world.state.signals[0]
        invalid.source = .gitHub(RequestConditions(event: .reviewRequested))
        invalid.finish = SignalFinish(doneWhen: .approved, mergesWhenReady: true)
        await #expect(throws: ActionUnavailable.self) { try await root.save(invalid) }
        #expect(h.workspace.state.signals == world.state.signals)
    }
    @Test func aPausedWorkerThatFailedIsNotSentCarryOnOrLeftBusyForever() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.operatorSession?.pausedWorkers = [PausedWorker(task: id, tab: "main", ownership: 0)]
        world.state.updateSignalTask(id) { $0.phase = .blocked }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("worker", tag: id, state: .done, conversation: "failed")]
        let native = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let signaller = SignalPauseSignaller(workspace: h.workspace, live: live, native: native, enabled: { true }, now: { world.now })
        await signaller.reconcile()
        #expect(h.workspace.state.operatorSession?.pausedWorkers?.isEmpty == true)
        #expect(daemon.requests("session.deliver").isEmpty)
        #expect(!native.busy(id))
    }
    /// Take Over hands the task to the person: its record goes, the task is marked, its question is withdrawn, its
    /// project opens, and its recorded guard scopes carry the raised ownership, so a launch past its claim check cannot
    /// write one that still grants the Operator anything.
    @Test func takeOverRevokesTheStageAndWithdrawsItsQuestions() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, ports = controller.signalController.ports
        var task = try await fixture.addTask(windowId: "worker-window")
        var record = SignalTask.make(item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        record.phase = .working; record.ownership = 2
        record.extraTabs = [ExtraTab(key: "review", agent: .claude, model: "model", reasoning: nil, modelReason: "", brief: "",
                                     launch: LaunchAttempt(number: 1, requestedAt: Date()))]
        task.signalTask = record; task.jira = JiraRef(key: "PAY-1", summary: "Pay", url: "https://jira.example/browse/PAY-1")
        let id = task.id, project = fixture.project.id
        controller.workspace.mutate { state in
            state.tasks = [task]
            state.updateProject(id: project) { $0.collapsed = true }
            state.operatorSession = OperatorSession(createdAt: Date())
            state.operatorSession?.questions = [.init(id: "q", task: id, text: "Which?", openedAt: Date())]
        }
        #expect(controller.workspace.flush())
        for slot in ["main", "review"] {
            var scope = WorkerGuard.Scope(task: id, worktree: task.worktreePath, branch: task.branch, remote: "", allowsPush: true)
            scope.ownership = 2
            _ = try WorkerGuardLaunch.prepare(scope: scope, home: ports.home, slot: slot, executable: ports.workerGuardExecutable)
        }

        await controller.takeOver(id)

        let current = try #require(controller.state.task(id: id))
        #expect(current.signalTask == nil && current.takenOver)
        #expect(controller.state.project(id: project)?.collapsed == false)
        #expect(controller.state.operatorSession?.questions.isEmpty == true)
        for slot in ["main", "review"] {
            #expect(WorkerGuardLaunch.recordedScope(task: id, home: ports.home, slot: slot)?.ownership == 3)
        }
        #expect(controller.toastState.toast?.message == "PAY-1 is yours. The Operator let go of it.")
        #expect(controller.issue == nil)
    }
    @Test func aPausePersistsItsWorkerAndResumeCarriesOnBeforeAdvancing() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("worker", tag: id, state: .working, conversation: "saved")]
        let root = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        root.start(); await ports.work.settled()
        await root.setPaused(true)
        #expect(h.workspace.state.operatorSession?.paused == true)
        #expect(h.workspace.state.operatorSession?.pausedWorkers?.count == 1)
        #expect(daemon.requests("session.deliver").last?.params["text"] as? String == SignalPauseSignaller.pauseNote)
        await root.setPaused(false)
        #expect(h.workspace.state.operatorSession?.pausedWorkers?.isEmpty == true)
        #expect(daemon.requests("session.deliver").last?.params["text"] as? String == SignalPauseSignaller.carryOnNote)
        #expect(h.workspace.state.task(id: id)?.signalTask?.pendingReplies?["main"] != nil)
        root.stop()
    }
    @Test func questionNotificationsOpenTheOneChatAndAreWithdrawnWhenResolved() throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.tasks[0].jira = JiraRef(key: "PAY-1", summary: "Retries", url: "https://jira.example/browse/PAY-1")
        let askedAt = world.now
        world.state.operatorSession?.questions = [.init(id: "one", task: id, text: "Which cap?", openedAt: askedAt)]
        let note = try #require(SignalQuestionNotification.make(state: world.state))
        #expect(note.title == "The Operator has a question")
        #expect(note.body.contains("PAY-1") && note.body.contains("Which cap?"))
        #expect(OperatorNote.Target(userInfo: note.target.userInfo) == .operatorWindow)
        world.state.operatorSession?.questions[0].resolvedAt = askedAt
        #expect(SignalQuestionNotification.make(state: world.state) == nil)
    }
    @Test func oneWorkloadKeepsOneOperatorAndServesSignalStatus() async throws {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        let controller = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        controller.tabsKnown = true
        controller.start()
        await ports.work.settled()
        await controller.reconcile()
        await controller.reconcile()
        let session = try #require(h.workspace.state.operatorSession)
        #expect(daemon.requests("operator.register").contains { $0.params["generation"] as? Int == session.generation })
        #expect(daemon.requests("window.createTask").count == 1)
        controller.handle(.operatorRequest(OperatorRequest(requestId: "status", operatorId: session.id.uuidString,
            tool: "run_status", arguments: [:], generation: session.generation)))
        await ports.work.settled()
        let reply = try #require(daemon.requests("operator.reply").last)
        #expect(reply.params["error"] == nil)
        #expect((reply.params["result"] as? JSONValue)?["signals"]?.arrayValue?.count == 1)
        controller.stop()
        try? FileManager.default.removeItem(at: ports.home)
    }
    @Test func aStaleShellRequestGetsARealGateDenialAndNeverAGenericToolError() async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        let controller = SignalOperatorController(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        controller.start(); await ports.work.settled()
        controller.handle(.operatorRequest(OperatorRequest(requestId: "gate", operatorId: world.state.operatorSession!.id.uuidString,
            tool: "gate_command", arguments: ["command": "cat README.md", "directory": .string(h.folder.path)], generation: 0)))
        await ports.work.settled()
        let reply = try #require(daemon.requests("operator.reply").last)
        #expect((reply.params["result"] as? JSONValue)?["decision"] == "deny")
        #expect(reply.params["error"] == nil)
        controller.stop()
    }
    @Test func toolsAndSkippedItemsKeepTheirOnDiskActivity() async throws {
        var world = SignalWorld(); let signal = world.signal()
        world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let controller = SignalOperatorController(workspace: h.workspace, live: LiveSessions(workspace: h.workspace),
            work: WorkInFlight(), ports: ports, daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) }, automatic: false)
        let session = try #require(h.workspace.state.operatorSession)
        _ = await controller.tools.respond(OperatorRequest(requestId: "status", operatorId: session.id.uuidString,
            tool: "run_status", arguments: [:], generation: session.generation))
        _ = controller.router.apply(signals: [signal], read: SignalRead(items: [world.ticket("NOPE-1")], complete: true, full: true))
        await ports.work.settled()
        let entries = ActivityLog.read(folder: OperatorLaunch.folder(home: ports.home)).entries
        #expect(Set(entries.map(\.tool)) == ["run_status", "signal_match"])
        #expect(entries.contains { $0.line.contains("NOPE-1") && $0.line.contains("No project") })
        #expect(h.workspace.state.tasks.isEmpty)
    }

}

private actor CountingSignalReader: SignalSourceReader {
    struct Call: Sendable { var since: Date?; var full: Bool }
    var calls: [Call] = []
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        calls.append(Call(since: since, full: full))
        return SignalRead(items: [], complete: true, full: full)
    }
}
