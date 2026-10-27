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

    /// review_task tells the Operator what its reviewer can't do, in step with `AgentReview`'s instructions to the reviewer: it
    /// reads files only, says on its first line which steps of a skill it skipped, and a skill that needs more runs in a tab.
    @Test func reviewTaskSaysWhatItsReviewerCannotDo() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/aitermd/operator_mcp.py")
        // The description as Python joins it: adjacent string literals are one.
        let python = try String(contentsOf: file, encoding: .utf8).replacing(try Regex(#""\s*\n\s*""#), with: "")
        let start = try #require(python.firstRange(of: #"_tool("review_task", ""#)?.upperBound)
        let description = String(python[start...].prefix { $0 != "\"" })
        #expect(description.contains("reads files only: it runs no commands and dispatches no subagents"), "\(description)")
        #expect(AgentReview.instructions.contains("You read files only: you run no commands and dispatch no subagents."))
        #expect(description.contains("says on its first line which steps of a named skill it skipped"), "\(description)")
        #expect(AgentReview.instructions.contains("say so on your first line, with the steps you skipped"))
        #expect(description.contains("open_tab with a read-only brief"), "\(description)")
    }
}
