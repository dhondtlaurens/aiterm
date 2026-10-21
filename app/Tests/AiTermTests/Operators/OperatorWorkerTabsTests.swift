import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A task counts every worker tab it has, its first worker and each extra tab the Operator added (`open_tab`): its
/// clock runs while any one is at work, it waits for acceptance once all ended their turn, and a prompt in any one
/// waits on you, naming the tab.
@MainActor @Suite(.blocking) struct OperatorWorkerTabsTests {
    let clock = StepClock()

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
    @Test func aTaskPastItsRuntimeIsBlockedOnlyWhileATabWorks() throws {
        let (world, run, task) = try makeWorld(runtimeUsed: 95 * 60)
        show(world, run, task, first: .idle, review: .idle)
        world.controller.reconcileTick()
        clock.advance(by: 30)
        world.controller.reconcileTick()
        let waiting = try #require(world.task(task.id)?.operated)
        #expect(waiting.state == .working && waiting.runtimeUsed == 95 * 60, "finished work waits for acceptance, unblocked")
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

        show(world, run, task, first: .working, review: .working)
        #expect(world.run(run.id)?.questions.last?.resolution == "Answered in its window.")
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
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

        show(world, run, task, first: .working, review: .needsInput)
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
}
