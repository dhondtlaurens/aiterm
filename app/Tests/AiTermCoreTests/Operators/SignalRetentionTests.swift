import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct SignalRetentionTests {
    @Test func pruningBoundsCompletedHistoryWithoutCappingQuestionsOrUndeliveredAnswers() {
        let now = Date()
        var session = OperatorSession(createdAt: now)
        session.ledger = (0..<600).map { .init(key: "k\($0)", result: "ok", at: now) }
        session.ledger.insert(.init(key: "expired", result: "ok", at: now.addingTimeInterval(-8 * 86400)), at: 0)
        session.questions = (0..<1001).map { .init(id: "open\($0)", task: nil, text: "Question", openedAt: now) }
        var pending = OperatorSession.Question(id: "pending", task: UUID(), text: "Answer?", openedAt: now, resolvedAt: now)
        pending.workerQuestion = "Answer?"; pending.answer = "Yes"
        session.questions += [pending]
        session.prune()
        #expect(session.ledger.count == 500 && session.ledger.first?.key == "k100")
        #expect(session.questions.count == 1002 && session.waitingOnYou == 1001)
    }
    @Test func aQuestionIsPendingWhileOpenOrWhileAWorkersAnswerIsUndelivered() {
        let now = Date()
        let open = OperatorSession.Question(id: "open", task: UUID(), text: "Which locale?", openedAt: now)
        var undelivered = OperatorSession.Question(id: "worker", task: UUID(), text: "Which locale?", openedAt: now, resolvedAt: now)
        undelivered.workerQuestion = "Which locale?"; undelivered.answer = "en-GB"
        var delivered = undelivered; delivered.deliveredAt = now
        var answered = OperatorSession.Question(id: "operator", task: UUID(), text: "Merge it?", openedAt: now, resolvedAt: now)
        answered.answer = "Yes"
        #expect(open.isPending && undelivered.isPending)
        #expect(!delivered.isPending && !answered.isPending)
    }
    @Test func pruningTheOperatorDropsWhatASupersededStageOrARemovedSignalLeftAndKeepsTheCurrentStages() throws {
        var world = SignalWorld(); let signal = world.signal(), removed = world.signal(name: "Old tickets")
        let id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.stage = 2; $0.ownership = 1 }
        let now = world.now
        func answered(_ name: String, stage: Int) -> OperatorSession.Question {
            var question = OperatorSession.Question(id: name, task: id, text: "Which scope?", openedAt: now, resolvedAt: now)
            question.workerQuestion = question.text; question.answer = "The original one."; question.deliveredAt = now
            question.stage = stage; question.ownership = 1
            return question
        }
        func round(_ name: String, stage: Int) throws -> OracleRound {
            let evidence = try JSONValue.object(["task": .string(id.uuidString), "stage": .int(stage), "ownership": 1]).canonicalJSON()
            return OracleRound(id: name, tool: OperatorTool.answerWorker.rawValue, stage: .delivered, askedAt: now, askedEvidence: evidence, round: 1)
        }
        let questions = [answered("superseded", stage: 1), answered("current", stage: 2)]
        let rounds = [try round("superseded", stage: 1), try round("current", stage: 2)]
        world.state.operatorSession?.questions = questions
        world.state.operatorSession?.oracleRounds = rounds
        world.state.operatorSession?.sourceFailures = [signal.uuidString: "Jira timed out.", removed.uuidString: "Jira timed out."]
        world.state.signals.removeAll { $0.id == removed }

        world.state.pruneOperator(at: now)

        #expect(world.state.operatorSession?.questions.map(\.id) == ["current"])
        #expect(world.state.operatorSession?.oracleRounds.map(\.id) == ["current"])
        #expect(world.state.operatorSession?.sourceFailures == [signal.uuidString: "Jira timed out."])
    }
    @Test func withdrawingObsoleteQuestionsResolvesOnlyThoseOfAFinishedStageAndSaysWhetherAnyChanged() {
        var world = SignalWorld(); let signal = world.signal()
        let finished = world.workingTask(signal: signal), working = world.workingTask(signal: signal)
        world.state.updateSignalTask(finished) { $0.phase = .done }
        let now = world.now, at = now.addingTimeInterval(60)
        let questions: [OperatorSession.Question] = [
            .init(id: "finished", task: finished, text: "Merge it?", openedAt: now),
            .init(id: "working", task: working, text: "Which locale?", openedAt: now),
            .init(id: "global", task: nil, text: "Pause on Fridays?", openedAt: now),
        ]
        world.state.operatorSession?.questions = questions

        let changed = world.state.withdrawObsoleteQuestions(at: at)
        #expect(changed)
        let resolved = Dictionary(uniqueKeysWithValues: (world.state.operatorSession?.questions ?? []).map { ($0.id, $0.resolvedAt) })
        #expect(resolved == ["finished": at, "working": nil, "global": nil])
        let changedAgain = world.state.withdrawObsoleteQuestions(at: at)
        #expect(!changedAgain, "Nothing left to withdraw changes nothing.")
    }
}
