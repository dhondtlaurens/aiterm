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

    @Test func aBackgroundTaskWindowSaysSoAndAForegroundOneSaysNothing() async throws {
        try connect { _ in ["windowId": "w1"] }
        let frame = Frame(x: 0, y: 0, w: 1, h: 1)
        _ = try await client.createTaskWindow(taskId: "t", cwd: "/wt", title: "x", agentCommand: nil, frame: frame, background: true)
        _ = try await client.createTaskWindow(taskId: "t", cwd: "/wt", title: "x", agentCommand: nil, frame: frame)
        #expect(params(0)["background"] as? Bool == true)
        #expect(params(1)["background"] == nil)
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

    @Test func anOpenPromptReadsAsItsKindAndNoneAsNil() async throws {
        try connect { req in
            ["kind": (req["params"] as? [String: Any])?["sessionId"] as? String == "s1" ? "permission" as Any : NSNull()]
        }
        #expect(try await client.prompt(sessionId: "s1") == .permission)
        #expect(try await client.prompt(sessionId: "s2") == nil)
        #expect(method() == "session.prompt")
    }

    @Test func anUnknownPromptKindReadsAsAnOpenMenuAndANullKindStaysNone() async throws {
        try connect { req in
            switch (req["params"] as? [String: Any])?["sessionId"] as? String {
            case "s1": ["kind": "somethingNew"]
            default: ["kind": NSNull()]
            }
        }
        #expect(try await client.prompt(sessionId: "s1") == .menu)
        #expect(try await client.prompt(sessionId: "s2") == nil)
    }

    @Test func anUnknownDeliveryResultReadsAsRefused() async throws {
        try connect { _ in ["result": "somethingNew", "reason": NSNull()] }
        let delivery = try await client.deliver(sessionId: "s1", text: "hi", ownership: 1, wake: false, worktree: nil)
        #expect(delivery == Delivery(result: .refused, reason: nil))
    }

    @Test func theSessionAndOperatorRequestsNameWhatTheyAreAbout() async throws {
        try connect { _ in [String: Any]() }
        try await client.interrupt(sessionId: "s1")
        try await client.setOwnership(sessionId: "s1", ownership: 4)
        try await client.registerOperator(runId: "R", token: "tok")
        try await client.revokeOperator(runId: "R")
        #expect((0..<4).map { method($0) } == ["session.interrupt", "session.setOwnership", "operator.register", "operator.revoke"])
        #expect(params(1)["ownership"] as? Int == 4)
        #expect(params(2)["token"] as? String == "tok")
        #expect(params(3)["runId"] as? String == "R")
    }

    @Test func aStartupDialogIsDismissedOnlyWhenTheDaemonSaysItDeclinedOne() async throws {
        try connect { req in ["dismissed": (req["params"] as? [String: Any])?["sessionId"] as? String == "s1"] }
        #expect(try await client.dismissStartup(sessionId: "s1"))
        #expect(try await client.dismissStartup(sessionId: "s2") == false)
        #expect(method() == "session.dismissStartup")
        #expect(params(1)["sessionId"] as? String == "s2")
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
        let line = Data(#"{"event":"operator.request","payload":{"requestId":"op-00000000000000000000000000000001-1","runId":"R","tool":"create_task","arguments":{"key":"a","dependsOn":[{"task":"b","kind":"code"}],"n":2}}}"#.utf8)
        let event = try DaemonClient.decodeEvent("operator.request", from: line)
        #expect(event == .operatorRequest(OperatorRequest(requestId: "op-00000000000000000000000000000001-1", runId: "R", tool: "create_task",
                                                          arguments: ["key": "a", "dependsOn": [["task": "b", "kind": "code"]], "n": 2])))
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
