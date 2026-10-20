import Testing
import Foundation
@testable import AiTermCore

@Suite struct RunStatusTests {
    typealias F = OperatorFixtures

    /// A run with revision 2 submitted, five tasks in every situation the
    /// obligations name, and an open and a resolved question.
    private func scene() -> (AppState, [UUID: TaskLiveFacts], ids: [String: UUID]) {
        let a = F.task("A", .accepted), b = F.task("B", .working, dependsOn: [TaskDependency(task: a.id, kind: .code)])
        var c = F.task("C", .working), d = F.task("D", .working), e = F.task("E", .planned, revision: 2)
        c.operated?.flags = [.possiblyStalled, .uncertain]
        d.operated?.takenOver = true
        var s = F.state(F.run(planRevision: 2), [a, b, c, d, e])
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
        #expect(status.run.planRevision == 2 && status.run.openRevision == 3 && status.run.state == .active)
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
    }

    /// A worker that committed off its task branch is named with what AiTerm found, the branch and the SHA,
    /// and listed among the obligations, so the Operator looks before the runtime runs out.
    @Test func aTaskOffItsBranchSaysWhatWasFound() throws {
        var (s, live, _) = scene()
        let drift = BranchDrift(source: .lastMessage, branch: "feat/mine", sha: "c0ffee1",
                                found: "Its last message names c0ffee1, which isn't on its task branch feat/b: it is on feat/mine.")
        s.tasks[1].operated?.branchDrift = drift
        let status = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live))
        #expect(status.tasks[1].branchDrift == drift && status.tasks[0].branchDrift == nil)
        #expect(status.obligations.branchDrift == ["B"])
        let json = String(decoding: try status.json(), as: UTF8.self)
        #expect(json.contains(#""branchDrift":{"branch":"feat\/mine","found":"#) && json.contains(#""sha":"c0ffee1","source":"lastMessage"}"#))
    }

    /// What the Operator needs to judge the backlog and its own reach: the first plan's size, the finds,
    /// the slices and the Oracle as the run froze them, and each agent's weekly usage.
    @Test func theRunSaysItsFirstPlanSizeFindsSlicesOracleAndUsage() throws {
        var (s, live, _) = scene()
        s.runs[0].firstPlanSize = 4
        s.runs[0].finds = [OffBriefFind(key: "f1", title: "Dead footer link", why: "/privacy 404s")]
        s.runs[0].profile.slices = Slices(jira: true, review: false, merge: true)
        s.runs[0].profile.oracle.isOn = false

        let run = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live,
                                               runLive: RunLiveFacts(weeklyUsage: [.claude: 81, .codex: 12]))).run

        #expect(run.firstPlanSize == 4)
        #expect(run.finds.map(\.key) == ["f1"])
        #expect(run.slices == Slices(jira: true, review: false, merge: true))
        #expect(!run.oracleIsOn)
        #expect(run.usage == ["claude": 81, "codex": 12])
    }

    @Test func aRunWithNoPlanOrUsageSaysSo() throws {
        let (s, live, _) = scene()
        let run = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).run
        #expect(run.firstPlanSize == nil && run.finds.isEmpty && run.slices == .none && run.usage.isEmpty)
        #expect(run.oracleIsOn == s.runs[0].profile.oracle.isOn)
    }

    /// The broadcast's prompt, Review and Done, as the run froze them.
    @Test func theRunSaysItsPromptReviewAndDone() throws {
        var (s, live, _) = scene()
        s.runs[0].review = "Jan approves each MR"
        let run = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).run
        #expect(run.prompt == "Implement the sprint." && run.review == "Jan approves each MR" && run.done == "a commit per item, tests green")
    }

    @Test func theToolsJSONHasSortedKeysAndISODates() throws {
        let (s, live, _) = scene()
        let data = try #require(RunStatus.build(state: s, run: F.runId, revision: 1, live: live)).json()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["revision", "run", "tasks", "obligations"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""askedAt":"2023-11-14T22:13:20Z""#))
        #expect(text.hasPrefix(#"{"obligations":"#))
        #expect(!text.contains("approvedRevision") && !text.contains("planAwaitingApproval") && !text.contains("gated"))
    }

    @Test func anUnknownRunHasNoSnapshot() {
        #expect(RunStatus.build(state: .empty, run: UUID(), revision: 1, live: [:]) == nil)
    }
}
