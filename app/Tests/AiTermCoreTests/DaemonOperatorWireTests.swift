import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// The requests and the event operators add to the wire, as `DaemonClient` sends and reads them.
final class DaemonOperatorWireTests {
    let server: FakeSocketServer
    let client: DaemonClient

    init() {
        let path = "/tmp/aiterm-test-\(UUID().uuidString.prefix(8)).sock"
        server = FakeSocketServer(path: path)
        server.start()
        client = DaemonClient(socketPath: path)
    }
    deinit { client.disconnect(); server.stop() }

    private func connect(answering result: @escaping @Sendable ([String: Any]) -> Any) throws {
        server.handler = { req in ["id": req["id"]!, "result": result(req)] }
        try client.connect()
        #expect(server.waitForClient(timeout: 2))
    }
    private func params(_ index: Int = 0) -> [String: Any] { server.received[index]["params"] as? [String: Any] ?? [:] }
    private func method(_ index: Int = 0) -> String? { server.received[index]["method"] as? String }

    @Test func taskWindowsAlwaysSendTheirBackgroundFlag() async throws {
        try connect { _ in ["windowId": "w1"] }
        let frame = Frame(x: 0, y: 0, w: 1, h: 1)
        _ = try await client.createTaskWindow(taskId: "t", cwd: "/wt", title: "x", agentCommand: nil, frame: frame, background: true)
        _ = try await client.createTaskWindow(taskId: "t", cwd: "/wt", title: "x", agentCommand: nil, frame: frame)
        #expect(params(0)["background"] as? Bool == true)
        #expect(params(1)["background"] as? Bool == false)
    }

    @Test func aDeliveryCarriesItsOwnershipAndReadsItsResult() async throws {
        try connect { _ in ["result": "partial", "reason": "a prompt opened"] }
        let delivery = try await client.deliver(sessionId: "s1", text: "hi", ownership: 3, wake: true, worktree: "/wt")
        #expect(delivery == Delivery(result: .partial, reason: "a prompt opened"))
        #expect(method() == "session.deliver")
        #expect(params()["sessionId"] as? String == "s1")
        #expect(params()["text"] as? String == "hi")
        #expect(params()["ownership"] as? Int == 3)
        #expect(params()["wake"] as? Bool == true)
        #expect(params()["worktree"] as? String == "/wt")
    }

