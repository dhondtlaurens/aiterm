import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalWatchTests {
    private func stages(_ h: SignalHarness, at: Date) -> StageRunner {
        StageRunner(workspace: h.workspace, journal: h.journal, now: { at }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, _ in "worker-window" }, restore: { $0 }))
    }
    private func ready(merged: Bool = false) -> RequestWatch.Snapshot {
        var facts = DoneCheck.Facts()
        facts.hostReadComplete = true; facts.approved = true; facts.threadsResolved = true; facts.merged = merged
        return .init(reference: SignalRequestRef(remote: "git@git.example:shop/web.git", number: 7), facts: facts,
                     head: "aabbcc", localHead: "aabbcc", approvals: true, greenChecks: true)
    }
    @Test func aDiscoveredRequestAddsTheOrdinaryClickableBadge() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .approved), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }; let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        let link = MergeRequestRef(iid: 7, title: "Retries", url: "https://git.example/shop/web/-/merge_requests/7")
        var snapshot = ready(); snapshot.link = link
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in snapshot }, oracleMerge: { _, _ in false }, merge: { _, _ in }))
        await watch.pass()
        #expect(h.workspace.state.task(id: id)?.mr == link)
    }
    @Test func theOperatorJudgesDoneBeforeItsMergeThenFinishesAfterHostConfirmation() async throws {
        var world = SignalWorld(); let signal = world.signal(); world.state.signals[0].finish.mergesWhenReady = true
        let id = world.workingTask(signal: signal), h = try SignalHarness(world); defer { h.cleanUp() }; let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        var merged = false, merges = 0
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { task in
                var snapshot = ready(merged: merged); snapshot.facts.operatorJudged = task.signalTask?.operatorJudged == true; return snapshot
            }, oracleMerge: { _, _ in true }, merge: { _, _ in merged = true; merges += 1 }))
        await watch.pass(); #expect(merges == 0)
        try await runner.finish(id, action: .watch(.operatorJudges), judged: true)
        await watch.pass()
        #expect(merges == 1 && h.workspace.state.task(id: id)?.signalTask?.phase == .done)
    }
    @Test func anApprovedRequestArchivesOnlyAfterItsConditionHolds() async throws {
        var world = SignalWorld(); let signal = world.signal(then: .archive, done: .approved), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        var archived = 0, read = 0
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { task, allowed in
                #expect(allowed()); archived += 1
                h.workspace.mutate { $0.moveToArchive(taskId: task.id, branch: task.branch, at: world.now) }
            }, remove: { _, _ in Issue.record("It should archive") }))
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in read += 1; return ready() },
            oracleMerge: { _, _ in Issue.record("No merge requested"); return false }, merge: { _, _ in Issue.record("No merge requested") }))
        await watch.pass()
        #expect(archived == 1 && read == 1)
        #expect(h.workspace.state.archived(id: task)?.task.signalTask?.phase == .archived)
        await watch.pass()
        #expect(archived == 1 && read == 1)
    }

    @Test func choosingMergedOnlyWatchesForThePersonsMergeAndNeverOptsIntoOne() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .merged), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        var merged = false
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in ready(merged: merged) },
            oracleMerge: { _, _ in Issue.record("No merge was opted into"); return false },
            merge: { _, _ in Issue.record("No merge was opted into") }))
        await watch.pass()
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .working)
        merged = true; await watch.pass()
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .done)
    }

    @Test(arguments: ["approval", "checks", "threads", "head", "oracle", "changed-head"])
    func aMergeRequiresTheWholeFloorAndTheOraclesYes(reason: String) async throws {
        var world = SignalWorld(); let signal = world.signal(done: .approved)
        world.state.signals[0].finish.mergesWhenReady = true
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        var reads = 0, merges = 0
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in
                reads += 1
                var value = ready()
                if reason == "approval" { value.approvals = false }
                if reason == "checks" { value.greenChecks = false }
                if reason == "threads" { value.facts.threadsResolved = false }
                if reason == "head" { value.localHead = "different" }
                if reason == "changed-head", reads > 1 { value.head = "different"; value.localHead = "different" }
                return value
            }, oracleMerge: { _, _ in reason != "oracle" }, merge: { _, _ in merges += 1 }))
        await watch.pass()
        #expect(merges == 0)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase != .done)
        #expect(h.workspace.state.task(id: task)?.signalTask?.currentAct == nil)
    }

    @Test func mergeWhenReadyKeepsWatchingUntilTheMergeFloorHolds() async throws {
        var world = SignalWorld()
        let signal = world.signal(then: .archive, done: .approved)
        world.state.signals[0].finish.mergesWhenReady = true
        _ = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        var archived = false
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in archived = true }, remove: { _, _ in }))
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in var value = ready(); value.greenChecks = false; return value },
            oracleMerge: { _, _ in Issue.record("Checks are not green"); return false }, merge: { _, _ in Issue.record("Checks are not green") }))
        await watch.pass()
        #expect(!archived && h.workspace.state.tasks.first?.signalTask?.canRunThen == false)
    }

    @Test func aMergeIsConfirmedFromTheHostBeforeThenRuns() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .approved)
        world.state.signals[0].finish.mergesWhenReady = true
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        var events: [String] = [], merged = false
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in events.append("read"); return ready(merged: merged) },
            oracleMerge: { _, _ in events.append("oracle"); return true }, merge: { _, _ in events.append("merge"); merged = true }))
        await watch.pass()
        #expect(events == ["read", "oracle", "read", "merge", "read"])
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .done)
        #expect(h.workspace.state.task(id: task)?.signalTask?.thenApplied == true)
    }

    @Test func pendingWorkThatArrivesDuringCleanupPreventsThenAndContinuesTheSameTask() async throws {
        var world = SignalWorld(); let first = world.signal(then: .remove), next = world.signal(age: 1), task = world.workingTask(signal: first)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalTask(task) { $0.phase = .done } }
        let runner = stages(h, at: world.now)
        var removed = false
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, allowed in
                h.workspace.mutate { $0.updateSignalTask(task) { record in
                    record.pendingStages.append(SignalStage(signal: next, item: world.ticket().item, matchedAt: world.now,
                                                           configuration: world.state.signal(id: next), prompt: "/psg:review"))
                } }
                guard allowed() else { throw ActionUnavailable("A new stage waits.") }
                removed = true
            }))
        await then.apply(task)
        #expect(!removed && h.workspace.state.tasks.map(\.id) == [task])
        #expect(h.workspace.state.task(id: task)?.signalTask?.signal == next)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .working)
    }
}
