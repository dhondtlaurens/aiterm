import Testing
import Foundation
@testable import AiTermCore

/// The transitions applied to a workspace: the context read from the task's run, and the
/// dependents a failure, a stop or a retry carries along (spec §8, "What else happens").
@Suite struct OperatedCascadeTests {
    typealias F = OperatorFixtures

    /// A → B → C by `order`, D by `code` on A; A working, the rest queued, E planned on A.
    private func chain() -> (AppState, a: UUID, b: UUID, c: UUID, d: UUID, e: UUID) {
        let a = F.task("A", .working), b = F.task("B", .queued, dependsOn: [TaskDependency(task: a.id, kind: .order)])
        let c = F.task("C", .queued, dependsOn: [TaskDependency(task: b.id, kind: .order)])
        let d = F.task("D", .queued, dependsOn: [TaskDependency(task: a.id, kind: .code)])
        let e = F.task("E", .planned, revision: 2, dependsOn: [TaskDependency(task: a.id, kind: .order)])
        return (F.state(F.run(), [a, b, c, d, e]), a.id, b.id, c.id, d.id, e.id)
    }

    private func state(of id: UUID, _ state: AppState) -> OperatedState? { state.task(id: id)?.operated?.state }

    @Test func aFailureBlocksEveryQueuedDependentAndLeavesThePlannedOne() throws {
        var (s, a, b, c, d, e) = chain()

        let changed = try OperatedTransitions.apply(.fail(reason: "red"), toTask: a, in: &s, by: .operatorTool)

        #expect(changed == [a, b, d, c])
        #expect([b, c, d].allSatisfy { state(of: $0, s) == .blocked })
        #expect(s.task(id: c)?.operated?.blockedReason == "upstream failed: A")
        #expect(state(of: e, s) == .planned)
    }

    @Test func aStopBlocksDependentsWithItsOwnReason() throws {
        var (s, a, b, _, _, _) = chain()
        try OperatedTransitions.apply(.stop, toTask: a, in: &s, by: .you)
        #expect(s.task(id: b)?.operated?.blockedReason == "upstream stopped: A")
    }

    @Test func aRetryPutsWhatItsFailureBlockedBackInTheQueue() throws {
        var (s, a, b, c, d, _) = chain()
        try OperatedTransitions.apply(.fail(reason: "red"), toTask: a, in: &s, by: .operatorTool)
        // A dependent blocked for a reason of its own stays blocked.
        s.tasks[s.tasks.firstIndex { $0.id == d }!].operated?.blockedReason = "needs you"

        let changed = try OperatedTransitions.apply(.retry, toTask: a, in: &s, by: .operatorTool)

        #expect(changed == [a, b, c])
        #expect(state(of: a, s) == .queued && state(of: b, s) == .queued && state(of: c, s) == .queued)
        #expect(state(of: d, s) == .blocked)
    }

    /// A dependent held back by its parent never ran, so resuming it (the operator's call, once the
    /// parent is sorted out another way) puts it back in the queue, not in a session it never had.
    @Test func aDependentBlockedByItsParentResumesToTheQueue() throws {
        var (s, a, b, _, _, _) = chain()
        try OperatedTransitions.apply(.fail(reason: "red"), toTask: a, in: &s, by: .operatorTool)
        #expect(s.task(id: b)?.operated?.blockedFrom == .queued)
        s.runs[0].state = .active
        try OperatedTransitions.apply(.resume, toTask: b, in: &s, by: .operatorTool)
        #expect(state(of: b, s) == .queued && s.task(id: b)?.operated?.blockedReason == nil)
    }

    @Test func aRepeatChangesNothing() throws {
        var (s, a, _, _, _, _) = chain()
        try OperatedTransitions.apply(.fail(reason: "red"), toTask: a, in: &s, by: .operatorTool)
        let before = s
        #expect(try OperatedTransitions.apply(.fail(reason: "red"), toTask: a, in: &s, by: .operatorTool) == [])
        #expect(s == before)
    }

    /// A started `code` dependent does not hold its parent back (spec §8): the parent is accepted again on another
    /// commit, and the caller replaces what the dependent was built on (`UpstreamReplacement`).
    @Test func aParentIsAcceptedAgainAfterItsCodeDependentStarted() throws {
        let head = "4f2a91c0d1e2f3a4"
        var (s, a, _, _, d, _) = chain()
        try OperatedTransitions.apply(.accept(F.acceptance(head), branchHead: head), toTask: a, in: &s, by: .operatorTool)
        try OperatedTransitions.apply(.start(LaunchAttempt(number: 1, requestedAt: F.epoch)), toTask: d, in: &s, by: .aiterm)

        #expect(try OperatedTransitions.apply(.accept(F.acceptance("bbbbbbb1"), branchHead: "bbbbbbb1"), toTask: a, in: &s,
                                              by: .operatorTool) == [a])
        #expect(s.tasks.first { $0.id == a }?.operated?.acceptance?.resultSHA == "bbbbbbb1")
    }

    @Test func theRunsStateAndRetryLimitApply() throws {
        var (s, a, _, _, _, _) = chain()
        s.runs[0].state = .paused
        #expect(throws: OperatedTransitionError.runIs(.paused)) {
            try OperatedTransitions.apply(.fail(reason: "x"), toTask: a, in: &s, by: .operatorTool)
        }
        s.runs[0].state = .active
        try OperatedTransitions.apply(.fail(reason: "x"), toTask: a, in: &s, by: .operatorTool)
        let index = try #require(s.tasks.firstIndex { $0.id == a })
        s.tasks[index].operated?.retriesUsed = OperatorTiming.retries
        #expect(throws: OperatedTransitionError.noRetriesLeft(limit: 2)) {
            try OperatedTransitions.apply(.retry, toTask: a, in: &s, by: .operatorTool)
        }
    }

    @Test func aTaskOutsideABroadcastIsSaid() {
        var s = F.state(F.run(), [])
        var mine = F.task("MINE")
        mine.operated = nil
        s.tasks = [mine]
        #expect(throws: OperatedTransitionError.notOperated(mine.id)) {
            try OperatedTransitions.apply(.stop, toTask: mine.id, in: &s, by: .you)
        }
        let ghost = UUID()
        #expect(throws: OperatedTransitionError.unknownTask(ghost)) {
            try OperatedTransitions.apply(.stop, toTask: ghost, in: &s, by: .you)
        }
    }

    @Test func dependentsAreFoundThroughTheChainOnce() {
        let (s, a, b, c, d, e) = chain()
        #expect(OperatedTransitions.dependents(of: a, in: s.tasks) == [b, d, e, c])
        #expect(OperatedTransitions.dependents(of: c, in: s.tasks).isEmpty)
    }
}
