import Testing
import Foundation
@testable import AiTermCore

@Suite struct PlanRevisionTests {
    typealias F = OperatorFixtures

    /// A fresh gated run in planning, nothing submitted yet, two planned tasks in the open revision 1.
    private func planning(_ autonomy: Autonomy = .routine) -> (AppState, a: UUID, b: UUID) {
        let a = F.task("A", .planned), b = F.task("B", .planned, dependsOn: [TaskDependency(task: a.id, kind: .order)])
        let run = F.run(state: .planning, autonomy: autonomy, planRevision: 0, approvedRevision: nil)
        return (F.state(run, [a, b]), a.id, b.id)
    }

    private func states(_ s: AppState) -> [OperatedState?] { s.tasks.map { $0.operated?.state } }

    @Test func aGatedSubmissionWaitsForYourApproval() throws {
        var (s, a, b) = planning()
        #expect(s.runs[0].openRevision == 1 && !PlanRevision.awaitsApproval(s.runs[0]))

        let submitted = try PlanRevision.submit(1, run: F.runId, in: &s)

        #expect(submitted == PlanRevision.Submitted(revision: 1, awaitingApproval: true))
        #expect(s.runs[0].planRevision == 1 && s.runs[0].openRevision == 2)
        #expect(s.runs[0].state == .planning)
        #expect(states(s) == [.planned, .planned])
        #expect(PlanRevision.awaitsApproval(s.runs[0]))
        #expect(PlanRevision.pending(in: s, run: F.runId) == [PlanChange(task: a, kind: .added), PlanChange(task: b, kind: .added)])
    }

    @Test func approvingTheLatestRevisionReleasesItAndActivatesTheRun() throws {
        var (s, a, b) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)

        #expect(try PlanRevision.approve(1, run: F.runId, in: &s) == [a, b])

