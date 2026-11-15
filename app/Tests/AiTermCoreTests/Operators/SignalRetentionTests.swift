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
    @Test func repeatedStagesRetainOnlyTheNewestTransitionTail() throws {
        var task = SignalTask(signal: UUID(), item: .unknown(.null), startedAt: Date()); task.phase = .working
        for _ in 0..<250 {
            task = try SignalTransitions.apply(.block("Wait"), to: task, at: Date())
            task = try SignalTransitions.apply(.resume, to: task, at: Date())
            task = try SignalTransitions.apply(.workerStarted, to: task, at: Date())
        }
        #expect(task.edges.count == 100)
        #expect(task.edges.last?.to == .working && task.ownership == 250)
    }
}
