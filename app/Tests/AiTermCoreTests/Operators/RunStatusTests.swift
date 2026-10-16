import Testing
import Foundation
@testable import AiTermCore

@Suite struct RunStatusTests {
    typealias F = OperatorFixtures

    /// A gated run with revision 2 submitted and revision 1 approved, five tasks in every situation the
    /// obligations name, and an open and a resolved question.
    private func scene() -> (AppState, [UUID: TaskLiveFacts], ids: [String: UUID]) {
        let a = F.task("A", .accepted), b = F.task("B", .working, dependsOn: [TaskDependency(task: a.id, kind: .code)])
        var c = F.task("C", .working), d = F.task("D", .working), e = F.task("E", .planned, revision: 2)
        c.operated?.flags = [.possiblyStalled, .uncertain]
        d.operated?.takenOver = true
        var s = F.state(F.run(autonomy: .routine, planRevision: 2, approvedRevision: 1), [a, b, c, d, e])
        s.tasks[0].operated?.acceptance = F.acceptance("4f2a91c0ffee")
        s.runs[0].questions = [
            OperatorQuestion(id: "q-open", text: "Which API version?", task: c.id, askedAt: F.epoch),
            OperatorQuestion(id: "q-done", text: "Old?", task: nil, askedAt: F.epoch, resolution: "v2"),
        ]
        let live: [UUID: TaskLiveFacts] = [
            b.id: TaskLiveFacts(status: .done, lastCommit: "b0b0b0b", summary: "Added the endpoint"),
            c.id: TaskLiveFacts(status: .needsInput, waitingPrompt: "permission"),
            d.id: TaskLiveFacts(status: .idle),
        ]
        return (s, live, ["A": a.id, "B": b.id, "C": c.id, "D": d.id, "E": e.id])
    }

    @Test func theSnapshotSaysTheRunAndEveryTask() throws {
        let (s, live, ids) = scene()
        let status = try #require(RunStatus.build(state: s, run: F.runId, revision: 7, live: live))
        #expect(status.revision == 7)
        #expect(status.run.planRevision == 2 && status.run.openRevision == 3 && status.run.approvedRevision == 1)
        #expect(status.run.gated && status.run.state == .active)
        #expect(status.tasks.map(\.key) == ["A", "B", "C", "D", "E"])
        let b = status.tasks[1]
        #expect(b.id == ids["B"] && b.project == "Shop" && b.live == .done && b.lastCommit == "b0b0b0b")
        #expect(b.summary == "Added the endpoint" && b.branch == "feat/b")
        #expect(b.dependsOn == [RunStatus.Dependency(key: "A", kind: .code)])
        #expect(status.tasks[0].acceptedSHA == "4f2a91c0ffee")
        #expect(status.tasks[2].flags == [.possiblyStalled, .uncertain])
        #expect(status.tasks[4].live == nil)
    }

    @Test func theObligationsSayWhatWaits() throws {
        let (s, live, _) = scene()
        let o = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).obligations
        #expect(o.questionsWaiting == [RunStatus.Question(key: "q-open", text: "Which API version?", task: "C", askedAt: F.epoch)])
        #expect(o.promptsWaitingOnYou == ["C"])
        #expect(o.readyForAcceptance == ["B"], "D ended its turn too, but you took it over")
        #expect(o.possiblyStalled == ["C"] && o.uncertain == ["C"])
        #expect(o.planAwaitingApproval == 2)
    }

    @Test func noPlanWaitsOnceTheLatestIsApprovedOrTheRunIsUngated() throws {
        var (s, live, _) = scene()
        s.runs[0].approvedRevision = 2
        #expect(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)?.obligations.planAwaitingApproval == nil)
        s.runs[0].approvedRevision = 1
        s.runs[0].persona.autonomy = .trusted
        #expect(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)?.obligations.planAwaitingApproval == nil)
    }

    @Test func theToolsJSONHasSortedKeysAndISODates() throws {
        let (s, live, _) = scene()
        let data = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).json()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["revision", "run", "tasks", "obligations"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""askedAt":"2023-11-14T22:13:20Z""#))
        #expect(text.hasPrefix(#"{"obligations":"#))
    }

    @Test func anUnknownRunHasNoSnapshot() {
        #expect(RunStatus.build(state: .empty, run: UUID(), revision: 1, live: [:]) == nil)
    }
}
