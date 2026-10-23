import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// `open_tab`: another worker tab on a running task, in its window and worktree, behind your work. Recorded on the task
/// before the daemon is asked, so the reconciler and a restart adopt the tab tagged for it and never open a second.
@MainActor @Suite(.blocking) struct OperatorOpenTabTests {
    let clock = TestClock.operators()
    let git = GitRunner.hermetic()

    /// An active run with one task in `state`, its worktree a real checkout off `main` and its window `w1` open,
    /// its first worker at work there and the Operator's tab listed.
    func makeWorld(state: OperatedState = .working, daemon: RecordingDaemon = RecordingDaemon(), change: (inout TaskItem) -> Void = { _ in },
                   adjust: @escaping (inout OperatorPorts) -> Void = { _ in }) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-tab-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: state)
        task = try TaskCreator.checkOutWorker(task, project: project, start: "main", git: git).task
        task.windowId = "w1"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        change(&task)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon) { [clock] ports in
            ports.now = { clock.now }
            adjust(&ports)
        }
        world.show(Self.tabs(run: run, task: task))
        return (world, run, task)
    }

    /// The Operator's tab and the task's first worker, and any `extra` tab.
    static func tabs(run: OperatorRun, task: TaskItem, extra: [SessionInfo] = []) -> [SessionInfo] {
        [OperatorServiceFixtures.session("op", window: "wop", tag: run.id),
         OperatorServiceFixtures.session("s1", tag: task.id, state: .working)] + extra
    }

    /// A tab the daemon tagged with the task and `key`.
    static func extraTab(_ id: String, of task: TaskItem, key: String) -> SessionInfo {
        var session = OperatorServiceFixtures.session(id, tag: task.id, agent: .codex, state: .working)
        session.tabIndex = 1
        session.tabKey = key
        return session
    }

    static func arguments(key: String = "review", agent: String = "codex", model: String? = "gpt-6-mini", brief: String = "Write the tests.",
                          pinned: Bool? = nil) -> JSONValue {
        var arguments: [String: JSONValue] = ["task": "PLUTO-1", "key": .string(key), "agent": .string(agent),
                                              "modelReason": "Codex writes tests well.", "brief": .string(brief)]
        if let model { arguments["model"] = .string(model) }
        if let pinned { arguments["agentPinned"] = .bool(pinned) }
        return .object(arguments)
    }

    func tabs(of task: TaskItem, in world: OperatorWorld) -> [ExtraTab] { world.task(task.id)?.operated?.extraTabs ?? [] }

    // -- opening -------------------------------------------------------------------------------------

    /// `main` is what `run_status` calls the task's first worker among its tabs: no extra tab takes it.
    @Test func theFirstWorkersNameIsRefusedAsAKey() async throws {
        let (world, run, task) = try makeWorld()
        #expect(await world.call(run.id, "open_tab", Self.arguments(key: "main")).message
                == "The key main names PLUTO-1’s first worker in run_status. Call open_tab with another key.")
        #expect(tabs(of: task, in: world).isEmpty && world.daemon.requests("tab.create").isEmpty)
    }

    @Test func itOpensInTheTasksWindowAndWorktreeBehindYourWorkWithAiTermsLinesThenTheBrief() async throws {
        let (world, run, task) = try makeWorld()
        let brief = "Write the tests.\n\n" + String(repeating: "Cover every refusal. ", count: 80) + "Then stop."
        let answer = await world.call(run.id, "open_tab", Self.arguments(brief: brief))
        #expect(answer.value == ["task": "PLUTO-1", "key": "review", "agent": "codex", "model": "gpt-6-mini", "state": "opened"])
        let request = try #require(world.daemon.requests("tab.create").first)
        #expect(request.params["windowId"] as? String == "w1")
        #expect(request.params["cwd"] as? String == task.worktreePath)
        #expect(request.params["tabKey"] as? String == "review")
        #expect(request.params["background"] as? Bool == true)
        let file = TabOpener.promptFile(for: "review")
        #expect(request.params["agentCommand"] as? String
                == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-6-mini \"$(command cat .aiterm/\(file))\"")
        let prompt = try String(contentsOfFile: task.worktreePath + "/.aiterm/" + file, encoding: .utf8)
        #expect(prompt == WorkerStarter.worktreeLine(branch: task.branch) + "\n\n" + TabOpener.sharedLine + "\n\n" + brief)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath + "/.aiterm/first-prompt.md"), "the first worker's file is its own")
        let tab = try #require(tabs(of: task, in: world).first)
        #expect(tab.key == "review" && tab.agent == .codex && tab.model == "gpt-6-mini" && tab.reasoning == nil)
        #expect(tab.modelReason == "Codex writes tests well." && tab.brief == brief && !tab.agentPinned)
        #expect(tab.sessionId == "s-review" && tab.launch.number == 1 && tab.launch.openedAt == clock.now && tab.failure == nil)
        #expect(world.task(task.id)?.operated?.state == .working, "the task stays one task")
    }

    @Test func aShortFirstPromptIsTypedWithTheCommandItStartsWithAiTermsLines() async throws {
        let (world, run, task) = try makeWorld()
        #expect(await world.call(run.id, "open_tab", Self.arguments(agent: "claude", model: "claude-named")).value?["state"] == "opened")
        let command = try #require(world.daemon.requests("tab.create").first?.params["agentCommand"] as? String)
        let prompt = TabOpener.prompt(branch: task.branch, brief: "Write the tests.")
        #expect(prompt.contains("Inventories, audits and lists go in your final message, never in a new file in the repository."))
        #expect(prompt.hasPrefix(WorkerStarter.worktreeLine(branch: task.branch) + "\n\n" + TabOpener.sharedLine + "\n\n"))
        #expect(command.hasPrefix("claude --model claude-named ") && command.hasSuffix(AgentCommand.shellQuote(prompt)))
        #expect(command.contains("--permission-mode auto"), "the Operator's worker flags")
    }

    @Test func aTaskInReviewTakesATab() async throws {
        let (world, run, _) = try makeWorld(state: .inReview)
        #expect(await world.call(run.id, "open_tab", Self.arguments()).value?["state"] == "opened")
    }

    @Test func thePromptFilesOfTwoKeysAreTheirOwnAndPlainNames() {
        let names = ["review", "review 2", "a/b; rm -rf"].map(TabOpener.promptFile(for:))
        #expect(Set(names).count == 3)
        #expect(names.allSatisfy { $0.wholeMatch(of: #/first-prompt-tab-[0-9a-f]{12}\.md/#) != nil })
    }

    // -- the same key --------------------------------------------------------------------------------

    @Test func theSameKeyReturnsTheFirstCallsTabAndOpensNothingMore() async throws {
        let (world, run, task) = try makeWorld()
        let first = await world.call(run.id, "open_tab", Self.arguments())
        #expect(await world.call(run.id, "open_tab", Self.arguments()) == first)
        #expect(await world.call(run.id, "open_tab", Self.arguments(model: nil)) == first, "a model left out is the one recorded")
        #expect(world.daemon.requests("tab.create").count == 1 && tabs(of: task, in: world).count == 1)
        #expect(await world.call(run.id, "open_tab", Self.arguments(key: "docs")).value?["key"] == "docs")
        #expect(world.daemon.requests("tab.create").map { $0.params["tabKey"] as? String } == ["review", "docs"])
        #expect(tabs(of: task, in: world).map(\.key) == ["review", "docs"])
    }

    @Test func theSameKeyWithOtherArgumentsIsRefused() async throws {
        let (world, run, task) = try makeWorld()
        _ = await world.call(run.id, "open_tab", Self.arguments())
        let refusal = "PLUTO-1 already has a tab review, opened with other arguments. Call open_tab with another key for another tab."
        for other in [Self.arguments(brief: "Write the docs."), Self.arguments(model: "gpt-6-astra"), Self.arguments(agent: "claude", model: nil),
                      Self.arguments(pinned: true)] {
            #expect(await world.call(run.id, "open_tab", other).message == refusal)
        }
        #expect(world.daemon.requests("tab.create").count == 1 && tabs(of: task, in: world).count == 1)
    }

    @Test func theSameKeyAnswersAsRecordedOnceTheTaskMovedOn() async throws {
        let (world, run, task) = try makeWorld()
        let first = await world.call(run.id, "open_tab", Self.arguments())
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .accepted } }
        #expect(await world.call(run.id, "open_tab", Self.arguments()) == first)
    }

    // -- refusals ------------------------------------------------------------------------------------

    @Test(arguments: [OperatedState.planned, .accepted, .published, .noChange, .blocked, .failed])
    func aTaskThatIsNotWorkingOrInReviewIsRefused(_ state: OperatedState) async throws {
        let (world, run, task) = try makeWorld(state: state)
        #expect(await world.call(run.id, "open_tab", Self.arguments()).message
                == "PLUTO-1 is \(state.rawValue): only a working task, or one in review, takes another tab.")
        #expect(world.daemon.requests("tab.create").isEmpty && tabs(of: task, in: world).isEmpty)
    }

    @Test func aTaskTakenOverIsRefused() async throws {
        let (world, run, task) = try makeWorld { $0.operated?.takenOver = true }
        #expect(await world.call(run.id, "open_tab", Self.arguments()).message == "The person took over PLUTO-1. Leave it until they hand it back.")
        #expect(world.daemon.requests("tab.create").isEmpty && tabs(of: task, in: world).isEmpty)
    }

    @Test func aTaskWithNoWorktreeOrNoWindowIsRefused() async throws {
        let (noWorktree, run, task) = try makeWorld { $0.worktreePath = "" }
        #expect(await noWorktree.call(run.id, "open_tab", Self.arguments()).message == "PLUTO-1 hasn’t started: it has no worktree yet.")
        #expect(tabs(of: task, in: noWorktree).isEmpty)
        let (noWindow, other, closed) = try makeWorld { $0.windowId = nil }
        #expect(await noWindow.call(other.id, "open_tab", Self.arguments()).message
                == "PLUTO-1’s window isn’t open right now, so there is nowhere to add a tab.")
        #expect(noWindow.daemon.requests("tab.create").isEmpty && tabs(of: closed, in: noWindow).isEmpty)
    }

    @Test func aBroadcastPausedOfflineOrStoppedIsRefused() async throws {
        let cases: [(OperatorRunState, OperatorRunState?, String)] = [
            (.paused, .paused, "The person paused this broadcast. Wait until they resume it."),
            (.active, .paused, "The person paused this broadcast. Wait until they resume it."),
            (.operatorOffline, nil, "AiTerm has this broadcast offline; it resumes it first."),
            (.active, .stopped, "This broadcast has ended; its tools no longer act."),
            (.stopped, nil, "This broadcast has ended; its tools no longer act."),
        ]
        for (runState, intent, refusal) in cases {
            let (world, run, task) = try makeWorld()
            world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = runState; $0.intent = intent } }
            #expect(await world.call(run.id, "open_tab", Self.arguments()).message == refusal, "\(runState) \(String(describing: intent))")
            #expect(world.daemon.requests("tab.create").isEmpty && tabs(of: task, in: world).isEmpty)
        }
    }

    @Test func anAgentOrModelCreateTaskWouldRefuseIsRefused() async throws {
        let (world, run, task) = try makeWorld { _ in } adjust: { $0.installedAgents = { [.claude] } }
        #expect(await world.call(run.id, "open_tab", Self.arguments(agent: "pi")).message == "The Operator’s task runs claude or codex.")
        #expect(await world.call(run.id, "open_tab", Self.arguments()).message
                == "Codex isn’t installed on this Mac. Choose an installed agent from run_status.")
        #expect(await world.call(run.id, "open_tab", Self.arguments(agent: "claude", model: "claude-9")).message
                == "claude-9 isn’t in Claude Code’s model list in Settings › Agents. Its models are: claude-opus-5-5, claude-named, claude-other.")
        #expect(world.daemon.requests("tab.create").isEmpty && tabs(of: task, in: world).isEmpty)
    }

    @Test func anAgentWhoseWorkersCannotBeMessagedIsRefusedWhileAnotherCanUnlessPinned() async throws {
        let daemon = RecordingDaemon()
        daemon.deliveryVerdicts[.codex] = DeliveryVerdict(policy: .off, version: "0.160.0")
        let (world, run, task) = try makeWorld(daemon: daemon)
        let refused = try #require(await world.call(run.id, "open_tab", Self.arguments()).message)
        #expect(refused.hasPrefix("Codex’s workers can’t be messaged: ") && refused.contains("set agentPinned"))
        #expect(world.daemon.requests("tab.create").isEmpty && tabs(of: task, in: world).isEmpty)
        let pinned = try #require(await world.call(run.id, "open_tab", Self.arguments(pinned: true)).value)
        #expect(pinned["state"] == "opened" && pinned["warning"]?.stringValue?.contains("can’t be messaged") == true)
        #expect(tabs(of: task, in: world).first?.agentPinned == true)
    }

    // -- recorded before it is asked for -------------------------------------------------------------

    /// The daemon never answers: the tab is on disk already, and AiTerm restarted adopts the tab tagged for it,
    /// opening no second one, a minute on and after.
    @Test func aRequestThatNeverAnswersLeavesTheRecordAndARestartAdoptsTheTaggedTab() async throws {
        let held = RecordingDaemon(holding: "tab.create")
        let (world, run, task) = try makeWorld(daemon: held)
        let call = Task { await world.call(run.id, "open_tab", Self.arguments()) }
        try await held.received("tab.create")
        let saved = try #require(try world.workspace.file.load().task(id: task.id)?.operated?.extraTabs.first)
        #expect(saved.key == "review" && saved.sessionId == nil && saved.launch.openedAt == nil)

        let restarted = try OperatorWorld(try world.workspace.file.load()) { [clock] ports in ports.now = { clock.now } }
        restarted.show(Self.tabs(run: run, task: task, extra: [Self.extraTab("s9", of: task, key: "review")]))
        restarted.controller.reconcileTick()
        let adopted = try #require(tabs(of: task, in: restarted).first)
        #expect(adopted.sessionId == "s9" && adopted.launch.openedAt == clock.now)
        clock.advance(by: 61)
        restarted.controller.reconcileTick()
        await restarted.controller.reconciler.lastTab?.value
        #expect(restarted.daemon.requests("tab.create").isEmpty)
        #expect(await restarted.call(run.id, "open_tab", Self.arguments()).value?["state"] == "opened")

        held.failing["tab.create"] = .timeout
        held.release()
        #expect(await call.value.value?["state"] == "opening")
    }

    @Test func aRequestThatTimedOutIsAdoptedOnceItsTabIsListed() async throws {
        let (world, run, task) = try makeWorld(daemon: RecordingDaemon(failing: ["tab.create": .timeout]))
        #expect(await world.call(run.id, "open_tab", Self.arguments()).value?["state"] == "opening")
        #expect(try world.workspace.file.load().task(id: task.id)?.operated?.extraTabs.first?.key == "review")
        world.show(Self.tabs(run: run, task: task, extra: [Self.extraTab("s9", of: task, key: "review")]))
        world.controller.reconcileTick()
        #expect(tabs(of: task, in: world).first?.sessionId == "s9")
        #expect(await world.call(run.id, "open_tab", Self.arguments()).value?["state"] == "opened")
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        #expect(world.daemon.requests("tab.create").count == 1, "never a second tab")
    }

    @Test func aRequestThatShowedNoTabIsAskedAgainOnlyAfterAMinuteAndNeverOnceItShowed() async throws {
        let daemon = RecordingDaemon(failing: ["tab.create": .timeout])
        let (world, run, task) = try makeWorld(daemon: daemon)
        _ = await world.call(run.id, "open_tab", Self.arguments())
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        #expect(daemon.requests("tab.create").count == 1)
        daemon.failing = [:]
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        let asked = daemon.requests("tab.create")
        #expect(asked.count == 2 && asked.last?.params["tabKey"] as? String == "review" && asked.last?.params["background"] as? Bool == true)
        #expect(try world.workspace.file.load().task(id: task.id)?.operated?.extraTabs.first?.launch.number == 2)
        #expect(tabs(of: task, in: world).first?.sessionId == "s-review-2")
        // Its tab closed: it is not opened again.
        world.show(Self.tabs(run: run, task: task))
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        #expect(daemon.requests("tab.create").count == 2)
    }

    @Test func aTabTheDaemonRefusedIsReportedAndNotAskedForAgain() async throws {
        let daemon = RecordingDaemon(failing: ["tab.create": .notFound])
        let (world, run, task) = try makeWorld(daemon: daemon)
        let refusal = "AiTerm couldn’t open the tab: The iTerm2 window or tab is already gone. Call open_tab with another key to try again."
        #expect(await world.call(run.id, "open_tab", Self.arguments()).message == refusal)
        #expect(tabs(of: task, in: world).first?.failure == "The iTerm2 window or tab is already gone.")
        #expect(await world.call(run.id, "open_tab", Self.arguments()).message == refusal, "the same key, the first call's answer")
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        #expect(daemon.requests("tab.create").count == 1)
    }

    @Test func noTabIsAskedForAgainWhileItsTaskIsTakenOver() async throws {
        let daemon = RecordingDaemon(failing: ["tab.create": .timeout])
        let (world, run, task) = try makeWorld(daemon: daemon)
        _ = await world.call(run.id, "open_tab", Self.arguments())
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true } }
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        #expect(daemon.requests("tab.create").count == 1)
    }
}
