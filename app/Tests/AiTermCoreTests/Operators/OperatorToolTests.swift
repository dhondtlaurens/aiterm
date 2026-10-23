import Foundation
import Testing
@testable import AiTermCore

/// The Operator's tools as the app names them (`OperatorTool`) and as the daemon serves them.
@Suite struct OperatorToolTests {
    /// Every tool `daemon/aitermd/operator_mcp.py` declares (`_tool("…"`) is a case, and every case is one it declares:
    /// a tool the app has no case for would be answered "AiTerm has no tool called …", and a case the daemon dropped is
    /// a name nothing calls.
    @Test func theAppNamesEveryToolTheDaemonServes() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/aitermd/operator_mcp.py")
        let python = try String(contentsOf: file, encoding: .utf8)
        let declared = python.matches(of: try Regex(#"_tool\(\s*"([a-z_]+)""#)).compactMap { $0.output[1].substring.map(String.init) }
        #expect(declared.count >= 30, "the daemon's tools, read from \(file.path)")
        #expect(Set(declared).count == declared.count, "a name declared twice: \(declared)")
        #expect(Set(declared) == Set(OperatorTool.allCases.map(\.rawValue)))
    }
}
