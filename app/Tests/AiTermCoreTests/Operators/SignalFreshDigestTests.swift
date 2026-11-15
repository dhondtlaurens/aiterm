import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct SignalFreshDigestTests {
    @Test func aFreshChatCarriesAnsweredButUndeliveredQuestionsOpenRoundsAndWorkerIntents() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        var question = OperatorSession.Question(id: "scope", task: id, text: "Which scope?", openedAt: world.now, resolvedAt: world.now)
        question.answer = "Keep the original scope."; question.workerQuestion = question.text
        world.state.operatorSession?.questions = [question]
        let round = ChallengeRecord(id: "open", tool: "answer_worker", askedArguments: "{}", askedAt: world.now)
        world.state.operatorSession?.oracleRounds = [round]
        let pending = SignalWorkerReply(at: world.now, fingerprint: "old-assistant-record")
        world.state.updateSignalTask(id) { $0.pendingReplies = ["main": pending] }
        world.state.signalSeen = [.init(signal: signal, item: world.ticket("NOPE-1").item, disposition: .skipped, at: world.now, reason: "No linked project")]
        let digest = OperatorDigest(state: world.state, at: world.now, oracleOn: true)
        #expect(digest.questions.first?.answer == question.answer)
        #expect(digest.waitingOnYou == 0, "An answered question is pending delivery, not another request to the person.")
        let json = try JSONValue(encoding: digest)
        #expect(json["oracleRounds"]?.arrayValue?.count == 1)
        #expect(json["tasks"]?.arrayValue?.first?["pendingReplies"]?["main"] != nil)
        #expect(json["skipped"]?.arrayValue?.count == 1)
    }
}
