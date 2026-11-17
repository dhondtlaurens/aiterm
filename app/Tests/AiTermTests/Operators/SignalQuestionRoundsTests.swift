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
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: false)
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in current }, deliver: { _, _, _ in deliveries += 1 }))
        try rounds.askYou(key: "scope", task: task, text: current.text)
        try rounds.resolveQuestion(key: "scope", answer: "Use the payment ID.")
        if newSession { current.session = "replacement-session" } else { current.message += " A different tail beyond the caption." }
        await #expect(throws: (any Error).self) {
            try await rounds.answer(task: task, proposal: "Use the payment ID.", fromQuestion: "scope")
        }
        #expect(deliveries == 0)
    }

    @Test func disagreementStopsAfterThreeRoundsAndOnlyARecordedChatQuestionCounts() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var deliveries = 0
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in .critique("NO. IMPORTANT: that key changes.") }
        var calls: Int { oracle.prompts.count }
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in question }, deliver: { _, _, _ in deliveries += 1 }))
        var challenge: String?
        for number in 1...3 {
            let result = try await rounds.answer(task: task, proposal: "Proposal \(number)", challenge: challenge)
            if number < 3 {
                #expect(result["status"] == "challenged")
                challenge = result["challengeId"]?.stringValue
            } else { #expect(result["status"] == "ask_you") }
        }
        let repeated = try await rounds.answer(task: task, proposal: "Try a different key.")
        #expect(repeated["status"] == "ask_you")
        #expect(calls == 3 && deliveries == 0)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 0)
        try rounds.askYou(key: "person", task: task, text: question.text)
        try rounds.askYou(key: "person", task: task, text: question.text)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 1)
        try rounds.resolveQuestion(key: "person", answer: "Use the payment ID.")
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 0)
        let answer = try await rounds.answer(task: task, proposal: "Use the payment ID.", fromQuestion: "person")
        #expect(answer["status"] == "answered" && calls == 3 && deliveries == 1)
        #expect(h.workspace.state.operatorSession?.questions.first?.deliveredAt != nil)
        #expect(OperatorDigest(state: h.workspace.state, at: world.now, oracleOn: true).questions.isEmpty)
    }

    @Test(arguments: [false, true]) func theOracleBeingOffOrCallingItThePersonsDecisionAsksInChat(oracleOn: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var delivered = false
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: oracleOn) { _ in .critique("PERSON This is a product decision.") }
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in question }, deliver: { _, _, _ in delivered = true }))
        let result = try await rounds.answer(task: task, proposal: "Choose A.")
        #expect(result["status"] == "ask_you" && !delivered && oracle.prompts.count == (oracleOn ? 1 : 0))
        #expect(result["reason"]?.stringValue == (oracleOn ? "PERSON This is a product decision." : "The Oracle is off."))
    }

    @Test func parallelKeysCannotAnswerTheSameWorkerQuestionTwice() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let entered = TestLatch(), release = TestLatch()
        var calls = 0, deliveries = 0
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in
            calls += 1
            if calls == 1 { entered.signal(); await release.wait() }
            return .critique("YES. Fine.")
        }
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in question }, deliver: { _, _, _ in deliveries += 1 }))
        let first = Task { try await rounds.answer(task: task, proposal: "Use A.") }
        await entered.wait()
        let second = try await rounds.answer(task: task, proposal: "Use B.")
        #expect(second["status"] == "pending")
        release.signal(); _ = try await first.value
        #expect(calls == 1 && deliveries == 1)
    }

    @Test func replacingTheOperatorSessionDuringAnOracleReadCannotDeliverAnOldAnswer() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var delivered = false
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in
            h.workspace.mutate { $0.operatorSession?.generation += 1 }
            return .critique("YES. Fine.")
        }
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in question }, deliver: { _, _, _ in delivered = true }))
        await #expect(throws: ActionUnavailable.self) { try await rounds.answer(task: task, proposal: "Answer.") }
        #expect(!delivered)
    }

    @Test func aTakeoverDuringTheOracleReadPreventsBothDeliveryAndAQuestion() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var delivered = false
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in
            h.workspace.mutate { $0.takeOver(task) }
            return .critique("YES. Fine.")
        }
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in question }, deliver: { _, _, _ in delivered = true }))
        await #expect(throws: ActionUnavailable.self) { try await rounds.answer(task: task, proposal: "Answer.") }
        #expect(!delivered && h.workspace.state.operatorSession?.waitingOnYou == 0)
    }

    /// A check whose Oracle settings changed while it ran is discarded: the Operator proposes again, and nothing
    /// goes to the worker or the person.
    @Test func aWorkerAnswerWhoseSettingsChangedReturnsRetryAndDeliversNothing() async throws {
        var world = SignalWorld(); let signal = world.signal(), task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var delivered = false
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now })
        oracle.answer = { [unowned oracle] _ in oracle.settings.instructions = "Ask before any merge."; return .critique("YES. Fine.") }
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult, ports: .init(
            question: { _, _ in question }, deliver: { _, _, _ in delivered = true }))
        let result = try await rounds.answer(task: task, proposal: "Answer.")
        #expect(result["status"] == "retry")
        #expect(result["next"] == "The Oracle's settings or the standing instructions changed during its check. Call run_status and propose again without challengeId, with a new key.")
        #expect(!delivered && h.workspace.state.operatorSession?.oracleRounds.isEmpty == true)
        oracle.answer = { _ in .critique("YES. Fine.") }
        #expect(try await rounds.answer(task: task, proposal: "Answer.")["status"] == "answered" && delivered)
    }
}
