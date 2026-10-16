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
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: .handsOff), projects: [project], state: .active)
        return (try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]), daemon: daemon), run, project)
    }

    func head(_ path: String) throws -> String {
        try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let window = try #require(daemon.requests("window.createTask").first)
        #expect(window.params["background"] as? Bool == true)
        #expect(window.params["taskId"] as? String == task.id.uuidString)
        #expect(window.params["cwd"] as? String == started.worktreePath)
        let expected = try AgentCommand.build(agent: .codex, model: "m", reasoning: nil, prompt: "Do PLUTO-1.",
                                              worktreePath: started.worktreePath, git: git, operated: .handsOff)
        #expect(window.params["agentCommand"] as? String == expected)
        #expect(started.windowId == "reopened")
        #expect(started.operated?.launch?.openedAt != nil, "its window is up: never launched again")
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
        #expect(world.notifications.posted.map(\.target) == [.overview(run.id)])
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
        #expect(world.notifications.posted.map(\.target) == [.overview(run.id)])
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
        #expect(sent.params["text"] as? String == "The last attempt failed: the tests failed. Try again from the worktree as it is.\n\nDo PLUTO-4.")
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
        let prompt = "The last attempt failed: the tests failed. Try again from the worktree as it is.\n\nDo PLUTO-5."
        let expected = try AgentCommand.build(agent: .claude, model: "m", reasoning: nil, prompt: prompt,
                                              worktreePath: started.worktreePath, git: git, operated: .handsOff)
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
        #expect(world.notifications.posted.map(\.target) == [.overview(run.id)])
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
