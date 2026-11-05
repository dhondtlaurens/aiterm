import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Area E of the Operator snags (`docs/plans/2026-11-05-task-launch-reaches-a-worker.md`): a task's launch reaches a
/// worker, or says plainly why it didn't. It never leaves a task working, opening or uncertain with no worker.
@MainActor @Suite(.blocking) struct WorkerLaunchTests {
    let git = GitRunner.hermetic()
    let clock = TestClock.operators()

    /// The retry with the worktree at 41fa602, as the snag log has it: a task whose worker committed in its worktree and
    /// then failed, its window still open with the shell the worker left (tagged with the task, no agent in it), and the
    /// Operator's tab. `failed` leaves it failed, for the test's own retry_task; otherwise it is retried, so queued.
    func retryAt41fa602(_ daemon: RecordingDaemon = RecordingDaemon(), failed: Bool = false,
                        adjust: @escaping (inout OperatorPorts) -> Void = { _ in })
        throws -> (world: OperatorWorld, run: OperatorRun, task: TaskItem, head: String) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-launch-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "T5", state: .working)
        task = try TaskCreator.checkOutWorker(task, project: project, start: "main", git: git).task
        try "work\n".write(toFile: task.worktreePath + "/work.swift", atomically: true, encoding: .utf8)
        try git.run(["add", "work.swift"], in: task.worktreePath)
        try git.run(["commit", "-q", "-m", "Work"], in: task.worktreePath)
        let head = try git.run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        task.windowId = "w-failed"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        let id = task.id, clock = self.clock
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon) { ports in
            ports.clock.now = { clock.now }
            adjust(&ports)
        }
        try world.workspace.mutate { state in
            _ = try OperatedTransitions.apply(.fail(reason: "the tests failed"), toTask: id, in: &state, by: .operatorTool)
            if !failed { _ = try OperatedTransitions.apply(.retry, toTask: id, in: &state, by: .operatorTool) }
        }
        world.show([OperatorServiceFixtures.session("op", window: "w-op", tag: run.id), shell(of: id)])
        return (world, run, try #require(world.task(id)), head)
    }

    /// The shell the failed worker left in its window: tagged with the task, running no agent.
    func shell(of task: UUID) -> SessionInfo {
        OperatorServiceFixtures.session("s-shell", window: "w-failed", tag: task, agent: .shell)
    }

    func expectedCommand(_ task: TaskItem) throws -> String {
        let prompt = WorkerStarter.worktreeLine(branch: task.branch)
            + "\n\nThe last attempt failed: the tests failed. Try again from the worktree as it is.\n\nDo \(task.operated?.key ?? "")."
        return try AgentCommand.build(agent: .claude, model: "m", reasoning: nil, prompt: prompt, worktreePath: task.worktreePath,
                                      git: git, operated: true)
    }

    // -- the retry reaches a worker --------------------------------------------------------------

    /// The snag: the start asked for a window, the daemon handed back the one tagged with the task without typing the
    /// agent command, and nothing ever started. Now the worker starts as a new tab in that window, behind your work.
    @Test func theRetryWithTheWorktreeAt41fa602StartsItsAgentInANewTabOfItsShellWindow() async throws {
        let (world, _, task, head) = try retryAt41fa602()
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        #expect(world.daemon.requests("window.createTask").isEmpty, "no window the daemon would hand back unused")
        let tab = try #require(world.daemon.requests("tab.create").first)
        // The worktree as the start adopted it, its symlinks resolved.
        let started = try #require(world.task(task.id))
        #expect(tab.params["windowId"] as? String == "w-failed")
        #expect(tab.params["cwd"] as? String == started.worktreePath)
        #expect(tab.params["background"] as? Bool == true && tab.params["tabKey"] == nil)
        #expect(tab.params["agentCommand"] as? String == (try expectedCommand(started)))
        #expect(started.operated?.state == .working && started.windowId == "w-failed")
        #expect(started.operated?.launch?.number == 2 && started.operated?.launch?.openedAt != nil)
        #expect(started.operated?.launch?.workerPending == true, "its agent is not listed yet")
        #expect(try git.run(["rev-parse", "HEAD"], in: started.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines) == head,
                "the worktree as it is")
    }

    @Test func retryTaskAnswersThatItOpenedTheWorker() async throws {
        let (world, run, task, _) = try retryAt41fa602(failed: true)
        let answer = try #require(await world.call(run.id, "retry_task", ["task": "T5"]).value)
        #expect(answer["state"] == "working")
        #expect(answer["launch"]?["result"] == "opened")
        #expect(answer["launch"]?["note"]?.stringValue
                == "AiTerm opened its worker in a new tab of its window, behind your work, and typed its agent command there. "
                + "If no agent starts there within 3 minutes, AiTerm blocks the task and says why.")
        #expect(world.daemon.requests("tab.create").count == 1)
        #expect(world.task(task.id)?.operated?.retriesUsed == 1)
    }

    @Test func aRetryWhoseAgentCommandCouldNotBeTypedAnswersThatItFailedAndWhy() async throws {
        let daemon = RecordingDaemon()
        daemon.commandErrors["tab.create"] = "iTerm2 did not answer within 10s"
        let (world, run, task, _) = try retryAt41fa602(daemon, failed: true)
        let answer = try #require(await world.call(run.id, "retry_task", ["task": "T5"]).value)
        let reason = "AiTerm couldn’t start it: its window opened, but AiTerm couldn’t type its agent command there: "
            + "iTerm2 did not answer within 10s. resume_task starts it again."
        #expect(answer["state"] == "blocked")
        #expect(answer["launch"]?["result"] == "failed" && answer["launch"]?["note"]?.stringValue == reason)
        let blocked = try #require(world.task(task.id)?.operated)
        #expect(blocked.state == .blocked && blocked.blockedReason == reason && blocked.blockedFrom == .queued)
        #expect(world.notifications.posted.map(\.target) == [.board(run.id)])
    }

    @Test func aRetryWithNoHelperAnswersThatItIsQueuedAndWhy() async throws {
        let (world, run, _, _) = try retryAt41fa602(failed: true)
        world.link.attached = false
        let answer = try #require(await world.call(run.id, "retry_task", ["task": "T5"]).value)
        #expect(answer["state"] == "queued")
        #expect(answer["launch"]?["result"] == "queued")
        #expect(answer["launch"]?["note"]?.stringValue == "AiTerm isn’t connected to iTerm2 now; it starts the worker once it reconnects.")
    }

    @Test func aRetryWhoseTabIsStillOpeningWhenTheAnswerMustGoSaysSo() async throws {
        let daemon = RecordingDaemon(holding: "tab.create")
        let (world, run, _, _) = try retryAt41fa602(daemon, failed: true) { $0.finishReplyBudget = .milliseconds(100) }
        let answer = try #require(await world.call(run.id, "retry_task", ["task": "T5"]).value)
        #expect(answer["launch"]?["result"] == "opening")
        #expect(answer["launch"]?["note"]?.stringValue
                == "AiTerm is still opening its worker. If no worker starts, AiTerm blocks the task and says why; run_status shows where it is.")
        daemon.release()
        await world.controller.lastStart?.value
    }

    // -- the 3-minute rule --------------------------------------------------------------------

    static let noAgentReason = "AiTerm couldn’t start it: its window opened, but no agent started in it within 3 minutes. resume_task starts it again."

    @Test func aLaunchWhoseAgentNeverStartsIsBlockedAfterThreeMinutesAndResumeStartsItAgain() async throws {
        let (world, run, task, _) = try retryAt41fa602()
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        clock.advance(by: OperatorTiming.firstWorkerOpening - 1)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.state == .working, "still opening")
        clock.advance(by: 1)
        world.controller.reconcileTick()
        let blocked = try #require(world.task(task.id)?.operated)
        #expect(blocked.state == .blocked && blocked.blockedReason == Self.noAgentReason && blocked.blockedFrom == .queued)
        #expect(world.notifications.posted.map(\.target) == [.board(run.id)])
        #expect(await world.call(run.id, "resume_task", ["task": "T5"]).value?["state"] == "queued")
        await world.controller.lastStart?.value
        #expect(world.daemon.requests("tab.create").count == 2, "its worker is started again")
        #expect(world.task(task.id)?.operated?.state == .working)
    }

    @Test func aLaunchWhoseAgentWasListedIsNeverBlockedByTheRule() async throws {
        let (world, run, task, _) = try retryAt41fa602()
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let op = OperatorServiceFixtures.session("op", window: "w-op", tag: run.id)
        world.show([op, shell(of: task.id), OperatorServiceFixtures.session("s-new", window: "w-failed", tag: task.id)])
        #expect(world.task(task.id)?.operated?.launch?.workerPending == nil)
        world.show([op, shell(of: task.id)])
        clock.advance(by: OperatorTiming.firstWorkerOpening + 60)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.state == .working)
    }

    /// State from before this change has no `workerPending`: never judged by the rule.
    @Test func aRecordFromBeforeTheRuleIsNeverBlockedByIt() async throws {
        let (world, _, task, _) = try retryAt41fa602()
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working; $0.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now) } }
        clock.advance(by: OperatorTiming.firstWorkerOpening + 60)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.state == .working)
    }

    /// A reply lost to a timeout, then the reconciler adopting the window it opened, holding only a shell: still judged.
    @Test func aLostReplyWhoseWindowHoldsOnlyAShellIsBlockedAfterThreeMinutes() async throws {
        let daemon = RecordingDaemon(failing: ["window.createTask": .timeout])
        let (world, run, task) = try queued(daemon)
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        #expect(world.task(task.id)?.operated?.launch?.workerPending == true && world.task(task.id)?.operated?.launch?.openedAt == nil)
        world.show([OperatorServiceFixtures.session("op", window: "w-op", tag: run.id), shell(of: task.id)])
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.launch?.openedAt == clock.now, "adopted")
        clock.advance(by: OperatorTiming.firstWorkerOpening)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.blockedReason == Self.noAgentReason)
    }

    // -- a launch that never gets a window ------------------------------------------------------

    func queued(_ daemon: RecordingDaemon) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-launch-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "T3", state: .queued)
        let clock = self.clock
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon) {
            $0.clock.now = { clock.now }
        }
        world.show([OperatorServiceFixtures.session("op", window: "w-op", tag: run.id)])
        return (world, run, task)
    }

    @Test func aWindowIniTerm2NeverConfirmsIsTriedThreeTimesThenBlocked() async throws {
        let (world, run, task) = try queued(RecordingDaemon(failing: ["window.createTask": .timeout]))
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        for _ in 0..<2 {
            clock.advance(by: OperatorTiming.launchAdoptAfter + 1)
            world.controller.reconcileTick()
            await world.controller.reconciler.lastLaunch?.value
        }
        #expect(world.daemon.requests("window.createTask").count == 3)
        #expect(world.task(task.id)?.operated?.state == .working)
        clock.advance(by: OperatorTiming.launchAdoptAfter + 1)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.daemon.requests("window.createTask").count == 3, "no fourth")
        let blocked = try #require(world.task(task.id)?.operated)
        #expect(blocked.state == .blocked && blocked.blockedFrom == .queued)
        #expect(blocked.blockedReason?.hasPrefix("AiTerm couldn’t start it: iTerm2 didn’t confirm its window in 3 tries (") == true)
        #expect(world.notifications.posted.map(\.target) == [.board(run.id)])
    }

    @Test func aLaunchCutOffByALastingDisconnectIsBlockedAfterThreeMinutes() async throws {
        let (world, _, task) = try queued(RecordingDaemon(failing: ["window.createTask": .disconnected]))
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        world.controller.handle(.itermDisconnected)
        clock.advance(by: OperatorTiming.firstWorkerOpening - 1)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.state == .working)
        clock.advance(by: 1)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.blockedReason?
            .hasPrefix("AiTerm couldn’t start it: it lost iTerm2 while opening its window, and iTerm2 hasn’t answered since (") == true)
    }

    /// A retried task has the conversation of the worker that failed, so the reconciler never launches it again: a retry whose
    /// window request goes unanswered is given up on after 3 minutes, tabs listed or not.
    @Test func aRetryWhoseWindowIsNeverConfirmedIsBlockedAfterThreeMinutes() async throws {
        let (world, run, task, _) = try retryAt41fa602(RecordingDaemon(failing: ["window.createTask": .timeout]), failed: true)
        world.workspace.mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i].conversations = [TaskConversation(agent: .claude, id: "c-failed")] }
        }
        let op = OperatorServiceFixtures.session("op", window: "w-op", tag: run.id)
        world.show([op])  // its old window was closed
        let answer = try #require(await world.call(run.id, "retry_task", ["task": "T5"]).value)
        #expect(answer["launch"]?["result"] == "opening")
        // Asked again meanwhile: still unconfirmed, never `opened`.
        let again = try #require(await world.call(run.id, "retry_task", ["task": "T5"]).value)
        #expect(again["state"] == "working" && again["launch"]?["result"] == "opening")
        #expect(again["launch"]?["note"]?.stringValue
                == "iTerm2 hasn’t confirmed its worker’s window yet. If none shows, AiTerm blocks the task and says why.")
        clock.advance(by: OperatorTiming.firstWorkerOpening - 1)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.state == .working)
        clock.advance(by: 1)
        world.controller.reconcileTick()
        #expect(world.daemon.requests("window.createTask").count == 1, "never launched again: it named a conversation")
        let blocked = try #require(world.task(task.id)?.operated)
        #expect(blocked.state == .blocked && blocked.blockedFrom == .queued)
        #expect(blocked.blockedReason?.hasPrefix("AiTerm couldn’t start it: iTerm2 didn’t confirm its window, and none showed within 3 minutes (") == true)
    }

    /// A launch left from before AiTerm started is the reconciler's, as before: the disconnect rule knows only its own.
    @Test func aLaunchFromAnEarlierRunOfAiTermIsNotBlockedWhileDisconnected() async throws {
        let (world, _, task) = try queued(RecordingDaemon())
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working; $0.launch = LaunchAttempt(number: 1, requestedAt: clock.now) } }
        world.controller.handle(.itermDisconnected)
        clock.advance(by: OperatorTiming.firstWorkerOpening + 60)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.state == .working)
    }
}
