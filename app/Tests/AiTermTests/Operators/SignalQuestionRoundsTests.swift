import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalQuestionRoundsTests {
    private let question = QuestionRounds.Question(session: "s1", tab: "main", text: "Which retry key?", message: "Question: Which retry key?")

    @Test(arguments: [false, true]) func aRecordedAnswerCannotCrossToANewQuestionWithTheSameCaption(newSession: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var current = question, deliveries = 0
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            oracleEnabled: { false }, question: { _, _ in current }, oracle: { _ in .agreed("Yes") },
            deliver: { _, _, _ in deliveries += 1 }))
        try rounds.askYou(key: "scope", task: task, text: current.text)
        try rounds.resolveQuestion(key: "scope", answer: "Use the payment ID.")
        if newSession { current.session = "replacement-session" } else { current.message += " A different tail beyond the caption." }
        await #expect(throws: (any Error).self) {
            try await rounds.answer(task: task, key: "answer", proposal: "Use the payment ID.", fromQuestion: "scope")
        }
        #expect(deliveries == 0)
    }

    @Test func agreementAnswersOnceAndTheSavedKeySurvivesARestart() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var oracleCalls = 0, deliveries: [String] = []
        let ports = QuestionRounds.Ports(oracleEnabled: { true }, question: { _, _ in question }, oracle: { input in
            oracleCalls += 1
            #expect(input.question.text == question.text && input.proposal == "Use the payment ID.")
            return .agreed("That key is stable across retries.")
        }, deliver: { _, _, answer in deliveries.append(answer) })
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: ports)
        let first = try await rounds.answer(task: task, key: "a1", proposal: "Use the payment ID.")
        #expect(first["status"] == "answered")
        try h.workspace.load()
        let restarted = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: ports)
        let replay = try await restarted.answer(task: task, key: "a1", proposal: "Use the payment ID.")
        #expect(replay == first)
        #expect(oracleCalls == 1 && deliveries == ["Use the payment ID."])
        #expect(h.workspace.state.operatorSession?.oracleRounds.isEmpty == true)
        #expect(try h.file.load().operatorSession?.ledger.count == 1)
    }

    @Test func disagreementStopsAfterThreeRoundsAndOnlyARecordedChatQuestionCounts() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var calls = 0, deliveries = 0
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            oracleEnabled: { true }, question: { _, _ in question }, oracle: { _ in calls += 1; return .critique("IMPORTANT: that key changes.") },
            deliver: { _, _, _ in deliveries += 1 }))
        var challenge: String?
        for number in 1...3 {
            let result = try await rounds.answer(task: task, key: "a\(number)", proposal: "Proposal \(number)", challenge: challenge)
            if number < 3 {
                #expect(result["status"] == "challenged")
                challenge = result["challengeId"]?.stringValue
            } else { #expect(result["status"] == "ask_you") }
        }
        let repeated = try await rounds.answer(task: task, key: "a4", proposal: "Try a different key.")
        #expect(repeated["status"] == "ask_you")
        #expect(calls == 3 && deliveries == 0)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 0)
        try rounds.askYou(key: "person", task: task, text: question.text)
        try rounds.askYou(key: "person", task: task, text: question.text)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 1)
        try rounds.resolveQuestion(key: "person", answer: "Use the payment ID.")
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 0)
        let answer = try await rounds.answer(task: task, key: "person-answer", proposal: "Use the payment ID.", fromQuestion: "person")
        #expect(answer["status"] == "answered" && calls == 3 && deliveries == 1)
        #expect(h.workspace.state.operatorSession?.questions.first?.deliveredAt != nil)
        #expect(OperatorDigest(state: h.workspace.state, at: world.now, oracleOn: true).questions.isEmpty)
    }

    @Test(arguments: [false, true]) func theOracleBeingOffOrCallingItThePersonsDecisionAsksInChat(oracleOn: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var calls = 0, delivered = false
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            oracleEnabled: { oracleOn }, question: { _, _ in question }, oracle: { _ in calls += 1; return .person("This is a product decision.") },
            deliver: { _, _, _ in delivered = true }))
        let result = try await rounds.answer(task: task, key: "q", proposal: "Choose A.")
        #expect(result["status"] == "ask_you" && !delivered && calls == (oracleOn ? 1 : 0))
    }

    @Test func parallelKeysCannotAnswerTheSameWorkerQuestionTwice() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let entered = TestLatch(), release = TestLatch()
        var calls = 0, deliveries = 0
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            oracleEnabled: { true }, question: { _, _ in question }, oracle: { _ in
                calls += 1
                if calls == 1 { entered.signal(); await release.wait() }
                return .agreed("Fine.")
            }, deliver: { _, _, _ in deliveries += 1 }))
        let first = Task { try await rounds.answer(task: task, key: "first", proposal: "Use A.") }
        await entered.wait()
        let second = try await rounds.answer(task: task, key: "second", proposal: "Use B.")
        #expect(second["status"] == "pending")
        release.signal(); _ = try await first.value
        #expect(calls == 1 && deliveries == 1)
    }

    @Test func replacingTheOperatorSessionDuringAnOracleReadCannotDeliverAnOldAnswer() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var delivered = false
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            oracleEnabled: { true }, question: { _, _ in question }, oracle: { _ in
                h.workspace.mutate { $0.operatorSession?.generation += 1 }
                return .agreed("Fine.")
            }, deliver: { _, _, _ in delivered = true }))
        await #expect(throws: ActionUnavailable.self) { try await rounds.answer(task: task, key: "old-session", proposal: "Answer.") }
        #expect(!delivered)
    }

    @Test func aTakeoverDuringTheOracleReadPreventsBothDeliveryAndAQuestion() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var delivered = false
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            oracleEnabled: { true }, question: { _, _ in question }, oracle: { _ in
                h.workspace.mutate { $0.updateSignalTask(task) { $0 = try! SignalTransitions.apply(.takeOver, to: $0, at: world.now) } }
                return .agreed("Fine.")
            }, deliver: { _, _, _ in delivered = true }))
        await #expect(throws: ActionUnavailable.self) { try await rounds.answer(task: task, key: "q", proposal: "Answer.") }
        #expect(!delivered && h.workspace.state.operatorSession?.waitingOnYou == 0)
    }
}
