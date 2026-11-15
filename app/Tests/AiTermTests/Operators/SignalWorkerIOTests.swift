import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalWorkerIOTests {
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
