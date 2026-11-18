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
        world.state.updateSignalTask(id) { $0.phase = .watching }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var busy = true
        let router = ItemRouter(workspace: h.workspace, now: { world.now }, workerIsWorking: { _ in busy })
        let read = SignalRead(items: [world.ticket()], complete: true)
        _ = router.apply(signals: [first], read: read)
        busy = false
        let launches = router.apply(signals: [latest], read: read)
        let task = try #require(h.workspace.state.task(id: id))
        #expect(task.signalTask?.current.signal == first && task.signalTask?.phase == .launching)
        #expect(task.agent == SignalWorld.agent.agent && task.model == SignalWorld.agent.model && task.reasoning == SignalWorld.agent.reasoning)
        #expect(task.signalTask?.pendingStages.map(\.signal) == [latest])
        #expect(launches == [id])
    }
    /// The higher heading takes an item both signals match in one pass, even when it is the newer signal.
    @Test(arguments: [false, true]) func differentQueriesInOnePassGiveTheSharedItemToTheHigherSignal(newerMovedUp: Bool) throws {
        var world = SignalWorld()
        let oldest = world.signal(age: -10), newer = world.signal(age: 10)
        if newerMovedUp { world.state.move(signalId: newer, .up) }
        let (higher, lower) = newerMovedUp ? (newer, oldest) : (oldest, newer)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let router = ItemRouter(workspace: h.workspace, now: { world.now })
        let read = SignalRead(items: [world.ticket()], complete: true)
        let ids = router.apply(observations: [.init(signals: [lower], read: read), .init(signals: [higher], read: read)])
        let task = try #require(h.workspace.state.tasks.first)
        #expect(ids == [task.id] && h.workspace.state.tasks.count == 1)
        #expect(task.signalTask?.current.signal == higher)
        #expect(task.signalTask?.pendingStages.map(\.signal) == [lower])
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

    @Test func aLaunchErrorAfterTheStageWasBlockedLeavesTheFirstReason() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .launching }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now },
            ports: .init(workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { task, _ in
                try h.workspace.mutate { state in
                    try state.updateSignalTask(task.id) { $0 = try SignalTransitions.apply(.block("Its worker stopped first."), to: $0, at: world.now) }
                }
                throw ActionUnavailable("The terminal could not open.")
            }, restore: { $0 }))
        var changes: [String] = []; runner.changed = { _, line in changes.append(line) }
        await runner.run(id)
        let record = try #require(h.workspace.state.task(id: id)?.signalTask)
        #expect(record.phase == .blocked && record.blockedReason == "Its worker stopped first.")
        #expect(changes.isEmpty)
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
                // As the app's checkout does: the worktree saved on the task.
                harness.workspace.mutate { $0.updateSignalItem(task.id) { $0.worktreePath = "/synthetic/shop/.worktrees/pay-1" } }
                harness.workspace.flush()
                return try #require(harness.workspace.state.task(id: task.id))
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

    /// The Done baseline is read once per stage, before its launch intent is saved, and saved with the stage.
    @Test func theDoneBaselineIsReadAndSavedBeforeTheLaunchIntent() async throws {
        var world = SignalWorld(); let signal = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let id = try #require(ItemRouter(workspace: h.workspace, now: { world.now })
            .apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true)).first)
        var reads = 0, launches = 0
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, _ in
                let saved = try h.file.load().task(id: id)
                #expect(saved?.signalTask?.doneMatched == true, "saved before the worker starts")
                launches += 1; return "worker-window"
            }, restore: { $0 }, doneMatches: { task in
                #expect(task.signalTask?.launch == nil, "read before the launch intent")
                reads += 1; return true
            }))
        await runner.run(id)
        #expect(reads == 1 && launches == 1 && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        h.workspace.mutate { $0.updateSignalTask(id) { $0.phase = .launching } }
        await runner.run(id)
        #expect(reads == 1 && launches == 2, "a relaunch of the same stage keeps its baseline")
    }
    /// An unreadable Done trigger holds the launch with its reason, and is read again only once the back-off ends.
    @Test func anUnreadableDoneTriggerHoldsTheLaunchUntilItsBackOffEnds() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .launching }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let clock = TestClock(world.now)
        var reads = 0, launches = 0, readable = false
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { clock.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, _ in launches += 1; return "worker-window" },
            restore: { $0 }, doneMatches: { _ in
                reads += 1
                guard readable else { throw ActionUnavailable("Jira did not answer.") }
                return false
            }))
        await runner.run(id)
        var record = try #require(h.workspace.state.task(id: id)?.signalTask)
        #expect(record.phase == .launching && record.launch == nil && launches == 0)
        #expect(record.blockedReason == "Its Done trigger could not be read: Jira did not answer.")
        readable = true
        await runner.run(id)
        #expect(reads == 1 && launches == 0, "the next reconcile inside the back-off reads nothing")
        clock.advance(by: StageRunner.heldBackOff)
        await runner.run(id)
        record = try #require(h.workspace.state.task(id: id)?.signalTask)
        #expect(reads == 2 && launches == 1 && record.phase == .working && record.doneMatched == false && record.blockedReason == nil)
    }
    struct Owner: CustomTestStringConvertible, Sendable {
        var author: String?
        var assignees: [String]
        var user: String?
        var review: Bool
        var testDescription: String { "\(author ?? "-") \(assignees) as \(user ?? "-")" }
    }
    nonisolated static let owners: [Owner] = [
        Owner(author: "alex", assignees: [], user: "alex", review: false),
        Owner(author: "sam", assignees: ["alex"], user: "alex", review: false),
        Owner(author: "sam", assignees: ["jo"], user: "alex", review: true),
        Owner(author: "Alex", assignees: [], user: "ALEX", review: false),
        Owner(author: "sam", assignees: ["ALEX"], user: "alex", review: false),
        Owner(author: "alex", assignees: [], user: nil, review: true),
    ]
    /// A merge request is a review task unless the account authored it or is one of its assignees, whatever the
    /// signal's query; the review task never pushes.
    @Test(arguments: owners) func aMergeRequestIsAReviewTaskUnlessItIsTheAccountsOwn(_ row: Owner) throws {
        var world = SignalWorld(); let signal = world.signal(start: SignalTrigger(source: .gitLab, query: "reviewer:@me"))
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let request = MergeRequest(iid: 7, title: "Work", sourceBranch: "feat/work", targetBranch: "main", author: row.author, state: "opened",
                                   draft: false, url: "https://git.example/shop/web/-/merge_requests/7")
        let item = SignalItem(item: .request(remote: "https://git.example/shop/web", number: 7), title: "Work", mergeRequest: request, assignees: row.assignees)
        let id = try #require(ItemRouter(workspace: h.workspace, now: { world.now })
            .apply(signals: [signal], read: SignalRead(items: [item], complete: true, accountUser: row.user)).first)
        #expect(h.workspace.state.task(id: id)?.kind == (row.review ? .review : .task))
    }
    @Test func aTicketIsAlwaysTheAccountsOwnTask() throws {
        var world = SignalWorld(); let signal = world.signal()
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let id = try #require(ItemRouter(workspace: h.workspace, now: { world.now })
            .apply(signals: [signal], read: SignalRead(items: [world.ticket()], complete: true)).first)
        #expect(h.workspace.state.task(id: id)?.kind == .task)
    }

    @Test func aSecondSignalWaitsForTheWorkersTurnAndStartsBeforeTheFirstStagesRemove() async throws {
        var world = SignalWorld()
        let first = world.signal(then: .remove), second = world.signal(name: "Review it", age: 1)
        world.state.signals[1].work.prompt = "/psg:review"
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var working = false, prompts: [String] = []
        let router = ItemRouter(workspace: h.workspace, now: { world.now }, workerIsWorking: { _ in working })
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in working }, prepare: { task, _ in
                // As the app's checkout does: the worktree saved on the task.
                h.workspace.mutate { $0.updateSignalItem(task.id) { $0.worktreePath = "/synthetic/work" } }
                h.workspace.flush(); return try #require(h.workspace.state.task(id: task.id))
            },
            launch: { _, prompt in prompts.append(prompt); return "same-window" }, restore: { $0 }))
        let id = try #require(router.apply(signals: [first], read: SignalRead(items: [world.ticket()], complete: true)).first)
        await runner.run(id)
        working = true
        #expect(router.apply(signals: [second], read: SignalRead(items: [world.ticket()], complete: true)).isEmpty)
        await runner.run(id)
        #expect(prompts.count == 1)
        #expect(h.workspace.state.task(id: id)?.signalTask?.pendingStages.count == 1)
        working = false
        try await runner.finish(id, action: .finish)
        #expect(prompts.count == 2 && prompts.last?.contains("/psg:review") == true)
        #expect(h.workspace.state.tasks.count == 1)
        #expect(h.workspace.state.task(id: id)?.signalTask?.current.signal == second)
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
        try await runner.finish(id, action: .finish)
        if multiple {
            #expect(agents.isEmpty)
            #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .choosing)
            #expect(h.workspace.state.task(id: id)?.signalTask?.choosableRows == [SignalWorld.agent, codex])
            try await runner.choose(id, choice: AgentChoiceRecord(row: codex, project: nil, reason: "A review suits Codex.",
                                                                  decided: .oracleAgreed, round: 1, note: nil, at: world.now))
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
                h.workspace.mutate { $0.takeOver(id) }
                h.workspace.mutate { $0.updateSignalItem(task.id) { $0.worktreePath = "/synthetic/work" } }
                return try #require(h.workspace.state.task(id: task.id))
            }, launch: { _, _ in launched = true; return "unexpected" }, restore: { $0 }))
        await runner.run(id)
        #expect(!launched && h.workspace.state.task(id: id)?.signalTask == nil && h.workspace.state.task(id: id)?.takenOver == true)
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
            workerIsWorking: { _ in false }, prepare: { task, _ in
                // As the app's checkout does: the worktree saved on the task.
                h.workspace.mutate { $0.updateSignalItem(task.id) { $0.worktreePath = "/synthetic/work" } }
                h.workspace.flush(); return try #require(h.workspace.state.task(id: task.id))
            },
            launch: { _, _ in "same-window" }, restore: { task in
                // As the app's restore does: the worktree back, then the row in the sidebar.
                restored = true
                h.workspace.mutate { state in
                    state.moveFromArchive(id: task.id)
                    state.updateSignalItem(task.id) { $0.worktreePath = "/synthetic/work" }
                }
                return try #require(h.workspace.state.task(id: task.id))
            }))
        #expect(router.apply(signals: [second], read: SignalRead(items: [world.ticket()], complete: true)) == [id])
        await runner.run(id)
        #expect(restored && h.workspace.state.archive.isEmpty && h.workspace.state.tasks.map(\.id) == [id])
        #expect(h.workspace.state.task(id: id)?.signalTask?.stage == 2)
    }

}
