import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// AiTerm, not the operator, starts a queued task (spec §6, §8, §11): its launch intent on disk first,
/// then its worktree, then its worker in a window behind your work.
@MainActor @Suite(.blocking) struct WorkerStarterTests {
    let git = GitRunner.hermetic()

    func makeWorld(_ daemon: RecordingDaemon = RecordingDaemon()) throws -> (OperatorWorld, OperatorRun, Project) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-start-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        return (try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]), daemon: daemon), run, project)
    }

    /// A worker's first prompt: AiTerm's line about its worktree and branch, then `text`.
    func brief(_ branch: String, _ text: String) -> String { WorkerStarter.worktreeLine(branch: branch) + "\n\n" + text }

    func head(_ path: String) throws -> String {
        try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func stoppingBeforeALaunchRunsLeavesItsClaimQueuedAndOpensNothing() async throws {
        let (world, run, project) = try makeWorld()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        let launch = world.controller.lastStart
        world.controller.stop()
        await launch?.value
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.task(task.id)?.operated?.state == .queued)
    }

    @Test func aQueuedTaskStartsWithItsIntentSavedThenItsWorktreeThenItsWorkerBehindYourWork() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, project) = try makeWorld(daemon)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .queued, agent: .codex)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        try await daemon.received("window.createTask")
        // Asked for its window: the attempt is on disk, and so is the worktree it opens in.
        let saved = try #require(try world.workspace.file.load().task(id: task.id))
        #expect(saved.operated?.state == .working && saved.operated?.launch?.number == 1)
        daemon.release()
        await world.controller.lastStart?.value
        let started = try #require(world.task(task.id))
        #expect(started.hasCheckout && FileManager.default.fileExists(atPath: started.worktreePath))
        #expect(started.baseBranch == "main")
        #expect(started.operated?.diffBaseSHA == (try head(project.path)), "the launch records its own starting baseline before worker commits")
        let window = try #require(daemon.requests("window.createTask").first)
        #expect(window.params["background"] as? Bool == true)
        #expect(window.params["taskId"] as? String == task.id.uuidString)
        #expect(window.params["cwd"] as? String == started.worktreePath)
        // AiTerm's own first line, not the Operator's: where the worker is, and where alone it commits.
        let prompt = "[AiTerm] You are already in this task's worktree, on branch feat/pluto-1. Commit only here, on feat/pluto-1. "
            + "Do not create another worktree or branch. Inventories, audits and lists go in your final message, never in a new file in the repository. "
            + "Never type /model, /effort or /config into a live agent session: they save the person's defaults. "
            + "To try a model or effort, use launch flags or a scratch CLAUDE_CONFIG_DIR. "
            + "Keep each background command's handle/PID, log and exit status. Queued tests are not stalled. "
            + "Finish when your command exits; do not poll other test processes.\n\nDo PLUTO-1."
        let expected = try AgentCommand.build(agent: .codex, model: "m", reasoning: nil, prompt: prompt,
                                              worktreePath: started.worktreePath, git: git, operated: true)
        #expect(window.params["agentCommand"] as? String == expected)
        #expect(started.windowId == "reopened")
        #expect(started.operated?.launch?.openedAt != nil, "its window is up: never launched again")
    }

    /// A claude task whose agent is near its weekly limit starts on codex: its agent and model rewritten before
    /// the window, and the switch logged once for the summary.
    @Test func aTaskStartsOnTheOtherAgentNearTheLimit() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-start-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        var state = OperatorServiceFixtures.state(projects: [project], runs: [run])
        state.lastModelByAgent[.codex] = "gpt-6-astra"
        // Codex's default, as create_task finds it: the Settings card on this Mac, else the remembered model.
        let fallback = try #require(run.agents.first { $0.agent == .codex })
        let world = try OperatorWorld(state) { $0.weeklyUsage = { [.claude: 84, .codex: 12] } }
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-7", state: .queued, agent: .claude)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let started = try #require(world.task(task.id))
        #expect(started.agent == .codex && started.model == fallback.model && started.reasoning == fallback.reasoning)
        #expect(started.operated?.modelReason == "Started Task PLUTO-7 on Codex: Claude’s weekly limit is at 84 %.")
        let expected = try AgentCommand.build(agent: .codex, model: fallback.model, reasoning: fallback.reasoning, prompt: brief("feat/pluto-7", "Do PLUTO-7."),
                                              worktreePath: started.worktreePath, git: git, operated: true)
        #expect(world.daemon.requests("window.createTask").first?.params["agentCommand"] as? String == expected)
        let logged = try #require(world.run(run.id)?.decisions)
        #expect(logged.map(\.key) == ["switch-\(task.id.uuidString)"])
        #expect(logged.first?.text == "Started Task PLUTO-7 on Codex")
        #expect(logged.first?.why == "Claude’s weekly limit is at 84 %.")
        #expect(logged.first?.task == task.id)
    }

    @Test func aPinnedTaskStaysOnItsAgent() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-start-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { $0.weeklyUsage = { [.claude: 84] } }
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-8", state: .queued, agent: .claude)
        task.operated?.agentPinned = true
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let started = try #require(world.task(task.id))
        #expect(started.agent == .claude && started.model == "m")
        #expect(world.run(run.id)?.decisions.isEmpty == true)
    }

    @Test func aCodeDependentBranchesFromItsParentsAcceptedCommit() async throws {
        let (world, run, project) = try makeWorld()
        let accepted = try head(project.path)
        try git.run(["commit", "-q", "--allow-empty", "-m", "later"], in: project.path)
        var parent = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .accepted, worktree: project.path)
        parent.operated?.acceptance = TaskAcceptance(resultSHA: accepted, prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date())
        let child = OperatorServiceFixtures.task(in: run, project: project, key: "B", state: .queued, dependsOn: [TaskDependency(task: parent.id, kind: .code)])
        world.workspace.mutate { $0.tasks += [parent, child] }
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let started = try #require(world.task(child.id))
        #expect(started.baseBranch == accepted)
        #expect(try head(started.worktreePath) == accepted)
    }

    /// The scheduler counts an accepted parent satisfied whether or not it kept a commit: the starter must
    /// not turn that into a branch from the default branch, which would drop the parent's work.
    @Test func aCodeDependentWhoseParentKeptNoCommitIsBlockedNotBranchedFromTheDefaultBranch() async throws {
        let (world, run, project) = try makeWorld()
        let parent = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .accepted, worktree: project.path)
        let child = OperatorServiceFixtures.task(in: run, project: project, key: "B", state: .queued, dependsOn: [TaskDependency(task: parent.id, kind: .code)])
        world.workspace.mutate { $0.tasks += [parent, child] }
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let blocked = try #require(world.task(child.id))
        #expect(blocked.operated?.state == .blocked)
        #expect(blocked.operated?.blockedReason == "AiTerm couldn’t start it: its code parent has no accepted commit to build on.")
        #expect(blocked.operated?.launch == nil, "no worker was ever launched for it")
        #expect(!blocked.hasCheckout, "no worktree was made")
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.notifications.posted.map(\.target) == [.board(run.id)])
    }

    @Test func aTaskWhoseWorkerCannotOpenIsBlockedWithTheReasonAndYouAreTold() async throws {
        let (world, run, project) = try makeWorld(RecordingDaemon(failing: ["window.createTask": .internal]))
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let blocked = try #require(world.task(task.id)?.operated)
        #expect(blocked.state == .blocked)
        #expect(blocked.blockedReason == "AiTerm couldn’t start it: AiTerm’s helper ran into a problem.")
        #expect(world.notifications.posted.map(\.target) == [.board(run.id)])
    }

    @Test func aWindowThatMayStillBeOpeningIsLeftForTheReconciler() async throws {
        let (world, run, project) = try makeWorld(RecordingDaemon(failing: ["window.createTask": .timeout]))
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-3", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.task(task.id)?.operated?.launch?.number == 1)
        #expect(world.task(task.id)?.operated?.launch?.openedAt == nil, "it may still be opening")
    }

    /// A task that failed and was retried, as the operator's own calls leave it: queued, with what failed kept.
    func retried(_ world: OperatorWorld, _ run: OperatorRun, _ project: Project, key: String, ownership: Int = 0) throws -> TaskItem {
        var task = OperatorServiceFixtures.task(in: run, project: project, key: key, state: .working, worktree: project.path)
        task.operated?.ownership = ownership
        let id = task.id
        world.workspace.mutate { $0.tasks.append(task) }
        try world.workspace.mutate { state in
            _ = try OperatedTransitions.apply(.fail(reason: "the tests failed"), toTask: id, in: &state, by: .operatorTool)
            _ = try OperatedTransitions.apply(.retry, toTask: id, in: &state, by: .operatorTool)
        }
        return try #require(world.task(id))
    }

    @Test func aRetriedTaskWhoseWorkerIsIdleIsToldWhatFailedInItsOwnTabAndItsWindowIsRecorded() async throws {
        let (world, run, project) = try makeWorld()
        let task = try retried(world, run, project, key: "PLUTO-4", ownership: 2)
        #expect(task.operated?.state == .queued && task.operated?.blockedReason == nil)
        world.show([OperatorServiceFixtures.session("w4", window: "win4", tag: task.id, state: .done)])
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let sent = try #require(world.daemon.requests("session.deliver").first)
        #expect(sent.params["sessionId"] as? String == "w4")
        #expect(sent.params["ownership"] as? Int == 2)
        #expect(sent.params["text"] as? String == brief("feat/pluto-4", "The last attempt failed: the tests failed. Try again from the worktree as it is.\n\nDo PLUTO-4."))
        #expect(world.daemon.requests("window.createTask").isEmpty)
        let after = try #require(world.task(task.id))
        #expect(after.operated?.state == .working)
        #expect(after.windowId == "win4")
        #expect(after.operated?.launch?.openedAt != nil, "its worker was shown: the reconciler never launches it again")
    }

    @Test func aRetriedTaskWithNoWorkerOpensAFreshWindowThatTellsWhatFailed() async throws {
        let (world, run, project) = try makeWorld()
        let task = try retried(world, run, project, key: "PLUTO-5")
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let started = try #require(world.task(task.id))
        let window = try #require(world.daemon.requests("window.createTask").first)
        let prompt = brief("feat/pluto-5", "The last attempt failed: the tests failed. Try again from the worktree as it is.\n\nDo PLUTO-5.")
        let expected = try AgentCommand.build(agent: .claude, model: "m", reasoning: nil, prompt: prompt,
                                              worktreePath: started.worktreePath, git: git, operated: true)
        #expect(window.params["agentCommand"] as? String == expected)
    }

    @Test func aRetriedTaskWhoseWorkerIsStillBusyIsBlockedAndNoSecondAgentStarts() async throws {
        let (world, run, project) = try makeWorld()
        let task = try retried(world, run, project, key: "PLUTO-6")
        world.show([OperatorServiceFixtures.session("w6", tag: task.id, state: .working)])
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let blocked = try #require(world.task(task.id)?.operated)
        #expect(blocked.state == .blocked)
        #expect(blocked.blockedReason == "AiTerm couldn’t start it: its worker is still busy; stop it or wait.")
        #expect(world.daemon.requests("session.deliver").isEmpty && world.daemon.requests("window.createTask").isEmpty)
        #expect(world.notifications.posted.map(\.target) == [.board(run.id)])
    }

    /// The run is paused between the claim and the window: no window opens, and the claim is taken back so the
    /// task queues again and holds no slot.
    @Test func aClaimThatNoLongerHoldsOpensNoWindowAndIsReleased() async throws {
        let (world, run, project) = try makeWorld()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-7", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        #expect(world.task(task.id)?.operated?.state == .working, "claimed and saved at once")
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .paused } }
        await world.controller.lastStart?.value
        #expect(world.daemon.requests("window.createTask").isEmpty)
        let released = try #require(world.task(task.id)?.operated)
        #expect(released.state == .queued && released.launch == nil)
    }

    @Test func aStartThatCannotBeSavedTakesItsClaimBackSoTheSlotIsFree() async throws {
        let (world, run, project) = try makeWorld()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-8", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        try FileManager.default.createDirectory(at: world.workspace.file.backupURL, withIntermediateDirectories: false)
        world.controller.startReadyTasks()
        #expect(world.controller.lastStart == nil)
        let operated = try #require(world.task(task.id)?.operated)
        #expect(operated.state == .queued && operated.launch == nil)
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    /// A block that did not take — the task was taken over while its window was being asked for — is neither
    /// recorded nor announced.
    @Test func aBlockThatDidNotTakeIsNotAnnounced() async throws {
        let daemon = RecordingDaemon(failing: ["window.createTask": .internal], holding: "window.createTask")
        let (world, run, project) = try makeWorld(daemon)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-9", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        try await daemon.received("window.createTask")
        world.workspace.mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i].operated?.takenOver = true }
        }
        daemon.release()
        await world.controller.lastStart?.value
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.notifications.posted.isEmpty)
    }
}

