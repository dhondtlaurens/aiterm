import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// What the board reads that the workspace keeps for it (broadcast setup v2, Board): your answer to a task's fix rounds,
/// on its question, and why the closing kept a task's worktree, on the task. Each is saved only when set, so a run that
/// has neither saves back as it was.
@Suite struct BoardRecordsTests {
    private let web = OperatorUIFixtures.project("webshop")

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private var question: OperatorQuestion {
        OperatorQuestion(id: "fix-pay-233", text: "Out of fix rounds: one more, or accept it?", task: UUID(),
                         askedAt: OperatorUIFixtures.epoch, about: OperatorQuestion.fixRounds)
    }

    @Test func aFixRoundsAnswerIsKeptOnItsQuestionOnlyOnceGiven() throws {
        #expect(try json(question)["answeredOnCard"] == nil, "a question nobody answered on its card saves as before")
        var answered = question
        answered.answeredOnCard = BroadcastBoard.FixRoundsAnswer.oneMoreRound.words
        #expect(try json(answered)["answeredOnCard"] as? String == "one more round")
        let decoded = try JSONDecoder().decode(OperatorQuestion.self, from: JSONEncoder().encode(answered))
        #expect(decoded == answered)
        #expect(BroadcastBoard.FixRoundsAnswer(words: "accept it as it is") == .acceptAsItIs)
    }

    @Test func runStatusSaysTheAnswerGivenOnTheCard() throws {
        var run = OperatorUIFixtures.run(projectIds: [web.id], agents: OperatorUIFixtures.agents, taskSettings: OperatorUIFixtures.taskSettings)
        let task = OperatorUIFixtures.task("Address autocomplete", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "PAY-233", state: .working))
        var asked = question
        asked.task = task.id
        asked.answeredOnCard = "accept it as it is"
        run.questions = [asked]
        var state = AppState()
        state.append(project: web)
        state.runs = [run]
        state.tasks = [task]
        let status = try #require(RunStatus.build(state: state, run: run.id, revision: 1, live: [:]))
        #expect(status.obligations.questionsWaiting.first?.answeredOnCard == "accept it as it is")
        let encoded = try #require(String(data: JSONEncoder().encode(status), encoding: .utf8))
        #expect(encoded.contains("\"answeredOnCard\":\"accept it as it is\""))
    }

    @Test func whyAWorktreeWasKeptIsKeptOnTheTaskOnlyOnceSet() throws {
        var operated = OperatorUIFixtures.operated(run: UUID(), key: "PAY-235", state: .published, end: .draftMR)
        #expect(try json(operated)["keptReason"] == nil, "a task the closing never kept saves as before")
        operated.keptReason = "Not closed: its worktree has uncommitted changes. Remove it yourself once they are safe."
        #expect(try json(operated)["keptReason"] as? String == operated.keptReason)
        #expect(try JSONDecoder().decode(OperatedTask.self, from: JSONEncoder().encode(operated)) == operated)
    }

    @Test func theBoardReadsBoth() throws {
        var run = OperatorUIFixtures.run(state: .complete, projectIds: [web.id], agents: OperatorUIFixtures.agents,
                                         taskSettings: OperatorUIFixtures.taskSettings)
        run.completedAt = OperatorUIFixtures.epoch
        run.closedAt = OperatorUIFixtures.epoch
        var kept = OperatorUIFixtures.task("Shipping step", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "PAY-235", state: .published,
                                                                                 end: .draftMR, sha: "71f0e9c11"))
        func card(_ run: OperatorRun, _ tasks: [TaskItem]) throws -> BroadcastBoard.Card {
            var state = AppState()
            state.append(project: web)
            state.runs = [run]
            state.tasks = tasks
            return try #require(BroadcastBoard.make(run: run, state: state, acting: .none, requests: []).columns.flatMap(\.cards).first)
        }
        #expect(try card(run, [kept]).notice == nil, "no reason recorded: the line alone")
        kept.operated?.keptReason = "Not closed: its worktree has uncommitted changes. Remove it yourself once they are safe."
        let keptCard = try card(run, [kept])
        #expect(keptCard.line?.text == "draft MR · worktree kept" && keptCard.notice == kept.operated?.keptReason)

        var active = run
        active.state = .active
        active.completedAt = nil
        let working = OperatorUIFixtures.task("Address autocomplete", project: web.id,
                                              operated: OperatorUIFixtures.operated(run: run.id, key: "PAY-233", state: .working))
        var asked = question
        asked.task = working.id
        active.questions = [asked]
        #expect(try card(active, [working]).fixRounds?.answered == nil)
        active.questions[0].answeredOnCard = "one more round"
        #expect(try card(active, [working]).fixRounds?.answered == .oneMoreRound)
    }
}
