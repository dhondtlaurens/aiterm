import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalWorkerIOTests {
    @Test func aNativeStageCanStartANewTaskBeforeItsFirstHookArrives() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .launching }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) { $0.worktreePath = h.folder.path; $0.windowId = nil } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let stages = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: io.busy, prepare: { task, _ in task }, launch: io.launch, restore: { $0 }))
        await stages.run(id)
        #expect(daemon.requests("window.createTask").count == 1)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        #expect(io.busy(id), "After the RPC, the first hook must arrive before finish or Then.")
        await stages.run(id)
        #expect(daemon.requests("window.createTask").count == 1)
    }
    @Test func aRefusedFinishIsWokenWhenAnUnkeyedCompanionBecomesIdle() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        var companion = OperatorServiceFixtures.session("companion", tag: id, state: .working)
        companion.agent = .codex; companion.tabIndex = 1
        live.sessions = [OperatorServiceFixtures.session("primary", tag: id, state: .done), companion]
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        var wakes: [UUID] = []; io.onTurn = { wakes.append($0) }
        let stages = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: io.busy, prepare: { task, _ in task }, launch: { _, _ in "worker" }, restore: { $0 }))
        await #expect(throws: SignalTransitionError.self) { try await stages.finish(id, action: .finish(.operatorJudges), judged: true) }
        #expect(wakes.isEmpty && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        // The refusal can occur between reconciliations: no earlier refresh observed this turn.
        live.sessions[1].state = .done
        await io.refreshTurns()
        #expect(wakes == [id])
        await io.refreshTurns()
        #expect(wakes == [id])
        try await stages.finish(id, action: .finish(.operatorJudges), judged: true)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
    }
    enum ActiveWorker: CaseIterable { case primary, companion, companionPrompt }
    @Test(arguments: ActiveWorker.allCases) func aSignalWaitsForAnOrdinaryTasksTurnThenContinuesItsConversation(active: ActiveWorker) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.tasks[0].signalTask = nil
        world.state.tasks[0].jira = JiraRef(key: "PAY-1", summary: "Retries", url: "https://jira.example/browse/PAY-1")
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) { $0.worktreePath = h.folder.path } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("manual-worker", tag: id, state: active == .primary ? .working : .done, conversation: "manual-conversation")]
        if active != .primary {
            var companion = OperatorServiceFixtures.session("manual-companion", tag: id, state: active == .companionPrompt ? .needsInput : .working, conversation: "companion-conversation")
            companion.agent = .codex; companion.tabIndex = 1; live.sessions.append(companion)
        }
        let native = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let router = ItemRouter(workspace: h.workspace, now: { world.now }, workerIsWorking: native.busy)
        _ = router.apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true))
        let stages = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: native.busy, prepare: native.prepare, launch: native.launch, restore: native.restore))
        await stages.run(id)
        #expect(daemon.requests("session.closeIdle").isEmpty && daemon.requests("window.createTask").isEmpty && daemon.requests("tab.create").isEmpty)
        for index in live.sessions.indices { live.sessions[index].state = .done }
        await stages.run(id)
        #expect(daemon.requests("session.closeIdle").count == 1)
        let opened = daemon.requests("window.createTask") + daemon.requests("tab.create")
        let command = try #require(opened.first?.params["agentCommand"] as? String)
        #expect(try guardedWorkerCommand(command)?.contains("manual-conversation") == true)
        #expect(h.workspace.state.tasks.count == 1 && h.workspace.state.tasks[0].id == id)
    }
    @Test(arguments: [false, true]) func steeringAWatchingTaskResumesWorkerObservation(extraTab: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) {
            $0.worktreePath = h.folder.path; $0.signalTask?.phase = .watching(.operatorJudges)
            $0.signalTask?.operatorJudged = true
        } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("worker", tag: id, state: .done, conversation: "steering")]
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let task = try #require(h.workspace.state.task(id: id))
        if extraTab { _ = try await io.openTab(task, key: "check", choice: SignalWorld.agent, prompt: "Inspect again.", why: "A new fact", allowed: { true }) }
        else { try await io.message(task, text: "Inspect again.", tab: "main", allowed: { true }) }
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        #expect(h.workspace.state.task(id: id)?.signalTask?.operatorJudged != true)
        #expect(h.workspace.state.task(id: id)?.signalTask?.needsWorkerReads == true)
    }
    @Test(arguments: [false, true], ["main", "check"]) func anAcceptedLaunchWithoutAWorkerEventuallyRequiresInspection(activeWorker: Bool, tab: String) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalTask(id) {
            $0.launch = LaunchAttempt(number: 1, requestedAt: world.now.addingTimeInterval(-200), openedAt: world.now.addingTimeInterval(-200))
            $0.pendingReplies = [tab: SignalWorkerReply(at: world.now.addingTimeInterval(-200), fingerprint: nil)]
            if tab != "main" { $0.extraTabs = [ExtraTab(key: tab, agent: .claude, model: SignalWorld.agent.model, reasoning: SignalWorld.agent.reasoning, modelReason: "Check", brief: "Inspect.", launch: LaunchAttempt(number: 1, requestedAt: world.now.addingTimeInterval(-200)))] }
        } }
        let live = LiveSessions(workspace: h.workspace), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        if activeWorker {
            var worker = OperatorServiceFixtures.session("worker", tag: id, state: .working, conversation: "still-working")
            worker.tabKey = tab == "main" ? nil : tab; live.sessions = [worker]
        }
        let instant = world.now
        var timed = ports; timed.clock.now = { instant }
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: timed,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        await io.refreshTurns()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == (activeWorker ? .working : .blocked))
        #expect(io.busy(id) == activeWorker, "Inspection must be able to resume a blocked launch.")
    }
    @Test func aFirstLaunchUsesTheAllowedAgentBelowItsWeeklyLimit() async throws {
        let codex = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        var world = SignalWorld(); let signal = world.signal(agents: [SignalWorld.agent, codex]), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) { $0.worktreePath = h.folder.path; $0.windowId = nil; $0.signalTask?.phase = .launching } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.usage = UsageSnapshot(claude: Usage(fiveHour: nil, sevenDay: .init(usedPercent: 80, resetsAt: nil), spend: nil, updatedAt: 1),
            codex: Usage(fiveHour: nil, sevenDay: .init(usedPercent: 20, resetsAt: nil), spend: nil, updatedAt: 1))
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        _ = try await io.launch(try #require(h.workspace.state.task(id: id)), prompt: "Work.")
        #expect(h.workspace.state.task(id: id)?.agent == .codex)
        #expect((daemon.requests("window.createTask").first?.params["agentCommand"] as? String)?.contains("launch-codex.sh") == true)
    }
    @Test(arguments: [false, true]) func anApiFailureBlocksTheStageInsteadOfReusingAnEarlierQuestion(hasConversation: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        var tab = OperatorServiceFixtures.session("worker", tag: id, state: .done, conversation: hasConversation ? "failed" : nil)
        tab.stoppedOn = StoppedOn(error: "billing_error")
        live.sessions = [tab]
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        await io.refreshTurns()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .blocked)
        #expect(h.workspace.state.task(id: id)?.signalTask?.blockedReason?.contains("billing") == true)
        #expect(io.question(id, tab: "main") == nil)
    }
    @Test func firstWorkerUsesGuardedPublishingProfileAndSavedLaunchIntent() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let harness = try SignalHarness(world); defer { harness.cleanUp() }
        harness.workspace.mutate { state in
            state.updateSignalItem(id) { $0.worktreePath = harness.folder.path; $0.windowId = nil; $0.signalTask?.phase = .launching }
        }
        let live = LiveSessions(workspace: harness.workspace), daemon = RecordingDaemon()
        let io = SignalWorkerIO(workspace: harness.workspace, live: live, work: WorkInFlight(), ports: .scratch(),
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let task = try #require(harness.workspace.state.task(id: id))
        let window = try await io.launch(task, prompt: "Use /psg:review.")
        #expect(!window.isEmpty)
        let command = try #require(daemon.requests("window.createTask").first?.params["agentCommand"] as? String)
        #expect(command.contains("launch-claude.sh"))
        let worker = try #require(try guardedWorkerCommand(command))
        #expect(worker.contains("AskUserQuestion"))
        #expect(!worker.contains("Bash(git push:*"))
        #expect(harness.workspace.state.task(id: id)?.signalTask?.pendingReplies?["main"] != nil)
        #expect(io.busy(id), "A successful window RPC before the first CLI hook must hold finish/Then.")
        try? FileManager.default.removeItem(at: io.ports.home)
    }
    @Test func takeoverBeforeLaunchCannotOpenAWorker() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let harness = try SignalHarness(world); defer { harness.cleanUp() }
        let live = LiveSessions(workspace: harness.workspace), daemon = RecordingDaemon()
        let io = SignalWorkerIO(workspace: harness.workspace, live: live, work: WorkInFlight(), ports: .scratch(),
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let stale = try #require(harness.workspace.state.task(id: id))
        harness.workspace.mutate { $0.updateSignalTask(id) { $0.takenOver = true; $0.ownership += 1 } }
        await #expect(throws: (any Error).self) { try await io.launch(stale, prompt: "Run.") }
        #expect(daemon.requests("window.createTask").isEmpty)
    }
    @Test func extraWorkTabPersistsItsKeyAndARepeatedOpenAdoptsIt() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) { $0.worktreePath = h.folder.path } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: .scratch(),
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let task = try #require(h.workspace.state.task(id: id))
        let opened = try await io.openTab(task, key: "check", choice: SignalWorld.agent, prompt: "Inspect the failure.", why: "Second task", allowed: { true })
        let current = try #require(h.workspace.state.task(id: id))
        let replay = try await io.openTab(current, key: "check", choice: SignalWorld.agent, prompt: "Inspect the failure.", why: "Second task", allowed: { true })
        #expect(opened == replay)
        #expect(daemon.requests("tab.create").count == 1)
        #expect(current.signalTask?.extraTabs.first?.key == "check")
        #expect(current.signalTask?.pendingReplies?["check"] != nil)
        try? FileManager.default.removeItem(at: io.ports.home)
    }
    @Test func anEndedWorkerQuestionKeepsItsStageBusyUntilAnAgreedAnswerIsSent() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let folder = ports.claudeConfig.directory(home: ports.home).appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Question: Should retries be capped?"}]}}"# + "\n"
        try text.write(to: folder.appendingPathComponent("question-test.jsonl"), atomically: true, encoding: .utf8)
        live.sessions = [OperatorServiceFixtures.session("worker", tag: id, state: .done, conversation: "question-test")]
        await io.refreshTurns()
        #expect(io.question(id, tab: "main")?.text.contains("Should retries") == true)
        #expect(io.busy(id), "A source condition must not finish a stage while its worker asks a question.")
        let task = try #require(h.workspace.state.task(id: id))
        try await io.message(task, text: "Use the cap in the plan.", tab: "main", allowed: { true })
        #expect(io.question(id, tab: "main") == nil)
        #expect(io.busy(id), "The saved answer waits for a new reply, rather than re-reading the old question.")
    }
    @Test func anUncheckedWorkerCannotStartAHeadlessStage() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) { $0.worktreePath = h.folder.path; $0.windowId = nil } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        daemon.deliveryVerdicts[.claude] = DeliveryVerdict(policy: .off, version: "2.1.301")
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        await #expect(throws: (any Error).self) { try await io.launch(try #require(h.workspace.state.task(id: id)), prompt: "Run.") }
        #expect(daemon.requests("window.createTask").isEmpty)
        try? FileManager.default.removeItem(at: ports.home)
    }
    @Test(arguments: [false, true]) func anInterruptedLaunchAdoptsItsGuardedWorkerWithoutRepeatingThePrompt(invalidScope: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) {
            $0.worktreePath = h.folder.path; $0.windowId = nil; $0.signalTask?.phase = .launching
            $0.signalTask?.launch = LaunchAttempt(number: 1, requestedAt: world.now, workerPending: true)
        } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let task = try #require(h.workspace.state.task(id: id))
        var scope = WorkerGuard.Scope(task: id, worktree: task.worktreePath, branch: task.branch, remote: world.project.remoteUrl!, allowsPush: true)
        scope.stage = task.signalTask?.stage; scope.ownership = invalidScope ? 99 : task.signalTask!.ownership
        _ = try WorkerGuardLaunch.prepare(scope: scope, home: ports.home, executable: ports.workerGuardExecutable)
        live.sessions = [OperatorServiceFixtures.session("already-started", window: "existing-window", tag: id, state: .working, conversation: "existing-conversation")]
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        await io.recoverLaunches()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == (invalidScope ? .blocked : .working))
        if !invalidScope { #expect(h.workspace.state.task(id: id)?.windowId == "existing-window") }
        #expect(daemon.requests.isEmpty, "Recovery observes the tagged worker; it never sends another prompt or closes it")
    }
}
