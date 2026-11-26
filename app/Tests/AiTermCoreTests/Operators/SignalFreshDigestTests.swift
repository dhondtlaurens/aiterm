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
        let round = OracleRound(id: "open", tool: "answer_worker", stage: .delivered, critique: "Check the original scope.",
                                askedAt: world.now, round: 1)
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
    /// The Operator is told only of its own signals: a project signal, its skipped items and its next run are the
    /// person's.
    @Test func theDigestHasNoProjectSignalSkipOrNextRun() throws {
        var world = SignalWorld(); let signal = world.signal(), scheduled = world.scheduled()
        let project = world.projectSignal()
        let projectRun = Signal.project(name: "Weekly audit", start: SignalTrigger(source: .schedule, query: "0 9 * * 1", project: world.project.id))
        world.state.signals.append(projectRun)
        world.state.signalSeen = [
            .init(signal: signal, item: world.ticket("NOPE-1").item, disposition: .skipped, at: world.now, reason: "No linked project"),
            .init(signal: project, item: world.ticket("NOPE-2").item, disposition: .skipped, at: world.now, reason: "No linked project"),
        ]
        let digest = OperatorDigest(state: world.state, at: world.now, oracleOn: false)
        #expect(digest.signals.map(\.id) == [signal, scheduled])
        #expect(digest.skipped.map(\.signal) == [signal])
        #expect(digest.nextRuns.map { Set($0.keys) } == [scheduled.uuidString])
    }
    @Test func anUnansweredOracleRoundSavesUnderItsOwnName() throws {
        let round = OracleRound(id: "no-answer", tool: "answer_worker", stage: .unanswered,
                                unansweredReason: "The Oracle is off.", askedAt: Date(timeIntervalSince1970: 0))
        let json = try JSONValue(encoding: round)
        #expect(json["stage"] == "unanswered")
        #expect(json["unansweredReason"] == "The Oracle is off.")
        #expect(try json.decode(OracleRound.self) == round)
    }
}
