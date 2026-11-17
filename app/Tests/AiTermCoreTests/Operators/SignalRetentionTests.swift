import Foundation
import Testing
@testable import AiTermCore

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
}