        #expect(states(s) == [.queued, .queued])
        #expect(s.runs[0].approvedRevision == 1 && s.runs[0].state == .active)
        #expect(!PlanRevision.awaitsApproval(s.runs[0]))
        #expect(try PlanRevision.approve(1, run: F.runId, in: &s) == [], "a second click changes nothing")
        #expect(PlanRevision.pending(in: s, run: F.runId).isEmpty)
    }

    @Test func nothingCanBeApprovedBeforeAPlanIsSubmitted() {
        var (s, _, _) = planning()
        #expect(throws: PlanRevision.Failure.nothingSubmitted) { try PlanRevision.approve(0, run: F.runId, in: &s) }
    }

    /// Spec §8: a stale approval click fails and releases nothing.
    @Test func approvingARevisionThatIsNoLongerTheLatestFails() throws {
        var (s, _, _) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)
        s.tasks.append(F.task("C", .planned, revision: 2))
        try PlanRevision.submit(2, run: F.runId, in: &s)
        let before = s

        #expect(throws: PlanRevision.Failure.stale(asked: 1, latest: 2)) { try PlanRevision.approve(1, run: F.runId, in: &s) }

        #expect(s == before)
    }

    /// A later revision needs approval of the difference only — shown as what it adds and what it
    /// changes — while the rest runs on.
    @Test func aLaterRevisionReleasesOnlyWhatItAddsOrChanges() throws {
        var (s, a, b) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)
        try PlanRevision.approve(1, run: F.runId, in: &s)
        let c = F.task("C", .planned, revision: 2)
        s.tasks.append(c)
        try PlanRevision.markChanged(task: b, in: &s)
        #expect(s.task(id: b)?.operated?.state == .planned, "a changed queued task waits for approval again")
        #expect(s.task(id: b)?.operated?.revision == 2 && s.task(id: b)?.operated?.firstRevision == 1)
        try PlanRevision.submit(2, run: F.runId, in: &s)

        #expect(PlanRevision.pending(in: s, run: F.runId) == [PlanChange(task: b, kind: .changed), PlanChange(task: c.id, kind: .added)])
        #expect(try PlanRevision.approve(2, run: F.runId, in: &s) == [b, c.id])
        #expect(s.task(id: a)?.operated?.state == .queued)
    }

    /// Tasks the operator adds to the open revision wait for its submission, not for this approval.
    @Test func theOpenRevisionIsNotPending() throws {
        var (s, _, _) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)
        let open = F.task("D", .planned, revision: 2)
        s.tasks.append(open)
        #expect(!PlanRevision.pending(in: s, run: F.runId).map(\.task).contains(open.id))
        try PlanRevision.approve(1, run: F.runId, in: &s)
        #expect(s.task(id: open.id)?.operated?.state == .planned)
    }

    @Test func anUngatedSubmissionReleasesAtOnce() throws {
        var (s, a, b) = planning(.trusted)

        let submitted = try PlanRevision.submit(1, run: F.runId, in: &s)

        #expect(submitted.released == [a, b] && !submitted.awaitingApproval)
        #expect(states(s) == [.queued, .queued] && s.runs[0].state == .active)
        #expect(!PlanRevision.awaitsApproval(s.runs[0]))
        #expect(throws: PlanRevision.Failure.notGated) { try PlanRevision.approve(1, run: F.runId, in: &s) }
    }

    /// Submitting the same revision again returns the earlier result and changes nothing.
    @Test func aRepeatedSubmissionIsTheEarlierResult() throws {
        var (s, _, _) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)
        let before = s

        let again = try PlanRevision.submit(1, run: F.runId, in: &s)

        #expect(again == PlanRevision.Submitted(revision: 1, awaitingApproval: true, repeated: true))
        #expect(s == before)
        #expect(throws: PlanRevision.Failure.unknownRevision(open: 2, asked: 5)) { try PlanRevision.submit(5, run: F.runId, in: &s) }
    }

    /// Revision 0 (or below) is not a closed revision: it is no repeat, and a fresh run has nothing to repeat.
    @Test(arguments: [0, -1])
    func aRevisionBelowOneIsNeverARepeat(_ revision: Int) {
        var (s, _, _) = planning()
        let before = s
        #expect(throws: PlanRevision.Failure.unknownRevision(open: 1, asked: revision)) { try PlanRevision.submit(revision, run: F.runId, in: &s) }
        #expect(s == before)
    }

    /// Spec §9: a new `submit_plan` reopens a complete run as active.
    @Test func aSubmissionReopensACompleteRun() throws {
        var s = F.state(F.run(state: .complete, autonomy: .handsOff, planRevision: 1, approvedRevision: nil),
                        [F.task("D", .planned, revision: 2)])
        try PlanRevision.submit(2, run: F.runId, in: &s)
        #expect(s.runs[0].state == .active && s.tasks[0].operated?.state == .queued)
    }

    @Test(arguments: [OperatorRunState.paused, .operatorOffline, .stopped])
    func aPausedOfflineOrStoppedRunTakesNoPlan(_ runState: OperatorRunState) {
        var (s, _, _) = planning()
        s.runs[0].state = runState
        #expect(throws: PlanRevision.Failure.runIs(runState)) { try PlanRevision.submit(1, run: F.runId, in: &s) }
    }

    /// Spec §13: a plan asking for more than the milestone supports is refused, not downgraded.
    @Test func aDraftMROrMergeIsRefusedBeforeM3() throws {
        var s = F.state(F.run(state: .planning, planRevision: 0, approvedRevision: nil), [F.task("A", .planned, end: .merge)])
        #expect(throws: PlanRevision.Failure.unsupportedEnd(key: "A", .merge)) { try PlanRevision.submit(1, run: F.runId, in: &s, milestone: .m1) }
        #expect(s.runs[0].planRevision == 0)
        try PlanRevision.submit(1, run: F.runId, in: &s, milestone: .m3)
        #expect(s.runs[0].planRevision == 1)
    }

    @Test func dependenciesThatCannotWorkAreRefused() {
        let a = F.task("A", .planned), b = F.task("B", .planned)
        let twoParents = F.task("C", .planned, dependsOn: [TaskDependency(task: a.id, kind: .code), TaskDependency(task: b.id, kind: .code)])
        #expect(throws: PlanRevision.Failure.tooManyCodeParents(key: "C")) {
            try PlanRevision.validate(F.state(F.run(), [a, b, twoParents]), run: F.runId)
        }
        let elsewhere = F.task("E", .planned, project: UUID())
        let crossing = F.task("X", .planned, dependsOn: [TaskDependency(task: elsewhere.id, kind: .code)])
        #expect(throws: PlanRevision.Failure.codeParentInAnotherProject(key: "X")) {
            try PlanRevision.validate(F.state(F.run(), [elsewhere, crossing]), run: F.runId)
        }
        let orderAcross = F.task("O", .planned, dependsOn: [TaskDependency(task: elsewhere.id, kind: .order)])
        #expect(throws: Never.self) { try PlanRevision.validate(F.state(F.run(), [elsewhere, orderAcross]), run: F.runId) }
        let orphan = F.task("Y", .planned, dependsOn: [TaskDependency(task: UUID(), kind: .order)])
        #expect(throws: PlanRevision.Failure.unknownDependency(key: "Y")) {
            try PlanRevision.validate(F.state(F.run(), [orphan]), run: F.runId)
        }
    }

    @Test func aCircleOfDependenciesIsRefused() {
        let aId = UUID(), bId = UUID(), cId = UUID()
        let a = F.task("A", .planned, id: aId, dependsOn: [TaskDependency(task: cId, kind: .order)])
        let b = F.task("B", .planned, id: bId, dependsOn: [TaskDependency(task: aId, kind: .order)])
        let c = F.task("C", .planned, id: cId, dependsOn: [TaskDependency(task: bId, kind: .order)])
        #expect(throws: PlanRevision.Failure.cycle(keys: ["A", "B", "C"])) {
            try PlanRevision.validate(F.state(F.run(), [a, b, c]), run: F.runId)
        }
    }

    @Test func aStartedTaskIsNotChangedByThePlan() {
        var s = F.state(F.run(), [F.task("W", .working)])
        #expect(throws: PlanRevision.Failure.started(key: "W")) { try PlanRevision.markChanged(task: s.tasks[0].id, in: &s) }
    }

    /// Ungated, a change is recorded in the open revision and the task stays queued.
    @Test func anUngatedChangeKeepsTheTaskQueued() throws {
        var s = F.state(F.run(autonomy: .handsOff, planRevision: 2), [F.task("Q", .queued)])
        try PlanRevision.markChanged(task: s.tasks[0].id, in: &s)
        #expect(s.tasks[0].operated?.state == .queued && s.tasks[0].operated?.revision == 3)
    }
}
