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



    /// ask_you's task description and rule 2 agree on which questions hold a task: a stopped worker in every run, and in a
    /// new run exhausted fix rounds too (a legacy run has none). The description says both, as it serves both kinds of run.
    @Test func askYouAndTheBriefAllowTheSameTaskQuestions() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/aitermd/operator_mcp.py")
        let python = try String(contentsOf: file, encoding: .utf8).replacing(try Regex(#""\s*\n\s*""#), with: "")
        let start = try #require(python.firstRange(of: #"_tool("ask_you", ""#)?.upperBound)
        let task = try #require(python[start...].firstRange(of: #""task": _text(""#)?.upperBound)
        let description = String(python[task...].prefix { $0 != "\"" })
        let newRun = OperatorCommand.brief(run: OperatorFixtures.run(taskSettings: OperatorFixtures.taskSettings), projects: [])
        let stopped = "worker is itself stopped on the answer", fixRounds = "or when its fix rounds are used up (about: fixRounds)"
        #expect(description.contains(stopped) && newRun.contains(stopped))
        #expect(description.contains(fixRounds) && newRun.contains(fixRounds))
        #expect(description.contains("Other questions about your own next step"))
        #expect(newRun.contains("Other questions about your own next step"))
    }

    /// The calls that act only on the Oracle's yes have one home: the handler challenges them as a veto, and a new run's
    /// brief names each, so the two can't drift.
    @Test func theVetoesHaveOneHomeThatTheBriefNames() {
        #expect(OperatorTool.vetoes.map(\.tool) == [.createTask, .finishTask, .checkGoal])
        #expect(OperatorTool.allCases.filter(\.isVeto) == [.createTask, .finishTask, .checkGoal])
        #expect(OperatorTool.vetoes.map(\.unanswered) == [.refused, .goesAhead, .actsUnchecked])
        let brief = OperatorCommand.brief(run: OperatorFixtures.run(taskSettings: OperatorFixtures.taskSettings), projects: [])
        for veto in OperatorTool.vetoes {
            #expect(brief.contains(veto.call), "\(veto.call)")
            #expect(brief.contains(veto.tool.rawValue + " " + veto.unanswered.words), "\(veto.tool)")
        }
    }
}
