import Foundation
@testable import AiTermCore

/// What one live eval run of the Operator did: every tool call, in order, as the stub MCP server logged it
/// (`daemon/tools/operator_stub.py`), and its final reply.
struct EvalTranscript: Sendable {
    var calls: [(tool: String, arguments: JSONValue)]
    var reply: String

    /// The arguments of each call to `tool`, in order.
    func arguments(of tool: String) -> [JSONValue] { calls.filter { $0.tool == tool }.map(\.arguments) }

    func called(_ tool: String) -> Bool { calls.contains { $0.tool == tool } }

    /// The calls to any of `tools` whose `task` names the task `key`.
    func calls(_ tools: Set<String>, on key: String) -> [(tool: String, arguments: JSONValue)] {
        calls.filter { tools.contains($0.tool) && OperatorEvalGrading.names($0.arguments["task"], key) }
    }
}

/// One situation the Operator wakes into: what AiTerm types into its tab, what each tool answers (as the stub's
/// `replies.json` takes them), and what it must and must not do there. `check` returns what went wrong, empty for a pass.
struct EvalScenario: Sendable {
    var name: String
    var firstMessage: String
    var replies: JSONValue
    var check: @Sendable (EvalTranscript) -> [String]
}

enum OperatorEvalGrading {
    static let pay12 = UUID(uuidString: "E7A1C0DE-0000-4000-8000-0000000000C2")!
    static let keys = ["PAY-12": pay12, "PAY-14": pay14]
    static let pay14 = UUID(uuidString: "E7A1C0DE-0000-4000-8000-0000000000C4")!
    static let wakeLine = "[AiTerm] updates waiting, call run_status"
    static func names(_ task: JSONValue?, _ key: String) -> Bool {
        guard let text = task?.stringValue?.trimmingCharacters(in: .whitespaces) else { return false }
        return text.caseInsensitiveCompare(key) == .orderedSame || text.caseInsensitiveCompare(keys[key]?.uuidString ?? key) == .orderedSame
    }
}
