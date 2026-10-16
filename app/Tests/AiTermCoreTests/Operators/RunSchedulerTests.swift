import Testing
import Foundation
@testable import AiTermCore

@Suite struct RunSchedulerTests {
    typealias F = OperatorFixtures

    private func startable(_ s: AppState, _ maxParallel: Int = 1) -> [UUID] {
        RunScheduler.startable(in: s, run: F.runId, maxParallel: maxParallel)
    }

    @Test func aQueuedTaskWithNoDependenciesStartsInPlanOrder() {
        let a = F.task("A"), b = F.task("B")
        #expect(startable(F.state(F.run(), [a, b])) == [a.id])
        #expect(startable(F.state(F.run(), [a, b]), 2) == [a.id, b.id])
    }

    @Test(arguments: [
        (DependencyKind.order, OperatedState.accepted, true), (.order, .noChange, true), (.order, .published, true),
        (.order, .working, false), (.order, .failed, false), (.order, .stopped, false),
        (.code, .accepted, true), (.code, .published, true), (.code, .noChange, false), (.code, .working, false),
    ])
    func aDependentWaitsForItsParent(_ kind: DependencyKind, _ parentState: OperatedState, _ starts: Bool) {
        let parent = F.task("P", parentState), child = F.task("C", dependsOn: [TaskDependency(task: parent.id, kind: kind)])
        // A parent still working takes the one slot, so the cap is raised past it.
        #expect(startable(F.state(F.run(), [parent, child]), 2) == (starts ? [child.id] : []))
    }

    @Test func aParentMissingFromTheWorkspaceHoldsItsChild() {
        let child = F.task("C", dependsOn: [TaskDependency(task: UUID(), kind: .order)])
        #expect(startable(F.state(F.run(), [child])).isEmpty)
    }

    @Test(arguments: [OperatorRunState.planning, .paused, .operatorOffline, .complete, .stopped])
    func onlyAnActiveRunStartsTasks(_ runState: OperatorRunState) {
        #expect(startable(F.state(F.run(state: runState), [F.task("A")])).isEmpty)
    }

    @Test func aTakenOverOrPlannedTaskDoesNotStart() {
        var taken = F.task("T")
        taken.operated?.takenOver = true
        #expect(startable(F.state(F.run(), [taken, F.task("P", .planned)])).isEmpty)
    }

    /// The slots are AiTerm's: a task working in another operation takes one, and so does one you
    /// took over; a blocked one takes none.
    @Test func workingTasksAnywhereTakeTheSlots() {
        let otherRun = F.run(id: UUID())
        var taken = F.task("T", .working)
        taken.operated?.takenOver = true
        var s = F.state(F.run(), [F.task("A"), F.task("B"), F.task("W", .working, run: otherRun.id), F.task("X", .blocked)])
        s.runs.append(otherRun)
        #expect(startable(s, 1).isEmpty)
        #expect(startable(s, 2).count == 1)
        #expect(startable(s, 0).isEmpty)
        s.tasks.append(taken)
        #expect(startable(s, 2).isEmpty)
    }

    /// Operations take turns for the free slots, oldest first, one task each per turn.
    @Test func operationsTakeTurnsOldestFirst() {
        var older = F.run(id: UUID()), newer = F.run(id: UUID())
        older.createdAt = F.epoch
        newer.createdAt = F.epoch.addingTimeInterval(60)
        let n1 = F.task("N1", run: newer.id), n2 = F.task("N2", run: newer.id)
        let o1 = F.task("O1", run: older.id), o2 = F.task("O2", run: older.id)
        var s = F.state(newer, [n1, n2, o1, o2])
        s.runs.append(older)

        #expect(RunScheduler.startable(in: s, maxParallel: 1) == [o1.id])
        #expect(RunScheduler.startable(in: s, maxParallel: 3) == [o1.id, n1.id, o2.id])
        #expect(RunScheduler.startable(in: s, run: newer.id, maxParallel: 1).isEmpty, "the older operation's turn")
        #expect(RunScheduler.startable(in: s, run: newer.id, maxParallel: 2) == [n1.id])
    }

    @Test func aCodeChildStartsFromItsParentsAcceptedSHA() {
        var parent = F.task("P", .accepted)
        parent.operated?.acceptance = F.acceptance("4f2a91c0ffee")
        let child = F.task("C", dependsOn: [TaskDependency(task: parent.id, kind: .code)])
        let orderOnly = F.task("O", dependsOn: [TaskDependency(task: parent.id, kind: .order)])
        let s = F.state(F.run(), [parent, child, orderOnly])
        #expect(RunScheduler.baseCommit(for: child.id, in: s) == "4f2a91c0ffee")
        #expect(RunScheduler.baseCommit(for: orderOnly.id, in: s) == nil)
    }

    @Test func aRunIsCompleteWhenEveryTaskIsAtItsEndAndNoQuestionIsOpen() {
        let done = [F.task("A", .accepted), F.task("B", .noChange), F.task("C", .stopped), F.task("D", .published, end: .merge)]
        var run = F.run()
        #expect(RunScheduler.isComplete(run, in: F.state(run, done)))
        #expect(!RunScheduler.isComplete(run, in: F.state(run, done + [F.task("E", .working)])))
        #expect(!RunScheduler.isComplete(run, in: F.state(run, done + [F.task("M", .accepted, end: .draftMR)])),
                "a draft MR's task ends when it is published")
        #expect(!RunScheduler.isComplete(run, in: F.state(run, [])))
        run.questions = [OperatorQuestion(id: "q", text: "?", task: nil, askedAt: F.epoch)]
        #expect(!RunScheduler.isComplete(run, in: F.state(run, done)))
        run.questions[0].resolution = "yes"
        #expect(RunScheduler.isComplete(run, in: F.state(run, done)))
    }
}
