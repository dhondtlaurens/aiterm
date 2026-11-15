import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalSelectionTests {
    @Test func aMergeRequestOnAnExistingTasksBranchContinuesThatTask() throws {
        var world = SignalWorld(); let signal = world.signal()
        world.state.signals[0].source = .gitLab(RequestConditions(event: .myRequest))
        let task = TaskItem.make(project: world.project.id, branch: "feat/work", worktreePath: "/synthetic/work")
        world.state.tasks = [task]
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let request = MergeRequest(iid: 7, title: "Work", sourceBranch: task.branch, targetBranch: "main", author: "me", state: "opened", draft: true,
                                   url: "https://git.example/shop/web/-/merge_requests/7", description: "Do the work.")
        let item = SignalItem(item: .request(remote: world.project.remoteUrl!, number: 7), title: request.title, mergeRequest: request)
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        #expect(router.apply(signals: [signal], read: SignalRead(items: [item], complete: true)) == [task.id])
        #expect(h.workspace.state.tasks.count == 1 && h.workspace.state.task(id: task.id)?.mr?.iid == 7)
    }

    @Test func severalLinkedProjectsAndAgentsWaitForTheOperatorsChoice() async throws {
        var world = SignalWorld()
        let codex = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        let signal = world.signal(agents: [SignalWorld.agent, codex])
        var second = world.project; second.id = UUID(); second.path = "/synthetic/second"; second.name = "second"
        world.state.append(project: second)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        let id = try #require(router.apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true)).first)
        var starts = 0
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in
                #expect(task.projectId == second.id && task.agent == .codex)
                var task = task; task.worktreePath = "/synthetic/second/.worktrees/work"; return task
            }, launch: { _, _ in starts += 1; return "worker-window" }, restore: { $0 }))
        await runner.run(id)
        #expect(starts == 0 && h.workspace.state.task(id: id)?.signalTask?.phase == .blocked)
        try await runner.resume(id, project: second.id, agent: codex)
        #expect(starts == 1 && h.workspace.state.task(id: id)?.projectId == second.id)
    }

    @Test func aFailedPreparationCanBeResumedWithItsSavedIntent() async throws {
        var world = SignalWorld(); let signal = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        let id = try #require(router.apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true)).first)
        var tries = 0, starts = 0
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in
                tries += 1
                if tries == 1 { throw ActionUnavailable("Try again") }
                var task = task; task.worktreePath = "/synthetic/work"; return task
            }, launch: { _, _ in starts += 1; return "worker-window" }, restore: { $0 }))
        await runner.run(id)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .blocked)
        try await runner.resume(id)
        #expect(tries == 2 && starts == 1 && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
    }

    @Test func stoppingWhilePreparationRunsPreventsItsLateLaunch() async throws {
        var world = SignalWorld(); let signal = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        let id = try #require(router.apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true)).first)
        let entered = TestLatch(), release = TestLatch()
        var started = false
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in entered.signal(); await release.wait(); return task },
            launch: { _, _ in started = true; return "unexpected" }, restore: { $0 }))
        let launch = Task { await runner.run(id) }
        await entered.wait(); runner.stop(); release.signal(); await launch.value
        #expect(!started)
    }

    @Test func signalWorkerTabsReuseTheSharedProjectionAndConversationOwnership() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        var task = try #require(world.state.task(id: id))
        task.conversations = [TaskConversation(agent: .claude, id: "extra"), TaskConversation(agent: .claude, id: "main")]
        task.signalTask?.extraTabs = [ExtraTab(key: "second", agent: .claude, model: "m", reasoning: nil, modelReason: "Second opinion",
                                             brief: "Look at the edge", launch: LaunchAttempt(number: 1, requestedAt: world.now), conversation: "extra")]
        let sessions = [SessionInfo.make("main", task: id), SessionInfo.make("extra", task: id, state: .working, tabKey: "second")]
        #expect(task.firstWorkerConversation?.id == "main")
        #expect(task.workerTabs(in: sessions).count == 2)
        #expect(task.workerTabs(in: sessions).last?.status == .working)
    }
}
