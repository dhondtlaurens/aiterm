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
    private func request(_ h: SignalHarness, command: String) -> OperatorRequest {
        OperatorRequest(requestId: UUID().uuidString, operatorId: h.workspace.state.operatorSession!.id.uuidString,
                        tool: "gate_command", arguments: ["command": .string(command), "directory": .string(h.folder.path)], generation: 1)
    }
}