/// Moved from OperatorReviewTests, where it sat apart from its subject.
extension WorkerStarterTests {
    @Test func aShellWindowStaysUncertainUntilAWorkerAppears() throws {
        let (world, _, task) = try OperatorServiceFixtures.oneWorkingTask()
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.launch = LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSince1970: 0))
            $0.retriesUsed = 1
        } }
        world.live.sessions = [OperatorServiceFixtures.session("shell", window: "existing", tag: task.id, agent: .shell)]
        var notices = 0
        world.controller.starter.onUncertain = { _ in notices += 1 }
        world.controller.starter.recordWindow("existing", of: task.id)
        #expect(world.task(task.id)?.operated?.flags.contains(.uncertain) == true)
        world.controller.starter.recordWindow("existing", of: task.id)
        world.controller.starter.tabsListed(world.live.sessions)
        #expect(notices == 1)
        world.live.sessions[0].agent = .claude
        world.controller.starter.tabsListed(world.live.sessions)
        #expect(world.task(task.id)?.operated?.flags.contains(.uncertain) == false)
        #expect(notices == 1)
        #expect(world.daemon.requests("session.deliver").isEmpty)
    }
}

extension WorkerStarterTests {
    @Test(arguments: [(true, false), (false, false), (true, true)])
    func weeklySwitchStaysWithinBroadcastRows(otherAllowed: Bool, pinned: Bool) async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-rows-"))
        var run = OperatorServiceFixtures.run(projects: [project], state: .active)
        run.taskSettings = TaskSettings(review: nil, end: .commit)
        let planned = AgentChoice(agent: .claude, model: "claude-named", reasoning: "high")
        let other = AgentChoice(agent: .codex, model: "gpt-6-mini", reasoning: "low")
        run.agents = otherAllowed ? [planned, other, AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "high")] : [planned]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) {
            $0.weeklyUsage = { [.claude: 84, .codex: 12] }
        }
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "ROW", state: .queued, agent: planned.agent)
        task.model = planned.model; task.reasoning = planned.reasoning
        task.operated?.agentPinned = pinned
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        await world.controller.lastStart?.value
        let started = try #require(world.task(task.id))
        let expected = otherAllowed && !pinned ? other : planned
        #expect(started.agent == expected.agent && started.model == expected.model && started.reasoning == expected.reasoning)
        #expect(world.daemon.requests("window.createTask").count == 1)
    }
}
