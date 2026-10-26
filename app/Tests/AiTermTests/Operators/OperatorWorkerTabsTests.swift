import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A task counts every worker tab it has, its first worker and each extra tab the Operator added (`open_tab`): its
/// clock runs while any one is at work, it waits for acceptance once all ended their turn, and a prompt in any one
/// waits on you, naming the tab. The Operator reaches one tab by its key; a takeover, a hand back and a stop reach
/// them all; and an extra tab once closed stays closed.
@MainActor @Suite(.blocking) struct OperatorWorkerTabsTests {
    let clock = TestClock.operators()

    /// An active run with one working task, PLUTO-1, its extra tab `review` recorded as `tab` leaves it: by default
    /// opened as `s-review`.
    func makeWorld(runtimeUsed: TimeInterval = 0, daemon: RecordingDaemon = RecordingDaemon(),
                   tab: (inout ExtraTab) -> Void = { _ in }) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working, worktree: "/tmp/aiterm-wt")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        task.operated?.runtimeUsed = runtimeUsed
        var extra = ExtraTab(key: "review", agent: .codex, model: "gpt-6-mini", reasoning: nil, modelReason: "Codex writes tests well.",
                             brief: "Write the tests.", launch: LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now),
                             sessionId: "s-review")
        tab(&extra)
        task.operated?.extraTabs = [extra]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon) {
            [clock] ports in ports.now = { clock.now }
        }
        return (world, run, task)
    }

    /// The Operator's tab, the first worker in `first`, and the extra tab in `review` unless it is nil.
    func show(_ world: OperatorWorld, _ run: OperatorRun, _ task: TaskItem, first: SessionState, review: SessionState?) {
        var tabs = [OperatorServiceFixtures.session("op", window: "wop", tag: run.id),
                    OperatorServiceFixtures.session("s1", tag: task.id, state: first)]
        if let review { tabs.append(Self.extraTab(of: task, state: review)) }
        world.show(tabs)
    }

    static func extraTab(of task: TaskItem, state: SessionState) -> SessionInfo {
        var session = OperatorServiceFixtures.session("s-review", tag: task.id, agent: .codex, state: state)
        session.tabIndex = 1
        session.tabKey = "review"
        return session
    }

    func runtime(_ task: TaskItem, in world: OperatorWorld) -> TimeInterval? { world.task(task.id)?.operated?.runtimeUsed }

    /// The run as `run_status` would show it now.
    func status(_ world: OperatorWorld, _ run: OperatorRun) throws -> RunStatus {
        let current = try #require(world.run(run.id))
        return try #require(world.controller.status(of: current))
    }

    /// A Claude conversation `id` whose last reply is `text`, in the scratch home's `~/.claude/projects`.
    func say(_ text: String, in id: String, _ world: OperatorWorld) throws {
        let file = world.ports.home.appendingPathComponent(".claude/projects/p/\(id).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
    }

    func message(_ text: String, tab: String? = nil) -> JSONValue {
        var arguments: [String: JSONValue] = ["task": "PLUTO-1", "text": .string(text)]
        if let tab { arguments["tab"] = .string(tab) }
        return .object(arguments)
    }

    func read(_ what: String, tab: String? = nil) -> JSONValue {
        var arguments: [String: JSONValue] = ["task": "PLUTO-1", "what": .string(what)]
        if let tab { arguments["tab"] = .string(tab) }
        return .object(arguments)
    }

    /// The tabs messages were typed into, the waker's lines to the Operator's own tab left out.
    func delivered(_ world: OperatorWorld) -> [String?] {
        world.daemon.requests("session.deliver").map { $0.params["sessionId"] as? String }.filter { $0 != "op" }
    }

    // -- the clock and acceptance -------------------------------------------------------------------

    /// The clock runs while any tab is at work, counting the time once; with every tab idle it stops.
    @Test func theClockRunsOnceWhileAnyTabWorks() throws {
        let (world, run, task) = try makeWorld()
        show(world, run, task, first: .idle, review: .working)
        world.controller.reconcileTick()
        clock.advance(by: 30)
        world.controller.reconcileTick()
        #expect(runtime(task, in: world) == 30, "the extra tab is at work")
        show(world, run, task, first: .working, review: .working)
        clock.advance(by: 30)
        world.controller.reconcileTick()
        #expect(runtime(task, in: world) == 60, "two tabs at work count the time once")
        show(world, run, task, first: .idle, review: .done)
        clock.advance(by: 30)
        world.controller.reconcileTick()
        #expect(runtime(task, in: world) == 60, "every tab ended its turn")
    }

    /// An extra tab asked for that has not shown yet is at work.
    @Test func anExtraTabStillOpeningRunsTheClock() throws {
        let (world, run, task) = try makeWorld { tab in
            tab.sessionId = nil
            tab.launch.openedAt = nil
        }
        show(world, run, task, first: .idle, review: nil)
        world.controller.reconcileTick()
        clock.advance(by: 30)
        world.controller.reconcileTick()
        #expect(runtime(task, in: world) == 30)
        let status = try status(world, run)
        #expect(status.obligations.readyForAcceptance.isEmpty)
    }

    /// Past its runtime, a task with a tab still at work is blocked; with every tab idle its work waits for acceptance.
    @Test func aTaskPastItsRuntimeIsBlockedOnlyWhileATabWorks() async throws {
        let (world, run, task) = try makeWorld(runtimeUsed: 95 * 60)
        show(world, run, task, first: .idle, review: .idle)
        world.controller.reconcileTick()
        clock.advance(by: 30)
        world.controller.reconcileTick()
        let waiting = try #require(world.task(task.id)?.operated)
        #expect(waiting.state == .working && waiting.runtimeUsed == 95 * 60, "finished work waits for acceptance, unblocked")
        // Ready once AiTerm has read what the first worker's turn left (`WorkerTurnReader`).
        await world.controller.turns.lastRead?.value
        let status = try status(world, run)
        #expect(status.obligations.readyForAcceptance == ["PLUTO-1"])
        show(world, run, task, first: .idle, review: .working)
        clock.advance(by: 30)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.state == .blocked)
    }

    /// `run_status` lists the task's tabs, its first worker as `main`, each with its agent, model and live status.
    @Test func runStatusListsEveryWorkerTab() throws {
        let (world, run, task) = try makeWorld()
        show(world, run, task, first: .idle, review: .working)
        let status = try status(world, run)
        let line = try #require(status.tasks.first)
        #expect(line.live == .idle)
        #expect(line.tabs == [RunStatus.TabLine(key: "main", agent: .claude, model: "m", live: .idle),
                              RunStatus.TabLine(key: "review", agent: .codex, model: "gpt-6-mini", live: .working)])
        #expect(status.obligations.readyForAcceptance.isEmpty)
    }

    /// A prompt you typed into a worker yourself (`SessionInfo.yourPrompt`): `run_status` says you are driving it, by
    /// your prompt's first line, until that turn ends, so the Operator leaves the worker alone and reads its result
    /// afterwards. Its background work is listed beside it (Background work A).
    @Test func runStatusSaysWhenYouAreDrivingAWorker() throws {
        let (world, run, task) = try makeWorld()
        var worker = OperatorServiceFixtures.session("s1", tag: task.id, state: .working)
        worker.yourPrompt = "Fix the language switch inline here"
        world.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id), worker])
        let line = try #require(try status(world, run).tasks.first)
        #expect(line.youAreDriving == true && line.yourPrompt == "Fix the language switch inline here")
        worker.state = .done
        worker.yourPrompt = nil
        world.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id), worker])
        let after = try #require(try status(world, run).tasks.first)
        #expect(after.youAreDriving == nil && after.yourPrompt == nil)
    }

    // -- prompts --------------------------------------------------------------------------------------

    /// A prompt open in the extra tab is a question waiting on you, on that tab: `run_status` names it, and it is
    /// resolved once that tab leaves the prompt.
    @Test func aPromptInAnExtraTabWaitsOnYouNamingTheTab() async throws {
        let daemon = RecordingDaemon()
        daemon.prompts["s-review"] = .permission
        let (world, run, task) = try makeWorld(daemon: daemon)
        show(world, run, task, first: .working, review: .needsInput)
        await world.controller.lastProbe?.value
        let question = try #require(world.run(run.id)?.questions.last)
        #expect(question.text == "Codex asks for permission" && question.task == task.id && question.tab == "review")
        #expect(question.resolution == nil && question.id == "prompt-\(task.id.uuidString)-1")
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true)
        let status = try status(world, run)
        #expect(status.obligations.promptsWaitingOnYou == ["PLUTO-1/review"])

        daemon.prompts["s-review"] = nil
        show(world, run, task, first: .working, review: .working)
        await world.controller.lastProbe?.value
        #expect(world.run(run.id)?.questions.last?.resolution == "Answered in its window.")
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
    }

    @Test func aScreenOnlyMenuInAnExtraTabWaitsOnYou() async throws {
        let daemon = RecordingDaemon()
        daemon.prompts["s-review"] = .menu
        let (world, run, task) = try makeWorld(daemon: daemon)
        show(world, run, task, first: .working, review: .working)
        await world.controller.lastProbe?.value
        let snapshot = try #require(OperatorController.status(of: run.id, state: world.state,
                                                              sessions: world.live.sessions, revision: 0, turns: [:], quiet: [task.id]))
        #expect(snapshot.obligations.promptsWaitingOnYou == ["PLUTO-1/review"])
        #expect(snapshot.tasks.first?.tabs?.first { $0.key == "review" }?.live == .needsInput)
        #expect(snapshot.obligations.uncertain.isEmpty)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true)
    }

    /// A prompt in each tab is a question each, numbered apart, and each tab's answer resolves its own.
    @Test func aPromptInEachTabIsAQuestionEach() async throws {
        let daemon = RecordingDaemon()
        daemon.prompts = ["s1": .permission, "s-review": .menu]
        let (world, run, task) = try makeWorld(daemon: daemon)
        show(world, run, task, first: .needsInput, review: .needsInput)
        #expect(await eventually(describing: "both prompts recorded") { world.run(run.id)?.questions.count == 2 })
        let questions = try #require(world.run(run.id)?.questions)
        #expect(Set(questions.map(\.id)) == ["prompt-\(task.id.uuidString)-1", "prompt-\(task.id.uuidString)-2"])
        #expect(Set(questions.map { $0.tab ?? "main" }) == ["main", "review"])
        #expect(questions.first { $0.tab == nil }?.text == "Claude Code asks for permission")
        let status = try status(world, run)
        #expect(status.obligations.promptsWaitingOnYou.sorted() == ["PLUTO-1", "PLUTO-1/review"])

        daemon.prompts["s1"] = nil
        show(world, run, task, first: .working, review: .needsInput)
        #expect(await eventually(describing: "first prompt resolved") {
            world.run(run.id)?.questions.first { $0.tab == nil }?.resolution != nil
        })
        let after = try #require(world.run(run.id)?.questions)
        #expect(after.first { $0.tab == nil }?.resolution == "Answered in its window.")
        #expect(after.first { $0.tab == "review" }?.resolution == nil)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true, "the extra tab still waits on you")
    }

    // -- the first worker -----------------------------------------------------------------------------

    /// An extra tab running its agent is not the first worker: a first worker's window holding only a shell stays
    /// uncertain, and the tool handler's worker tab is the first worker even when the extra tab comes first.
    @Test func anExtraTabIsNeverTakenForTheFirstWorker() throws {
        let (world, run, task) = try makeWorld()
        world.workspace.mutate { $0.updateOperated(task.id) { $0.flags.insert(.uncertain) } }
        var shell = OperatorServiceFixtures.session("s1", tag: task.id, agent: .shell)
        shell.tabIndex = 2
        var extra = Self.extraTab(of: task, state: .working)
        extra.tabIndex = 0
        world.live.sessions = [OperatorServiceFixtures.session("op", window: "wop", tag: run.id), shell, extra]
        world.controller.starter.tabsListed(world.live.sessions)
        #expect(world.task(task.id)?.operated?.flags.contains(.uncertain) == true)
        let current = try #require(world.task(task.id))
        #expect(world.controller.tools.workerTab(of: current) == nil)
        world.live.sessions[1].agent = .claude
        #expect(world.controller.tools.workerTab(of: current)?.sessionId == "s1")
        #expect(world.controller.tools.workerTabs(of: current).map { $0.session?.sessionId } == ["s1", "s-review"])
    }

    // -- one tab, by its key ----------------------------------------------------------------------------

    /// Without a tab, or with `main`, message_task reaches the first worker as it always did; with a tab's key, that tab.
    /// The same words to two tabs are two messages.
    @Test func messageTaskReachesTheTabItsKeyNames() async throws {
        let (world, run, task) = try makeWorld()
        show(world, run, task, first: .idle, review: .idle)
        #expect(await world.call(run.id, "message_task", message("Go on.")).value?["result"] == "delivered")
        #expect(await world.call(run.id, "message_task", message("Go on.", tab: "review")).value?["result"] == "delivered")
        #expect(await world.call(run.id, "message_task", message("And this.", tab: "main")).value?["result"] == "delivered")
        #expect(delivered(world) == ["s1", "s-review", "s1"])
        #expect(await world.call(run.id, "message_task", message("Go on.", tab: "review")).value?["result"] == "delivered")
        #expect(delivered(world).count == 3, "a repeat to the same tab returns the recorded answer")
    }

    /// read_task's lastMessage and prompt read the tab its key names, the first worker without one; a closed tab's last
    /// message is read from the conversation it named.
    @Test func readTaskReadsTheTabItsKeyNames() async throws {
        let daemon = RecordingDaemon()
        daemon.prompts["s-review"] = .permission
        let (world, run, task) = try makeWorld(daemon: daemon) { $0.agent = .claude }
        try say("Main is done.", in: "conv-main", world)
        try say("Tests are green.", in: "conv-review", world)
        var review = Self.extraTab(of: task, state: .needsInput)
        review.agent = .claude
        review.conversationId = "conv-review"
        world.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id),
                    OperatorServiceFixtures.session("s1", tag: task.id, state: .idle, conversation: "conv-main"), review])
        world.controller.reconcileTick()
        #expect(await world.call(run.id, "read_task", read("lastMessage")).value?["lastMessage"] == "Main is done.")
        #expect(await world.call(run.id, "read_task", read("lastMessage", tab: "main")).value?["lastMessage"] == "Main is done.")
        #expect(await world.call(run.id, "read_task", read("lastMessage", tab: "review")).value?["lastMessage"] == "Tests are green.")
        #expect(await world.call(run.id, "read_task", read("prompt")).value?["prompt"] == .null)
        #expect(await world.call(run.id, "read_task", read("prompt", tab: "review")).value?["prompt"] == "permission")
        #expect(world.task(task.id)?.operated?.extraTabs.first?.conversation == "conv-review", "recorded once the tab named it")

        // Both closed: each is read from the conversation it named, the extra tab's never taken for the first worker's.
        world.workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            state.tasks[i].conversations = [TaskConversation(agent: .claude, id: "conv-review"), TaskConversation(agent: .claude, id: "conv-main")]
        }
        world.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id)])
        #expect(await world.call(run.id, "read_task", read("lastMessage")).value?["lastMessage"] == "Main is done.")
        #expect(await world.call(run.id, "read_task", read("lastMessage", tab: "review")).value?["lastMessage"] == "Tests are green.")
        #expect(await world.call(run.id, "read_task", read("prompt", tab: "review")).value
                == ["prompt": .null, "note": "PLUTO-1’s tab review was closed. AiTerm doesn’t open it again."])
    }

    /// A key the task has no tab for is refused, naming the tabs it has.
    @Test func anUnknownTabIsRefusedWithTheTasksTabs() async throws {
        let (world, run, task) = try makeWorld()
        show(world, run, task, first: .idle, review: .idle)
        let refusal = "PLUTO-1 has no tab docs. Its tabs are main, review."
        #expect(await world.call(run.id, "message_task", message("Go on.", tab: "docs")).message == refusal)
        #expect(await world.call(run.id, "read_task", read("lastMessage", tab: "docs")).message == refusal)
        #expect(await world.call(run.id, "read_task", read("prompt", tab: "docs")).message == refusal)
        #expect(delivered(world).isEmpty)
    }

    /// A tab closed, or still opening, has no worker to message: said, and nothing is typed.
    @Test func aClosedOrOpeningTabIsNotMessaged() async throws {
        let (world, run, task) = try makeWorld()
        show(world, run, task, first: .idle, review: nil)
        #expect(await world.call(run.id, "message_task", message("Go on.", tab: "review")).message
                == "PLUTO-1’s tab review was closed. AiTerm doesn’t open it again.")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.extraTabs[0].sessionId = nil; $0.extraTabs[0].launch.openedAt = nil } }
        #expect(await world.call(run.id, "message_task", message("Go on.", tab: "review")).message
                == "PLUTO-1’s tab review is still opening; try again in a moment.")
        #expect(delivered(world).isEmpty)
    }

    // -- every tab: take over, hand back, stop --------------------------------------------------------

    /// A takeover moves the ownership on in every tab, so the Operator's message to an extra tab is refused; a hand back
    /// sets it on every tab again, and the next message carries it.
    @Test func aTakeoverHoldsEveryTabAndAHandBackReleasesThem() async throws {
        let (world, run, task) = try makeWorld()
        show(world, run, task, first: .idle, review: .idle)
        try await world.controller.takeOver(task: task.id)
        let set = world.daemon.requests("session.setOwnership")
        #expect(set.map { $0.params["sessionId"] as? String } == ["s1", "s-review"] && set.allSatisfy { $0.params["ownership"] as? Int == 1 })
        #expect(await world.call(run.id, "message_task", message("Go on.", tab: "review")).message
                == "The person took over PLUTO-1. Leave it until they hand it back.")
        #expect(delivered(world).isEmpty)

        try await world.controller.handBack(task: task.id)
        #expect(world.daemon.requests("session.setOwnership").dropFirst(2).map { $0.params["sessionId"] as? String } == ["s1", "s-review"])
        #expect(await world.call(run.id, "message_task", message("Go on.", tab: "review")).value?["result"] == "delivered")
        let sent = try #require(world.daemon.requests("session.deliver").last { $0.params["sessionId"] as? String == "s-review" })
        #expect(sent.params["ownership"] as? Int == 1)
    }

    /// Stop Task reaches every tab: the Operator steers none, a prompt in any one is resolved, and a tab not opened yet
    /// is not asked for. Their agents finish their turn, as the first worker's does.
    @Test func stoppingTheTaskReachesEveryTab() async throws {
        let daemon = RecordingDaemon(failing: ["tab.create": .timeout])
        daemon.prompts["s-review"] = .permission
        let (world, run, task) = try makeWorld(daemon: daemon)
        world.workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            state.tasks[i].windowId = "w1"
            state.tasks[i].operated?.extraTabs.append(ExtraTab(key: "docs", agent: .codex, model: "gpt-6-mini", reasoning: nil,
                                                              modelReason: "Docs.", brief: "Write the docs.",
                                                              launch: LaunchAttempt(number: 1, requestedAt: clock.now)))
        }
        show(world, run, task, first: .working, review: .needsInput)
        await world.controller.lastProbe?.value
        #expect(world.run(run.id)?.questions.last?.tab == "review")
        #expect(TabOpener.holds(try #require(world.task(task.id)), in: world.state))

        try world.controller.stop(task: task.id)
        #expect(world.run(run.id)?.questions.allSatisfy { $0.resolution == "Stopped by you." } == true)
        for tab in [nil, "review"] {
            #expect(await world.call(run.id, "message_task", message("Go on.", tab: tab)).message
                    == "PLUTO-1 is stopped: there is no worker to steer.")
        }
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        #expect(daemon.requests("tab.create").isEmpty && delivered(world).isEmpty)
    }

    // -- a closed tab stays closed --------------------------------------------------------------------

    /// An extra tab closed after it opened is listed closed in run_status, and is opened again by nothing: not by the
    /// reconciler, not by reopening the task's window, not by AiTerm's restart. The first worker comes back on your
    /// click, as before.
    @Test func aClosedExtraTabIsReportedAndNeverOpenedAgain() async throws {
        let (world, run, task) = try makeWorld { $0.agent = .claude; $0.conversation = "conv-review" }
        world.workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            state.tasks[i].windowId = "w1"
        }
        show(world, run, task, first: .working, review: nil)
        let line = try #require(try status(world, run).tasks.first)
        #expect(line.tabs == [RunStatus.TabLine(key: "main", agent: .claude, model: "m", live: .working),
                              RunStatus.TabLine(key: "review", agent: .claude, model: "gpt-6-mini", closed: true)])
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastTab?.value
        #expect(world.daemon.requests("tab.create").isEmpty, "not by the reconciler")

        // The whole window closed, the extra tab's conversation remembered before the first worker's.
        world.workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            state.tasks[i].conversations = [TaskConversation(agent: .claude, id: "conv-review"), TaskConversation(agent: .claude, id: "conv-main")]
        }
        world.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id)])
        await world.controller.reopenWorker(task: task.id)
        let reopened = try #require(world.daemon.requests("window.createTask").first)
        #expect(reopened.params["agentCommand"] as? String
                == AgentCommand.resumeWorker(agent: .claude, conversation: "conv-main", model: "m", reasoning: nil))
        #expect(world.daemon.requests("window.createTask").count == 1 && world.daemon.requests("tab.create").isEmpty, "not by a reopen")

        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load()) { [clock] ports in ports.now = { clock.now } }
        restarted.show([OperatorServiceFixtures.session("op", window: "wop", tag: run.id),
                        OperatorServiceFixtures.session("s1", window: "reopened", tag: task.id, state: .working)])
        restarted.controller.reconcileTick()
        clock.advance(by: 61)
        restarted.controller.reconcileTick()
        await restarted.controller.reconciler.lastTab?.value
        #expect(restarted.daemon.requests("tab.create").isEmpty && restarted.daemon.requests("window.createTask").isEmpty,
                "not after a restart")
        let after = try #require(try status(restarted, run).tasks.first?.tabs)
        #expect(after.last == RunStatus.TabLine(key: "review", agent: .claude, model: "gpt-6-mini", closed: true))
    }
}
