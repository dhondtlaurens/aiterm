import Testing
import Foundation
@testable import AiTermCore

@Suite struct PlanRevisionTests {
    typealias F = OperatorFixtures

    /// A fresh run in planning, nothing submitted yet, two planned tasks in the open revision 1.
    private func planning() -> (AppState, a: UUID, b: UUID) {
        let a = F.task("A", .planned), b = F.task("B", .planned, dependsOn: [TaskDependency(task: a.id, kind: .order)])
        let run = F.run(state: .planning, planRevision: 0)
        return (F.state(run, [a, b]), a.id, b.id)
    }

    private func states(_ s: AppState) -> [OperatedState?] { s.tasks.map { $0.operated?.state } }

    @Test func submitReleasesEveryPlannedTask() throws {
        var (s, a, b) = planning()
        #expect(s.runs[0].openRevision == 1)

        let submitted = try PlanRevision.submit(1, run: F.runId, in: &s)

        #expect(submitted == PlanRevision.Submitted(revision: 1, released: [a, b]))
        #expect(s.runs[0].planRevision == 1 && s.runs[0].openRevision == 2)
        #expect(s.runs[0].state == .active)
        #expect(states(s) == [.queued, .queued])
    }

    @Test func theOpenRevisionSubmitsWithoutNamingIt() throws {
        var (s, a, b) = planning()
        #expect(try PlanRevision.submit(run: F.runId, in: &s).released == [a, b])
        #expect(s.runs[0].planRevision == 1)
        #expect(throws: PlanRevision.Failure.unknownRun(UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!)) {
            try PlanRevision.submit(run: UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!, in: &s)
        }
    }

    @Test func theFirstSubmitSetsFirstPlanSize() throws {
        var s = F.state(F.run(state: .planning, planRevision: 0),
                        (1...5).map { F.task("T\($0)", .planned) })
        #expect(s.runs[0].firstPlanSize == nil)
        try PlanRevision.submit(1, run: F.runId, in: &s)
        #expect(s.runs[0].firstPlanSize == 5)

        s.tasks.append(F.task("T6", .planned, revision: 2))
        s.tasks.append(F.task("T7", .planned, revision: 2))
        try PlanRevision.submit(2, run: F.runId, in: &s)
        #expect(s.runs[0].firstPlanSize == 5, "the backlog's growth is measured against the first plan")
    }

    /// A later revision releases what it adds, and what it changed and had not started; the rest runs on.
    @Test func aLaterRevisionReleasesOnlyWhatIsStillPlanned() throws {
        var (s, a, b) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)
        let c = F.task("C", .planned, revision: 2)
        s.tasks.append(c)
        try PlanRevision.markChanged(task: b, in: &s)
        #expect(s.task(id: b)?.operated?.state == .queued, "a changed queued task stays queued")
        #expect(s.task(id: b)?.operated?.revision == 2 && s.task(id: b)?.operated?.firstRevision == 1)

        #expect(try PlanRevision.submit(2, run: F.runId, in: &s).released == [c.id])
        #expect(s.task(id: a)?.operated?.state == .queued && s.task(id: c.id)?.operated?.state == .queued)
    }

    /// Tasks the operator adds to the open revision wait for its submission.
    @Test func theOpenRevisionWaitsForItsSubmission() throws {
        var (s, _, _) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)
        let open = F.task("D", .planned, revision: 2)
        s.tasks.append(open)
        #expect(s.task(id: open.id)?.operated?.state == .planned)
        try PlanRevision.submit(2, run: F.runId, in: &s)
        #expect(s.task(id: open.id)?.operated?.state == .queued)
    }

    /// Submitting the same revision again returns the earlier result and changes nothing.
    @Test func aRepeatedSubmissionIsTheEarlierResult() throws {
        var (s, _, _) = planning()
        try PlanRevision.submit(1, run: F.runId, in: &s)
        let before = s

        let again = try PlanRevision.submit(1, run: F.runId, in: &s)

        #expect(again == PlanRevision.Submitted(revision: 1, repeated: true))
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

    /// Spec §9: a new `submit_plan` reopens a complete run as active and releases its tasks.
    @Test func aSubmissionReopensACompleteRun() throws {
        var s = F.state(F.run(state: .complete, planRevision: 1),
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
        var s = F.state(F.run(state: .planning, planRevision: 0), [F.task("A", .planned, end: .merge)])
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
}