    /// What the delivery check vouches for, per agent: a policy a newer daemon names reads as off, and a
    /// harness this app doesn't know is left out.
    @Test func theDeliveryPolicyReadsAsEachAgentsVerdict() async throws {
        try connect { _ in ["agents": ["claude": ["policy": "auto", "version": "2.1.301"], "codex": ["policy": "pasteOnly", "version": "0.160.0"],
                                       "pi": ["policy": "somethingNew", "version": "1.0.0"],
                                       "gemini": ["policy": "auto", "version": "9.9.9"]]] }
        let verdicts = try await client.deliveryPolicy()
        #expect(method() == "delivery.policy")
        #expect(verdicts == [.claude: DeliveryVerdict(policy: .auto, version: "2.1.301"), .codex: DeliveryVerdict(policy: .pasteOnly, version: "0.160.0"),
                             .pi: DeliveryVerdict(policy: .off, version: "1.0.0")])
    }

    @Test func anUnknownDeliveryResultReadsAsRefused() async throws {
        try connect { _ in ["result": "somethingNew", "reason": NSNull()] }
        let delivery = try await client.deliver(sessionId: "s1", text: "hi", ownership: 1, wake: false, worktree: nil)
        #expect(delivery == Delivery(result: .refused, reason: nil))
    }

    @Test(arguments: [("typing", DeliveryCode.typing), ("prompt", .prompt), ("somethingNew", .unknown)])
    func aRefusalReadsItsCodeAndOneThisAppDoesNotKnowAsUnknown(_ raw: String, _ code: DeliveryCode) async throws {
        try connect { _ in ["result": "refused", "reason": "why", "code": raw] }
        let delivery = try await client.deliver(sessionId: "s1", text: "hi", ownership: 1, wake: true, worktree: nil)
        #expect(delivery == Delivery(result: .refused, reason: "why", code: code))
    }

    @Test func aDaemonThatNamesNoCodeReadsAsNone() async throws {
        try connect { _ in ["result": "refused", "reason": "why"] }
        let delivery = try await client.deliver(sessionId: "s1", text: "hi", ownership: 1, wake: true, worktree: nil)
        #expect(delivery.code == nil)
    }

    @Test func theSessionAndOperatorRequestsNameWhatTheyAreAbout() async throws {
        try connect { _ in [String: Any]() }
        try await client.setOwnership(sessionId: "s1", ownership: 4)
        try await client.registerOperator(operatorId: "R", token: "tok", generation: 1)
        try await client.revokeOperator(operatorId: "R", generation: 1)
        #expect((0..<3).map { method($0) } == ["session.setOwnership", "operator.register", "operator.revoke"])
        #expect(params(0)["ownership"] as? Int == 4)
        #expect(params(1)["token"] as? String == "tok")
        #expect(params(2)["operatorId"] as? String == "R")
    }

    @Test func aSingleOperatorsRequestRetainsTheTokensGeneration() throws {
        let line = Data(#"{"event":"operator.request","payload":{"requestId":"op-1","operatorId":"R","generation":3,"tool":"run_status","arguments":{}}}"#.utf8)
        let event = try DaemonClient.decodeEvent("operator.request", from: line)
        #expect(event == .operatorRequest(OperatorRequest(requestId: "op-1", operatorId: "R", tool: "run_status", arguments: [:], generation: 3)))
    }

    @Test func singleOperatorAuthorityCarriesItsGenerationOnRegisterAndRevoke() async throws {
        try connect { _ in [String: Any]() }
        try await client.registerOperator(operatorId: "R", token: "tok", generation: 2)
        try await client.revokeOperator(operatorId: "R", generation: 2)
        #expect(params(0)["generation"] as? Int == 2)
        #expect(params(1)["generation"] as? Int == 2)
    }

    @Test func aReplyToTheOperatorSendsItsResultAndAnExplicitNullError() async throws {
        try connect { _ in [String: Any]() }
        try await client.replyToOperator(requestId: "op-00000000000000000000000000000001-1", result: ["task": "T1", "created": true], error: nil)
        try await client.replyToOperator(requestId: "r2", result: nil, error: "AiTerm says no")
        #expect(method() == "operator.reply")
        #expect(params(0)["requestId"] as? String == "op-00000000000000000000000000000001-1")
        #expect((params(0)["result"] as? [String: Any])?["created"] as? Bool == true)
        #expect(params(0)["error"] is NSNull)
        #expect(params(1)["result"] is NSNull)
        #expect(params(1)["error"] as? String == "AiTerm says no")
    }

    @Test func anOperatorRequestArrivesWithItsArguments() throws {
        let line = Data(#"{"event":"operator.request","payload":{"requestId":"op-1","operatorId":"R","generation":2,"tool":"read_task","arguments":{"task":"task-id","stage":1,"ownership":0}}}"#.utf8)
        let event = try DaemonClient.decodeEvent("operator.request", from: line)
        #expect(event == .operatorRequest(OperatorRequest(requestId: "op-1", operatorId: "R", tool: "read_task",
            arguments: ["task": "task-id", "stage": 1, "ownership": 0], generation: 2)))
    }
    @Test func aRequestWithoutSingleOperatorAuthorityIsRefused() {
        let line = Data(#"{"event":"operator.request","payload":{"requestId":"op-1","operatorId":"R","tool":"run_status","arguments":{}}}"#.utf8)
        #expect(throws: (any Error).self) { try DaemonClient.decodeEvent("operator.request", from: line) }
    }

    @Test func aJSONValueKeepsIntegersAndRoundTripsAnEncodable() throws {
        struct Point: Codable, Equatable { var x: Int; var label: String? }
        let value = try JSONValue(encoding: Point(x: 3, label: nil))
        #expect(value["x"] == .int(3))
        #expect(value["x"]?.intValue == 3)
        #expect(try value.decode(Point.self) == Point(x: 3, label: nil))
        let read = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"n":12,"f":1.5,"s":"x","b":true,"z":null}"#.utf8))
        #expect(read == ["n": 12, "f": .double(1.5), "s": "x", "b": true, "z": nil])
    }
}
