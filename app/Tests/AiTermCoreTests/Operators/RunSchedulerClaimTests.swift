import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Starts are claimed in one synchronous change before anything launches: two tasks finishing at
/// once each end in a claim, and the second sees the first's.
@Suite struct RunSchedulerClaimTests {
    let now = Date(timeIntervalSince1970: 1_800_000_600)

    @Test func twoTasksFinishingAtOnceClaimEachQueuedTaskOnce() {
        var world = OperatedWorld()
        let run = world.addRun()
        let first = world.addTask("W-1", run: run, state: .working), second = world.addTask("W-2", run: run, state: .working)
        let queued = (1...3).map { world.addTask("Q-\($0)", run: run) }
        world.update(first) { $0.state = .accepted }
        world.update(second) { $0.state = .noChange }

        let claimedFirst = RunScheduler.claim(in: &world.state, now: now)
        let claimedSecond = RunScheduler.claim(in: &world.state, now: now)

        #expect(Set(claimedFirst) == Set(queued))
        #expect(claimedSecond.isEmpty, "the second finds the first's claims taken")
        #expect(world.state.tasks.filter { $0.operated?.state == .working }.count == 3)
        for id in claimedFirst {
            #expect(world.operated(id)?.launch == LaunchAttempt(number: 1, requestedAt: now), "the launch intent is in the same change")
        }
    }

    @Test func aClaimedTaskIsNeverClaimedAgain() {
        var world = OperatedWorld()
        let run = world.addRun()
        let first = world.addTask("Q-1", run: run), second = world.addTask("Q-2", run: run)
        #expect(RunScheduler.claim(in: &world.state, now: now) == [first, second])
        #expect(RunScheduler.claim(in: &world.state, now: now).isEmpty)
    }

    /// The claim is the scheduler's one list, not a list per operation: the oldest operation's tasks come first.
    @Test func operationsAreClaimedOldestFirst() {
        var world = OperatedWorld()
        let older = world.addRun(), newer = world.addRun(age: 60)
        let olderTasks = (1...3).map { world.addTask("A-\($0)", run: older) }
        let newerTask = world.addTask("B-1", run: newer)
        let claimed = RunScheduler.claim(in: &world.state, now: now)
        #expect(claimed == olderTasks + [newerTask])
    }

    @Test func aPausedOrStoppedOperationClaimsNothing() {
        var world = OperatedWorld()
        world.addTask("P-1", run: world.addRun(.paused))
        world.addTask("S-1", run: world.addRun(.stopped))
        #expect(RunScheduler.claim(in: &world.state, now: now).isEmpty)
    }

    /// A retried task (failed → queued) comes back with its last attempt recorded; its new launch is the next.
    @Test func aRetriedTaskIsLaunchedAsItsNextAttempt() {
        var world = OperatedWorld()
        let run = world.addRun()
        let retried = world.addTask("R-1", run: run)
        world.update(retried) { $0.launch = LaunchAttempt(number: 1, requestedAt: now.addingTimeInterval(-600)); $0.retriesUsed = 1 }
        #expect(RunScheduler.claim(in: &world.state, now: now) == [retried])
        #expect(world.operated(retried)?.launch == LaunchAttempt(number: 2, requestedAt: now))
    }

    /// A state holding one id twice (F3): its claim is made once, and a later claim, which meets the
    /// twin still queued, claims it no second time — never a second worktree or window for one task.
    @Test func aTaskIdHeldTwiceIsClaimedOnce() {
        var world = OperatedWorld()
        let run = world.addRun()
        let first = world.addTask("Q-1", run: run)
        var twin = world.state.tasks[0]
        twin.operated?.key = "Q-1-twin"
        world.state.tasks.append(twin)
        #expect(RunScheduler.claim(in: &world.state, now: now) == [first])
        #expect(RunScheduler.claim(in: &world.state, now: now.addingTimeInterval(1)).isEmpty)
        #expect(world.operated(first)?.launch == LaunchAttempt(number: 1, requestedAt: now))
    }

    /// A queued task whose window is already being opened (a reopen) is left out: it is not claimed,
    /// and the next one starts.
    @Test func aTaskAlreadyStartingIsLeftOut() {
        var world = OperatedWorld()
        let run = world.addRun()
        let reopening = world.addTask("Q-1", run: run), next = world.addTask("Q-2", run: run)
        #expect(RunScheduler.claim(in: &world.state, now: now, excluding: [reopening]) == [next])
        #expect(world.operated(reopening)?.state == .queued)
    }
}
