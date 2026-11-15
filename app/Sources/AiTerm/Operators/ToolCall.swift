import Foundation
import AiTermCore

enum ToolAnswer: Equatable, Sendable {
    case result(JSONValue), error(String)
    var value: JSONValue? { if case .result(let value) = self { value } else { nil } }
    var message: String? { if case .error(let message) = self { message } else { nil } }
}

struct ToolRefusal: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }

    /// Any tool of a broadcast that has ended.
}

struct ToolCall {
    let tool: String, arguments: JSONValue
    enum MarkOutcome: String { case accepted, noChange, blocked, failed }
    let markOutcome: MarkOutcome?

    init(tool: String, arguments: JSONValue) {
        self.tool = tool; self.arguments = arguments
        self.markOutcome = (arguments["outcome"]?.stringValue).said.flatMap(MarkOutcome.init(rawValue:))
    }

    /// The tool by its name; nil for a name AiTerm has no tool for.

    func string(_ key: String) throws(ToolRefusal) -> String {
        guard let value = optionalString(key) else { throw ToolRefusal("\(tool) needs `\(key)`.") }
        return value
    }

    func optionalString(_ key: String) -> String? {
        (arguments[key]?.stringValue).said
    }

    func optionalBool(_ key: String) -> Bool? { arguments[key]?.boolValue }
}
