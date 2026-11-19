import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalShellGateTests {
    @Test func hardLimitsHoldWithOracleOffAndStaleAuthorityAlwaysReturnsADenial() async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var current = true
        let gate = SignalShellGate(workspace: h.workspace, folder: h.folder, now: { world.now }, validate: { _ in
            if !current { throw ActionUnavailable("The session changed.") }
        }, consult: { _ in .unavailable(.off) })
        let request = request(h, command: "git push origin HEAD")
        #expect(await gate.respond(request)["decision"] == "deny")
        #expect(await gate.respond(self.request(h, command: "cat README.md"))["decision"] == "allow")
        let unchecked = await gate.respond(self.request(h, command: "./inspect"))
        #expect(unchecked["decision"] == "allow")
        #expect(unchecked["reason"] == "unchecked: the Oracle is off")
        current = false
        #expect(await gate.respond(self.request(h, command: "cat README.md"))["decision"] == "deny")
    }
    @Test func personAllowsOnlyTheExactCommandOnceAndHardLimitsCannotBeUnlocked() async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let gate = SignalShellGate(workspace: h.workspace, folder: h.folder, now: { world.now }, validate: { _ in },
                                   consult: { _ in .person("The person decides.") })
        let request = request(h, command: "./deploy")
        #expect(await gate.respond(request)["decision"] == "deny")
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 1)
        h.workspace.mutate { $0.operatorSession?.questions[0].resolvedAt = world.now; $0.operatorSession?.questions[0].answer = "YES" }
        #expect(await gate.respond(self.request(h, command: "./deploy --different"))["decision"] == "deny")
        #expect(await gate.respond(request)["decision"] == "allow")
        #expect(await gate.respond(request)["decision"] == "deny")
        #expect(await gate.respond(self.request(h, command: "git push origin HEAD"))["decision"] == "deny")
    }
    /// The Operator drops a gated command: its question closes without consent, nothing waits on the
    /// person, and the same command later asks again instead of running on the withdrawal.
    @Test func aWithdrawnGateQuestionIsNeverConsentAndTheSameCommandAsksAgain() async throws {
        var world = SignalWorld(); world.state.operatorSession = OperatorSession(createdAt: world.now)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var consulted = 0
        let gate = SignalShellGate(workspace: h.workspace, folder: h.folder, now: { world.now }, validate: { _ in },
                                   consult: { _ in consulted += 1; return .person("The person decides.") })
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: false)
        let rounds = QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: oracle.consult,
                                    ports: .init(question: { _, _ in nil }, deliver: { _, _, _ in }))
        let request = request(h, command: "./deploy")
        #expect(await gate.respond(request)["decision"] == "deny")
        let key = try #require(h.workspace.state.operatorSession?.questions.first?.id)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 1 && h.workspace.state.currentOperatorQuestions.count == 1)

        try rounds.withdrawQuestion(key: key, reason: "Read the log file instead.")
        try rounds.withdrawQuestion(key: key, reason: "Read the log file instead.")
        let closed = try #require(h.workspace.state.operatorSession?.questions.first)
        #expect(closed.withdrawn == "Read the log file instead." && closed.answer == nil && closed.resolvedAt == world.now)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 0 && h.workspace.state.currentOperatorQuestions.isEmpty)
        #expect(SignalQuestionNotification.make(state: h.workspace.state) == nil)
        let status = OperatorDigest(state: h.workspace.state, at: world.now, oracleOn: true)
        #expect(status.waitingOnYou == 0 && status.questions.isEmpty)
        #expect(throws: (any Error).self) { try rounds.resolveQuestion(key: key, answer: "allow") }
        #expect(throws: (any Error).self) { try rounds.withdrawQuestion(key: key, reason: "Another reason.") }

        let again = await gate.respond(request)
        #expect(again["decision"] == "deny" && consulted == 2)
        let questions = try #require(h.workspace.state.operatorSession?.questions)
        #expect(questions.count == 2 && questions[0].gateConsumedAt == nil)
        #expect(questions[1].id != key && questions[1].gate == questions[0].gate && questions[1].resolvedAt == nil)
        #expect(h.workspace.state.operatorSession?.waitingOnYou == 1)
        try rounds.resolveQuestion(key: questions[1].id, answer: "allow")
        #expect(await gate.respond(request)["decision"] == "allow")
    }
    private func request(_ h: SignalHarness, command: String) -> OperatorRequest {
        OperatorRequest(requestId: UUID().uuidString, operatorId: h.workspace.state.operatorSession!.id.uuidString,
                        tool: "gate_command", arguments: ["command": .string(command), "directory": .string(h.folder.path)], generation: 1)
    }
}
