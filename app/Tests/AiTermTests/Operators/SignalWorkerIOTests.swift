import Foundation
import Testing
import Synchronization
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalWorkerIOTests {
    private func expectQuestionInstruction(_ request: RecordingDaemon.Request?, in folder: URL) throws {
        let request = try #require(request)
        #expect(request.params["worker"] as? Bool == true)
        let launch = try #require(try guardedWorkerCommand(request.params["agentCommand"] as? String))
        let prompt: String
        if let file = launch.range(of: #"\.aiterm/signal-[0-9A-Fa-f-]+\.md"#, options: .regularExpression) {
            prompt = try String(contentsOf: folder.appendingPathComponent(String(launch[file])), encoding: .utf8)
        } else {
            prompt = launch
        }
        #expect(prompt.contains(WorkerPrompt.askLine))
    }

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
            workerIsWorking: io.busy, prepare: { task, _ in task }, launch: { try await io.launch($0, prompt: $1) }, restore: { $0 }))
        await stages.run(id)
        #expect(daemon.requests("window.createTask").count == 1)
        try expectQuestionInstruction(daemon.requests("window.createTask").first, in: h.folder)
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
        await #expect(throws: SignalTransitionError.self) { try await stages.finish(id, action: .finish) }
        #expect(wakes.isEmpty && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        // The tick every tool reply triggers observes the companion's work.
        await io.refreshTurns()
        #expect(wakes.isEmpty)
        live.sessions[1].state = .done
        await io.refreshTurns()
        #expect(wakes == [id])
        await io.refreshTurns()
        #expect(wakes == [id])
        try await stages.finish(id, action: .finish)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
    }
    /// `busy` only answers. The `worker_ended` wake comes from the ticks: work one tick saw that the next does not.
    @Test func busyChangesNothingAndWorkTwoTicksSawEndGetsOneWake() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("primary", tag: id, state: .working)]
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        var wakes: [UUID] = []; io.onTurn = { wakes.append($0) }
        #expect(io.busy(id) && io.busy(id))
        live.sessions[0].state = .done
        await io.refreshTurns()
        #expect(wakes.isEmpty, "No tick saw the work that busy was asked about.")
        live.sessions[0].state = .working
        await io.refreshTurns()
        #expect(wakes.isEmpty)
        live.sessions[0].state = .done
        await io.refreshTurns()
        #expect(wakes == [id])
        await io.refreshTurns()
        #expect(wakes == [id])
    }
    @Test(arguments: AgentKind.allCases)
    func aHelperTabIsCardWorkAndCannotWakeTheOperator(agent: AgentKind) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { nil }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        var wakes: [UUID] = []; io.onTurn = { wakes.append($0) }
        var worker = OperatorServiceFixtures.session("primary", tag: id, state: .done, conversation: "primary")
        worker.tabRole = .worker
        var helper = OperatorServiceFixtures.session("helper", tag: id, state: .working, conversation: "helper")
        helper.tabRole = .helper; helper.tabKey = "review"; helper.agent = agent.session
        live.sessions = [worker, helper]
        await io.refreshTurns()
        let digest = OperatorDigest(state: h.workspace.state, at: world.now, oracleOn: false, sessions: live.sessions)
        #expect(digest.workers.map(\.session) == [worker.sessionId])
        #expect(h.workspace.state.task(id: id)?.firstWorker(in: live.sessions) == worker)
        #expect(SidebarModel.displayJobs(of: live.sessions).map(\.label) == ["review"])
        #expect(!io.busy(id))
        live.sessions = [worker]
        await io.refreshTurns()
        #expect(wakes.isEmpty && SidebarModel.displayJobs(of: live.sessions).isEmpty)
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
            workerIsWorking: native.busy, prepare: { task, _ in task }, launch: { try await native.launch($0, prompt: $1) }, restore: { $0 }))
        await stages.run(id)
        #expect(daemon.requests("session.closeIdle").isEmpty && daemon.requests("window.createTask").isEmpty && daemon.requests("tab.create").isEmpty)
        for index in live.sessions.indices { live.sessions[index].state = .done }
        await stages.run(id)
        #expect(daemon.requests("session.closeIdle").count == 1)
        let opened = daemon.requests("window.createTask") + daemon.requests("tab.create")
        try expectQuestionInstruction(opened.first, in: h.folder)
        let command = try #require(opened.first?.params["agentCommand"] as? String)
        #expect(try guardedWorkerCommand(command)?.contains("manual-conversation") == true)
        #expect(h.workspace.state.tasks.count == 1 && h.workspace.state.tasks[0].id == id)
    }
    @Test(arguments: [false, true]) func steeringAWatchingTaskResumesWorkerObservation(extraTab: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) {
            $0.worktreePath = h.folder.path; $0.signalTask?.phase = .watching
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
    /// The main worker counts only as a listed agent: `workerTab` gives a first tab even when none is open.
    @Test func aTaskHasAMainWorkerOnlyWhileItsAgentIsListed() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let live = LiveSessions(workspace: h.workspace), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { RecordingDaemon() }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let task = try #require(h.workspace.state.task(id: id))
        #expect(task.workerTab("main", in: live.sessions) != nil && !io.hasMainWorker(task))
        live.sessions = [OperatorServiceFixtures.session("worker", tag: id, state: .done, conversation: "steering")]
        #expect(io.hasMainWorker(task))
    }
    /// The carry-on line after AiTerm's merge is saved as sent in the same change that saves the reply it waits for, by a
    /// message or a resumed launch alike; a worker that cannot take it leaves it owed.
    @Test(arguments: ["message", "launch", "busy"]) func aHandBackIsSavedAsMadeWithThePendingReply(_ path: String) async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) {
            $0.worktreePath = h.folder.path
            $0.signalTask?.phase = path == "launch" ? .launching : .watching
            if path == "launch" { $0.windowId = nil }
            $0.signalTask?.merge = SignalMerge(request: SignalRequestRef(remote: "git@git.example:shop/web.git", number: 7), head: "aabbcc")
        } }
        h.workspace.flush()
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        if path != "launch" {
            live.sessions = [OperatorServiceFixtures.session("worker", tag: id, state: path == "busy" ? .working : .done, conversation: "steering")]
        }
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
            daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        let task = try #require(h.workspace.state.task(id: id))
        let made: (inout SignalTask) -> Void = { $0.merge?.handBackOwed = false }
        switch path {
        case "launch": _ = try await io.launch(task, prompt: "AiTerm merged !7 at aabbcc; carry on.", saving: made)
        case "busy":
            await #expect(throws: ActionUnavailable.self) {
                try await io.message(task, text: "AiTerm merged !7 at aabbcc; carry on.", tab: "main", allowed: { true }, saving: made)
            }
            #expect(try h.file.load().task(id: id)?.signalTask?.merge?.handBackOwed == true)
            return
        default: try await io.message(task, text: "AiTerm merged !7 at aabbcc; carry on.", tab: "main", allowed: { true }, saving: made)
        }
        let saved = try #require(try h.file.load().task(id: id)?.signalTask)
        #expect(saved.merge?.handBackOwed == false && saved.pendingReplies?["main"] != nil)
        if path == "message" { #expect(saved.phase == .working) }
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
        harness.workspace.mutate { $0.takeOver(id) }
        await #expect(throws: (any Error).self) { try await io.launch(stale, prompt: "Run.") }
        #expect(daemon.requests("window.createTask").isEmpty)
    }
    /// The checkout monitor's pass as the app runs it, except that it finds each project's remote as the project has
    /// it. The fixture's repository stands for the request's GitLab project but has no origin, and a pass that read
    /// that would make the project a plain git one; one landing before the stage reads the project (the helper's
    /// attach asks for one) would leave the stage no host to find its request on.
    nonisolated static let keepingTheRequestsRemote: CheckoutMonitor.Scanner = { cwds, projects, tasks, branches, remotes, diffs in
        var scan = WorkspaceScan.run(cwds: cwds, projects: projects, tasks: tasks, branches: branches, remotes: remotes, diffs: diffs)
        scan.remotes = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, WorkspaceScan.Remote(provider: $0.provider, url: $0.remoteUrl)) })
        return scan
    }
    /// The stage's checkout is the app's (`TaskLauncher.checkOutWorker`): a Take Over that lands while git makes a
    /// request task's worktree leaves the task with that worktree's folder and launches no worker.
    @Test(.blocking) func takeOverDuringARequestCheckoutKeepsItsFolderAndBaseBranchWithoutLaunchingAWorker() async throws {
        let git = CheckoutHeldGit()
        let fixture = try await RaceFixture(scan: Self.keepingTheRequestsRemote, provider: .gitlab, remoteUrl: "git@git.example:shop/web.git", controllerGit: git)
        let controller = fixture.controller, server = RecordingDaemon()
        defer { git.release(); controller.shutdown(); fixture.cleanUp() }
        let repo = fixture.repo.path, setup = fixture.git
        try await BackgroundWork.run { _ = try setup.run(["branch", "work"], in: repo) }
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalItem(id) {
            $0.projectId = fixture.project.id
            $0.branch = "work"; $0.worktreePath = ""; $0.baseBranch = ""; $0.windowId = nil
            $0.mr = .init(iid: 7, title: "Work", url: "https://git.example/shop/web/-/merge_requests/7")
            $0.signalTask?.phase = .launching
        }
        controller.workspace.mutate { state in
            state.signals = world.state.signals; state.tasks = world.state.tasks; state.operatorSession = world.state.operatorSession
        }
        #expect(controller.workspace.flush())
        let stub = StubSession { _ in
            (200, Data(#"[{"iid":7,"title":"Work","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"opened","source_project_id":1,"target_project_id":1}]"#.utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        controller.signalController.readConnections = { links }
        controller.helper.setDaemonClient(server)
        // The attach asks the checkout monitor for a pass: it lands before the stage starts, not at a moment of the host's choosing.
        await controller.checkouts.refreshTask?.value
        let root = controller.signalController
        root.sourceRegistrations = { _ in [] }
        root.start(); await root.ports.work.settled()
        let checkout = Task { await root.stages.run(id) }
        // The stage reads the request before git runs: on a loaded host that can take a while.
        try #require(await eventually(describing: "the checkout reaching git") { git.reached })
        await controller.takeOver(id)
        #expect(controller.state.task(id: id)?.signalTask == nil && controller.state.task(id: id)?.takenOver == true)
        #expect(controller.state.task(id: id)?.hasCheckout == false)
        git.release(); await checkout.value
        let task = try #require(controller.state.task(id: id))
        #expect(task.worktreePath == repo + "/.worktrees/review-work")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(task.baseBranch == "main")
        #expect(task.signalTask == nil && task.takenOver)
        #expect(server.requests("window.createTask").isEmpty && server.requests("tab.create").isEmpty,
                "The finished checkout cannot launch a worker after Take Over.")
    }
    /// A Take Over that lands while the stage still reads the request, before git runs, leaves that checkout to finish
    /// for the person: the task gets its worktree on the request's source branch, and the Operator opens no worker.
    /// A read that then fails is said on the task, as no one else would say it.
    @Test(.blocking, arguments: [false, true])
    func takeOverWhileTheStageReadsTheRequestStillLeavesTheTaskItsWorktree(readFails: Bool) async throws {
        let fixture = try await RaceFixture(scan: Self.keepingTheRequestsRemote, provider: .gitlab, remoteUrl: "git@git.example:shop/web.git")
        let controller = fixture.controller, server = RecordingDaemon()
        let read = HeldRead()
        defer { read.release(); controller.shutdown(); fixture.cleanUp() }
        let repo = fixture.repo.path, setup = fixture.git
        try await BackgroundWork.run { _ = try setup.run(["branch", "work"], in: repo) }
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalItem(id) {
            $0.projectId = fixture.project.id
            $0.branch = "work"; $0.worktreePath = ""; $0.baseBranch = ""; $0.windowId = nil
            $0.mr = .init(iid: 7, title: "Work", url: "https://git.example/shop/web/-/merge_requests/7")
            $0.signalTask?.phase = .launching
        }
        controller.workspace.mutate { state in
            state.signals = world.state.signals; state.tasks = world.state.tasks; state.operatorSession = world.state.operatorSession
        }
        #expect(controller.workspace.flush())
        let stub = StubSession { _ in
            read.hold()
            if readFails { return (500, Data("{}".utf8)) }
            return (200, Data(#"[{"iid":7,"title":"Work","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/web/-/merge_requests/7","state":"opened","source_project_id":1,"target_project_id":1}]"#.utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        controller.signalController.readConnections = { links }
        controller.helper.setDaemonClient(server)
        // The attach asks the checkout monitor for a pass: it lands before the stage starts, not at a moment of the host's choosing.
        await controller.checkouts.refreshTask?.value
        let root = controller.signalController
        root.sourceRegistrations = { _ in [] }
        root.start(); await root.ports.work.settled()
        let stage = Task { await root.stages.run(id) }
        try #require(await eventually(describing: "the stage reading the request") { read.reached })
        await controller.takeOver(id)
        #expect(controller.state.task(id: id)?.hasCheckout == false, "The stage's checkout is still under way.")
        read.release(); await stage.value
        #expect(server.requests("window.createTask").isEmpty && server.requests("tab.create").isEmpty,
                "The finished checkout cannot launch a worker after Take Over.")
        if readFails {
            let task = try #require(controller.state.task(id: id))
            #expect(task.signalTask == nil && task.takenOver && !task.hasCheckout)
            #expect(controller.issue?.title == "The task is yours, but its worktree couldn’t be made." && controller.issue?.subject == id)
            #expect(controller.issue?.reason != nil)
            return
        }
        try #require(await eventually(describing: "the checkout saved") { controller.state.task(id: id)?.hasCheckout == true })
        let task = try #require(controller.state.task(id: id))
        #expect(task.signalTask == nil && task.takenOver)
        #expect(task.worktreePath == repo + "/.worktrees/review-work" && task.baseBranch == "main")
        let path = task.worktreePath
        let head = try await BackgroundWork.run { try setup.run(["rev-parse", "--abbrev-ref", "HEAD"], in: path) }
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "work")
        #expect(controller.issue == nil)
    }
    /// A stage for a request item checks out the request's source branch through the app's checkout, and refuses a
    /// fork's, whose source branch is not in this repository.
    @Test(.blocking, arguments: [false, true]) func aRequestStageChecksOutItsSourceBranchAndRefusesAFork(fork: Bool) async throws {
        let fixture = try await RaceFixture(scan: Self.keepingTheRequestsRemote, provider: .gitlab, remoteUrl: "git@git.example:shop/web.git")
        let controller = fixture.controller
        defer { controller.shutdown(); fixture.cleanUp() }
        let repo = fixture.repo.path, setup = fixture.git
        try await BackgroundWork.run { _ = try setup.run(["branch", "work"], in: repo) }
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalItem(id) {
            $0.projectId = fixture.project.id
            $0.branch = "work"; $0.worktreePath = ""; $0.baseBranch = ""; $0.windowId = nil
            $0.mr = .init(iid: 7, title: "Work", url: "https://git.example/shop/web/-/merge_requests/7")
            $0.signalTask?.phase = .launching
        }
        controller.workspace.mutate { state in
            state.signals = world.state.signals; state.tasks = world.state.tasks; state.operatorSession = world.state.operatorSession
        }
        #expect(controller.workspace.flush())
        let stub = StubSession { _ in
            (200, Data("[{\"iid\":7,\"title\":\"Work\",\"source_branch\":\"work\",\"target_branch\":\"main\",\"web_url\":\"https://git.example/shop/web/-/merge_requests/7\",\"state\":\"opened\",\"source_project_id\":\(fork ? 2 : 1),\"target_project_id\":1}]".utf8))
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        controller.signalController.readConnections = { links }
        let root = controller.signalController
        root.sourceRegistrations = { _ in [] }
        root.start(); await root.ports.work.settled()

        // No helper: once its checkout is made, the stage's worker cannot start, and the stage blocks.
        await root.stages.run(id)

        let current = try #require(controller.state.task(id: id))
        #expect(current.signalTask?.phase == .blocked)
        if fork {
            #expect(current.signalTask?.blockedReason == "The request's source branch is unavailable in this repository. Open it yourself to choose its checkout.")
            #expect(!current.hasCheckout)
        } else {
            #expect(current.worktreePath == repo + "/.worktrees/review-work", "saved on the task")
            #expect(current.baseBranch == "main")
            let head = try await BackgroundWork.run { try setup.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo + "/.worktrees/review-work") }
            #expect(head == "work")
        }
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
        try expectQuestionInstruction(daemon.requests("tab.create").first, in: h.folder)
        #expect(current.signalTask?.extraTabs.first?.key == "check")
        #expect(current.signalTask?.pendingReplies?["check"] != nil)
        try? FileManager.default.removeItem(at: io.ports.home)
    }
    /// A work tab that opened but whose agent command was never typed is no launch: the Operator gets the daemon's
    /// reason, and the tab's launch stays unopened.
    @Test func anExtraWorkTabWhoseCommandWasNotTypedStaysUnopened() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) { $0.worktreePath = h.folder.path } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon()
        daemon.commandErrors["tab.create"] = "The session ended before the command was typed."
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: .scratch(),
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        defer { try? FileManager.default.removeItem(at: io.ports.home) }
        let task = try #require(h.workspace.state.task(id: id))
        var refusal: String?
        do {
            _ = try await io.openTab(task, key: "check", choice: SignalWorld.agent, prompt: "Inspect the failure.", why: "Second task", allowed: { true })
        } catch let error as ActionUnavailable { refusal = error.message }
        #expect(refusal == "The session ended before the command was typed.")
        #expect(daemon.requests("tab.create").count == 1)
        let tab = try #require(h.workspace.state.task(id: id)?.signalTask?.extraTabs.first { $0.key == "check" })
        #expect(tab.sessionId == nil && tab.launch.openedAt == nil)
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
    @Test(arguments: [false, true]) func anInterruptedLaunchAdoptsItsTaggedWorkerWithoutRepeatingThePrompt(plannedAgent: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalItem(id) {
            $0.worktreePath = h.folder.path; $0.windowId = nil; $0.signalTask?.phase = .launching
            $0.signalTask?.launch = LaunchAttempt(number: 1, requestedAt: world.now, workerPending: true)
        } }
        let live = LiveSessions(workspace: h.workspace), daemon = RecordingDaemon(), ports = OperatorPorts.scratch()
        defer { try? FileManager.default.removeItem(at: ports.home) }
        live.sessions = [OperatorServiceFixtures.session("already-started", window: "existing-window", tag: id,
            agent: plannedAgent ? .claude : .codex, state: .working, conversation: "existing-conversation")]
        let io = SignalWorkerIO(workspace: h.workspace, live: live, work: WorkInFlight(), ports: ports,
                                daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) })
        io.recoverLaunches()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == (plannedAgent ? .working : .blocked))
        if plannedAgent { #expect(h.workspace.state.task(id: id)?.windowId == "existing-window") }
        #expect(daemon.requests.isEmpty, "Recovery observes the tagged worker; it never sends another prompt or closes it")
    }
}

/// A host read held until released, so a Take Over can land while the stage waits for it.
private final class HeldRead: Sendable {
    private let entered = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)
    var reached: Bool { entered.withLock { $0 } }
    func release() { gate.signal() }
    func hold() {
        entered.withLock { $0 = true }
        _ = gate.wait(timeout: .now() + TestDeadline.seconds)
    }
}
private final class CheckoutHeldGit: GitRunning {
    private let entered = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)
    private let inner = GitRunner.hermetic()
    /// Whether a `git worktree add` has reached the hold.
    var reached: Bool { entered.withLock { $0 } }
    func release() { gate.signal() }
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.starts(with: ["worktree", "add"]) {
            entered.withLock { $0 = true }
            guard gate.wait(timeout: .now() + TestDeadline.seconds) == .success else {
                throw ActionUnavailable("Timed out waiting for Take Over during checkout.")
            }
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
