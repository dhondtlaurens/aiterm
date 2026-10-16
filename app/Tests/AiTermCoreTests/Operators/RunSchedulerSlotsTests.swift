import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// M2's slots: the cap counts every operation's workers, limits starts only, and never lets a task
/// start before its dependencies.
@Suite struct RunSchedulerSlotsTests {
    @Test func theCapCountsWorkersInEveryOperation() {
        var world = OperatedWorld()
        let a = world.addRun(), b = world.addRun(age: 60)
        for key in ["A-1", "A-2", "A-3"] { world.addTask(key, run: a) }
        world.addTask("B-1", run: b, state: .working)
        #expect(RunScheduler.occupiedSlots(in: world.state) == 1)
        #expect(RunScheduler.startable(in: world.state, run: a, maxParallel: 2).count == 1)
        #expect(RunScheduler.startable(in: world.state, run: a, maxParallel: 3).count == 2)
        #expect(RunScheduler.startable(in: world.state, run: a, maxParallel: 5).count == 3)
    }

    @Test func aLoweredCapStartsNothingAndStopsNothing() {
        var world = OperatedWorld()
        let run = world.addRun()
        for key in ["W-1", "W-2", "W-3"] { world.addTask(key, run: run, state: .working) }
        world.addTask("Q-1", run: run)
        #expect(RunScheduler.freeSlots(in: world.state, maxParallel: 2) == 0)
        #expect(RunScheduler.startable(in: world.state, run: run, maxParallel: 2).isEmpty)
        #expect(world.state.tasks.filter { $0.operated?.state == .working }.count == 3)
    }

    @Test func aBlockedTaskHoldsNoSlotAndATakenOverWorkerHoldsOne() {
        var world = OperatedWorld()
        let run = world.addRun()
        world.addTask("B-1", run: run, state: .blocked)
        let driven = world.addTask("W-1", run: run, state: .working)
        world.update(driven) { $0.takenOver = true }
        world.addTask("Q-1", run: run)
        world.addTask("Q-2", run: run)
        #expect(RunScheduler.occupiedSlots(in: world.state) == 1)
        #expect(RunScheduler.startable(in: world.state, run: run, maxParallel: 3).count == 2)
    }

    @Test func aFreeSlotNeverStartsATaskBeforeItsParent() {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("P-1", run: run)
        world.addTask("C-1", run: run, dependsOn: [TaskDependency(task: parent, kind: .order)])
        #expect(RunScheduler.startable(in: world.state, run: run, maxParallel: 5) == [parent])
    }

    @Test func aPausedOperationStartsNothing() {
        var world = OperatedWorld()
        let run = world.addRun(.paused)
        world.addTask("Q-1", run: run)
        #expect(RunScheduler.startable(in: world.state, run: run, maxParallel: 5).isEmpty)
    }

    @Test func aResumedTaskMayExceedTheCapAndNewStartsWaitUntilItIsUnderAgain() {
        var world = OperatedWorld()
        let run = world.addRun()
        let blocked = world.addTask("B-1", run: run, state: .blocked)
        world.addTask("W-1", run: run, state: .working)
        world.addTask("Q-1", run: run)
        #expect(RunScheduler.startable(in: world.state, run: run, maxParallel: 2).count == 1)
        world.update(blocked) { $0.state = .working }
        world.addTask("W-2", run: run, state: .working)
        #expect(RunScheduler.occupiedSlots(in: world.state) == 3)
        #expect(RunScheduler.freeSlots(in: world.state, maxParallel: 2) == 0)
        #expect(RunScheduler.startable(in: world.state, run: run, maxParallel: 2).isEmpty)
    }

    @Test func aTaskYouMadeHoldsNoSlot() {
        var world = OperatedWorld()
        let run = world.addRun()
        world.addTask("W-1", run: run, state: .working)
        var yours = world.state.tasks[0]
        yours.id = UUID(); yours.operated = nil
        world.state.tasks.append(yours)
        #expect(RunScheduler.occupiedSlots(in: world.state) == 1)
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
        #expect(RunScheduler.occupiedSlots(in: world.state) == 1)
        #expect(RunScheduler.startable(in: world.state, maxParallel: 5) == [first])
        #expect(RunScheduler.startable(in: world.state, run: run, maxParallel: 5) == [first])
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
            try PlanRevision.validate(world.state, run: run, milestone: .m2)
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
            try PlanRevision.validate(world.state, run: run, milestone: .m2)
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
            try PlanRevision.validate(world.state, run: run, milestone: .m2)
        }
    }

    @Test func aPlanWithEveryIdOnceStillValidates() throws {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("P-1", run: run)
        world.addTask("C-1", run: run, dependsOn: [TaskDependency(task: parent, kind: .order)])
        try PlanRevision.validate(world.state, run: run, milestone: .m2)
    }
}
