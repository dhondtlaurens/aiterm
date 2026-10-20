import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct RunSchedulerTests {
    typealias F = OperatorFixtures

    private func startable(_ s: AppState) -> [UUID] {
        RunScheduler.startable(in: s, run: F.runId)
    }

    @Test func aQueuedTaskWithNoDependenciesStartsInPlanOrder() {
        let a = F.task("A"), b = F.task("B")
        #expect(startable(F.state(F.run(), [a, b])) == [a.id, b.id])
    }

    /// There is no cap: every ready task starts, and a claim takes all of them.
    @Test func everyReadyTaskStarts() {
        let tasks = (1...6).map { F.task("T\($0)") }
        var s = F.state(F.run(), tasks)
        #expect(startable(s) == tasks.map(\.id))
        #expect(RunScheduler.claim(in: &s, now: F.epoch) == tasks.map(\.id))
        #expect(s.tasks.allSatisfy { $0.operated?.state == .working })
    }

    @Test(arguments: [
        (DependencyKind.order, OperatedState.accepted, true), (.order, .noChange, true), (.order, .published, true),
        (.order, .working, false), (.order, .failed, false), (.order, .stopped, false),
        (.code, .accepted, true), (.code, .published, true), (.code, .noChange, false), (.code, .working, false),
    ])
    func aDependentWaitsForItsParent(_ kind: DependencyKind, _ parentState: OperatedState, _ starts: Bool) {
        let parent = F.task("P", parentState), child = F.task("C", dependsOn: [TaskDependency(task: parent.id, kind: kind)])
        #expect(startable(F.state(F.run(), [parent, child])) == (starts ? [child.id] : []))
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

    /// Working tasks anywhere, taken over or not, hold nobody else back: only the queued ones are listed.
    @Test func workingAndBlockedTasksAreNotListed() {
        let otherRun = F.run(id: UUID())
        var taken = F.task("T", .working)
        taken.operated?.takenOver = true
        var s = F.state(F.run(), [F.task("A"), F.task("B"), F.task("W", .working, run: otherRun.id), F.task("X", .blocked), taken])
        s.runs.append(otherRun)
        #expect(startable(s).count == 2)
    }

    /// Operations are listed oldest first, each in its plan order.
    @Test func operationsAreListedOldestFirst() {
        var older = F.run(id: UUID()), newer = F.run(id: UUID())
        older.createdAt = F.epoch
        newer.createdAt = F.epoch.addingTimeInterval(60)
        let n1 = F.task("N1", run: newer.id), n2 = F.task("N2", run: newer.id)
        let o1 = F.task("O1", run: older.id), o2 = F.task("O2", run: older.id)
        var s = F.state(newer, [n1, n2, o1, o2])
        s.runs.append(older)

        #expect(RunScheduler.startable(in: s) == [o1.id, o2.id, n1.id, n2.id])
        #expect(RunScheduler.startable(in: s, run: newer.id) == [n1.id, n2.id])
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

    @Test(arguments: [DependencyKind.code, .order])
    func aForeignMergeBlocksItsQueuedChildWithTheRecordedReason(_ kind: DependencyKind) {
        var parent = F.task("P", .accepted)
        let reason = "P was merged on the host into release, not main"
        parent.operated?.publication = TaskPublication(mergedSHA: "foreign", mergedHead: "accepted", problem: reason)
        let child = F.task("C", dependsOn: [TaskDependency(task: parent.id, kind: kind)])
        var state = F.state(F.run(), [parent, child])
        #expect(startable(state).isEmpty)
        #expect(RunScheduler.claim(in: &state, now: F.epoch).isEmpty)
        #expect(state.task(id: child.id)?.operated?.state == .blocked)
        #expect(state.task(id: child.id)?.operated?.blockedReason == reason)
        #expect(state.task(id: child.id)?.operated?.launch == nil)
    }

    /// A state holding one id twice (a hand-edited or half-merged `state.json`) must not trap, and
    /// must not start the task twice: no second worktree or window for one task.
    @Test func twoTasksWithOneIdDoNotTrapTheSchedulerAndStartOnce() {
        var world = OperatedWorld()
        let run = world.addRun()
        let first = world.addTask("Q-1", run: run)
        world.addTask("Q-2", run: run, state: .working)
        var twin = world.state.tasks[0]
        twin.operated?.key = "Q-1-twin"
        world.state.tasks.append(twin)
        #expect(world.state.tasks.filter { $0.id == first }.count == 2)
        #expect(RunScheduler.startable(in: world.state) == [first])
        #expect(RunScheduler.startable(in: world.state, run: run) == [first])
    }

    /// Corrupt state may reuse an id in another operation: its first copy cannot decide whether
    /// the requested operation's copy is ready or make the other operation's tasks appear here.
    @Test(arguments: [OperatedState.queued, .blocked])
    func aSingleRunUsesItsOwnCopyOfADuplicateTaskId(_ requestedState: OperatedState) {
        let requested = F.run(), other = F.run(id: UUID()), sharedId = UUID()
        let foreign = F.task("OTHER", requestedState == .queued ? .blocked : .queued, id: sharedId, run: other.id)
        let local = F.task("LOCAL", requestedState, id: sharedId, run: requested.id)
        let localOnly = F.task("LOCAL-ONLY"), foreignOnly = F.task("OTHER-ONLY", run: other.id)
        var state = F.state(requested, [foreign, foreignOnly, local, localOnly])
        state.runs.append(other)

        #expect(RunScheduler.startable(in: state, run: requested.id) ==
                (requestedState == .queued ? [sharedId, localOnly.id] : [localOnly.id]))
    }

    @Test func twoTasksWithOneIdDoNotTrapTheStatus() throws {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("P-1", run: run)
        world.addTask("C-1", run: run, dependsOn: [TaskDependency(task: parent, kind: .order)])
        world.state.tasks.append(world.state.tasks[0])
        #expect(PlanRevision.cycle(in: world.state.tasks(inRun: run)) == nil)
        let status = try #require(RunStatus.build(state: world.state, run: run, revision: 1, live: [:]))
        #expect(status.tasks.count == 3)
    }

    @Test func aPlanHoldingOneIdTwiceIsRefusedNotHalfRead() {
        var world = OperatedWorld()
        let run = world.addRun()
        let x = world.addTask("X-1", run: run)
        world.addTask("X-2", run: run, dependsOn: [TaskDependency(task: x, kind: .order)])
        var twin = world.state.tasks[0]
        twin.operated?.key = "X-1-twin"
        world.state.tasks.append(twin)
        #expect(throws: PlanRevision.Failure.duplicateTask(key: "X-1-twin")) {
            try PlanRevision.validate(world.state, run: run, milestone: .m3)
        }
    }

    /// The twin, not the first copy, closes the circle: a first-wins read would see none.
    @Test func aCircleInTheTwinIsNotHiddenByTheFirstCopy() {
        var world = OperatedWorld()
        let run = world.addRun()
        let x = world.addTask("X-1", run: run)
        let y = world.addTask("Y-1", run: run, dependsOn: [TaskDependency(task: x, kind: .order)])
        var twin = world.state.tasks[0]
        twin.operated?.key = "X-1-twin"
        twin.operated?.dependsOn = [TaskDependency(task: y, kind: .order)]
        world.state.tasks.append(twin)
        #expect(throws: PlanRevision.Failure.duplicateTask(key: "X-1-twin")) {
            try PlanRevision.validate(world.state, run: run, milestone: .m3)
        }
    }

    /// The twin sits in another project, so a code child's parent is in the wrong one only there.
    @Test func aCodeParentInTheTwinsOtherProjectIsNotHiddenByTheFirstCopy() {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("P-1", run: run, state: .accepted, acceptedSHA: "4f2a91c")
        world.addTask("C-1", run: run, dependsOn: [TaskDependency(task: parent, kind: .code)])
        var twin = world.state.tasks[0]
        twin.operated?.key = "P-1-twin"
        twin.projectId = UUID()
        world.state.tasks.append(twin)
        #expect(throws: PlanRevision.Failure.duplicateTask(key: "P-1-twin")) {
            try PlanRevision.validate(world.state, run: run, milestone: .m3)
        }
    }

    @Test func aPlanWithEveryIdOnceStillValidates() throws {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("P-1", run: run)
        world.addTask("C-1", run: run, dependsOn: [TaskDependency(task: parent, kind: .order)])
        try PlanRevision.validate(world.state, run: run, milestone: .m3)
    }

    @Test func aTaskNeverStartsBeforeItsParent() {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("P-1", run: run)
        world.addTask("C-1", run: run, dependsOn: [TaskDependency(task: parent, kind: .order)])
        #expect(RunScheduler.startable(in: world.state, run: run) == [parent])
    }
}
