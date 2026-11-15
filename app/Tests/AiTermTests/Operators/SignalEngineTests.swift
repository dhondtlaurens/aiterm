import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalEngineTests {
    @Test(arguments: [false, true]) func theOldestQueuedStageChoosesItsOwnAgentWhenANewMatchArrives(incomingHasSeveralAgents: Bool) throws {
        let codex = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        var world = SignalWorld(); let original = world.signal(), id = world.workingTask(signal: original)
        let first = world.signal(agents: [SignalWorld.agent])
        let latest = world.signal(agents: incomingHasSeveralAgents ? [codex, SignalWorld.agent] : [codex])
        world.state.updateSignalTask(id) { $0.phase = .watching(.approved) }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var busy = true
        let router = ItemRouter(workspace: h.workspace, now: { world.now }, workerIsWorking: { _ in busy })
        let read = SignalRead(items: [world.ticket()], complete: true)
        _ = router.apply(signals: [first], read: read)
        busy = false
        let launches = router.apply(signals: [latest], read: read)
        let task = try #require(h.workspace.state.task(id: id))
        #expect(task.signalTask?.signal == first && task.signalTask?.phase == .launching)
        #expect(task.agent == SignalWorld.agent.agent && task.model == SignalWorld.agent.model && task.reasoning == SignalWorld.agent.reasoning)
        #expect(task.signalTask?.pendingStages.map(\.signal) == [latest])
        #expect(launches == [id])
    }
    @Test func differentQueriesInOnePassGiveTheSharedItemToTheOldestSignal() throws {
        var world = SignalWorld()
        let oldest = world.signal(age: -10), newer = world.signal(age: 10)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        let read = SignalRead(items: [world.ticket()], complete: true)
        let ids = router.apply(observations: [.init(signals: [newer], read: read), .init(signals: [oldest], read: read)])
        let task = try #require(h.workspace.state.tasks.first)
        #expect(ids == [task.id] && h.workspace.state.tasks.count == 1)
        #expect(task.signalTask?.signal == oldest)
        #expect(task.signalTask?.pendingStages.map(\.signal) == [newer])
    }

    @Test func switchingOffAnOwnerDefersItsSavedLaunchUntilItIsOnAgain() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .launching }
        world.state.signals[0].enabled = false
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var launches = 0
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now },
            ports: .init(workerIsWorking: { _ in false }, prepare: { task, _ in task },
                         launch: { _, _ in launches += 1; return "window" }, restore: { $0 }))
        await runner.run(id)
        #expect(launches == 0)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .launching)
        h.workspace.mutate { $0.signals[0].enabled = true }
        await runner.run(id)
        #expect(launches == 1)
    }

    @Test func aCompleteMatchSavesItsStageBeforePreparingAndLaunchingAWorker() async throws {
        var world = SignalWorld()
        let signal = world.signal()
        let harness = try SignalHarness(world)
        defer { harness.cleanUp() }
        let router = ItemRouter(workspace: harness.workspace, now: { world.now })
        let ids = router.apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true))
        let id = try #require(ids.first)
        var prepared = false, launched = false
        let runner = StageRunner(workspace: harness.workspace, journal: harness.journal, now: { world.now },
            ports: .init(workerIsWorking: { _ in false }, prepare: { task, _ in
                let saved = try harness.file.load().task(id: id)
                #expect(saved?.signalTask?.phase == .launching && saved?.signalTask?.launch != nil)
                prepared = true
                var task = task; task.worktreePath = "/synthetic/shop/.worktrees/pay-1"; return task
            }, launch: { task, prompt in
                #expect(prepared)
                #expect(prompt.contains("/psg:plan") && prompt.contains("Use an idempotency key."))
                #expect(prompt.contains("untrusted"))
                let saved = try harness.file.load().task(id: id)
                #expect(saved?.worktreePath == task.worktreePath)
                launched = true; return "worker-window"
            }, restore: { $0 }))
        await runner.run(id)
        #expect(launched && harness.workspace.state.task(id: id)?.signalTask?.phase == .working)
        #expect(harness.workspace.state.task(id: id)?.windowId == "worker-window")
        #expect(try TaskJournal.read(task: id, folder: harness.folder.appendingPathComponent("journals")).count >= 1)
    }

    @Test func aSecondSignalWaitsForTheWorkersTurnAndStartsBeforeTheFirstStagesRemove() async throws {
        var world = SignalWorld()
        let first = world.signal(then: .remove), second = world.signal(name: "Review it", age: 1)
        world.state.signals[1].work.prompt = "/psg:review"
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var working = false, prompts: [String] = []
        let router = ItemRouter(workspace: h.workspace, now: { world.now }, workerIsWorking: { _ in working })
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in working }, prepare: { task, _ in var task = task; task.worktreePath = "/synthetic/work"; return task },
            launch: { _, prompt in prompts.append(prompt); return "same-window" }, restore: { $0 }))
        let id = try #require(router.apply(signals: [first], read: SignalRead(items: [world.ticket()], complete: true)).first)
        await runner.run(id)
        working = true
        #expect(router.apply(signals: [second], read: SignalRead(items: [world.ticket()], complete: true)).isEmpty)
        await runner.run(id)
        #expect(prompts.count == 1)
        #expect(h.workspace.state.task(id: id)?.signalTask?.pendingStages.count == 1)
        working = false
        try await runner.finish(id, action: .finish(.operatorJudges))
        #expect(prompts.count == 2 && prompts.last?.contains("/psg:review") == true)
        #expect(h.workspace.state.tasks.count == 1)
        #expect(h.workspace.state.task(id: id)?.signalTask?.signal == second)
        #expect(h.workspace.state.task(id: id)?.signalTask?.canRunThen == false)
    }

    @Test(arguments: [false, true]) func aPendingStageUsesItsOwnAgentRows(multiple: Bool) async throws {
        var world = SignalWorld(); let first = world.signal()
        let codex = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        let second = world.signal(name: "Review", agents: multiple ? [SignalWorld.agent, codex] : [codex])
        let id = world.workingTask(signal: first), next = world.state.signal(id: second)!
        let stage = SignalStage(signal: second, item: world.ticket().item, matchedAt: world.now, configuration: next, prompt: "Review.")
        world.state.updateSignalTask(id) { $0.pendingStages = [stage] }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var agents: [AgentKind] = []
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in task },
            launch: { task, _ in agents.append(task.agent); return "worker" }, restore: { $0 }))
        try await runner.finish(id, action: .finish(.operatorJudges))
        if multiple {
            #expect(agents.isEmpty)
            #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .blocked)
            try await runner.resume(id, agent: codex)
        }
        #expect(agents == [.codex])
        #expect(h.workspace.state.task(id: id)?.agent == .codex)
    }

    @Test func partialReadsAndUnmappedTicketsNeverCreateAWorkerIntent() throws {
        var world = SignalWorld(); let signal = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        #expect(router.apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: false)).isEmpty)
        #expect(h.workspace.state.tasks.isEmpty && h.workspace.state.signalSeen.isEmpty)
        #expect(router.apply(signals: [signal], read: SignalRead(items: [world.ticket("OTHER-1")], complete: true)).isEmpty)
        #expect(h.workspace.state.tasks.isEmpty)
        #expect(h.workspace.state.signalSeen.first?.disposition == .skipped)
        #expect(h.workspace.state.signalSeen.first?.reason?.contains("No project") == true)
    }

    @Test func aTakeoverWhileCheckoutIsPreparedPreventsTheLaunch() async throws {
        var world = SignalWorld(); let signal = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        let id = try #require(router.apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true)).first)
        var launched = false
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in
                h.workspace.mutate { $0.updateSignalTask(id) { $0 = try! SignalTransitions.apply(.takeOver, to: $0, at: world.now) } }
                var task = task; task.worktreePath = "/synthetic/work"; return task
            }, launch: { _, _ in launched = true; return "unexpected" }, restore: { $0 }))
        await runner.run(id)
        #expect(!launched && h.workspace.state.task(id: id)?.signalTask?.takenOver == true)
    }

    @Test func anArchivedItemIsRestoredAndContinuedInItsOriginalTask() async throws {
        var world = SignalWorld(); let first = world.signal(), second = world.signal(age: 1)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        let id = try #require(router.apply(signals: [first], read: SignalRead(items: [world.ticket()], complete: true)).first)
        h.workspace.mutate { state in
            state.updateSignalTask(id) { $0.phase = .archived }
            state.moveToArchive(taskId: id, branch: "feat/pay-1", at: world.now)
        }
        var restored = false
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in var task = task; task.worktreePath = "/synthetic/work"; return task },
            launch: { _, _ in "same-window" }, restore: { task in restored = true; var task = task; task.worktreePath = "/synthetic/work"; return task }))
        #expect(router.apply(signals: [second], read: SignalRead(items: [world.ticket()], complete: true)) == [id])
        await runner.run(id)
        #expect(restored && h.workspace.state.archive.isEmpty && h.workspace.state.tasks.map(\.id) == [id])
        #expect(h.workspace.state.task(id: id)?.signalTask?.stage == 2)
    }

}
