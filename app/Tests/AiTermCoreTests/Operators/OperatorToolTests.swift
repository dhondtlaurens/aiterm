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



    /// ask_you's descriptions and rule 2 agree on which questions hold a task: a stopped worker in every run, and in a
    /// new run exhausted fix rounds too (a legacy run has none), the rest asked with holds false; and on which go on no
    /// task. The descriptions say both, as they serve both kinds of run.
    @Test func askYouAndTheBriefAllowTheSameTaskQuestions() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/aitermd/operator_mcp.py")
        let python = try String(contentsOf: file, encoding: .utf8).replacing(try Regex(#""\s*\n\s*""#), with: "")
        let start = try #require(python.firstRange(of: #"_tool("ask_you", ""#)?.upperBound)
        /// The description of `property`: the first string after `opening` that follows its name.
        func described(_ property: String, after opening: String) throws -> String {
            let name = try #require(python[start...].firstRange(of: "\"\(property)\": ")?.upperBound)
            let from = try #require(python[name...].firstRange(of: opening)?.upperBound)
            return String(python[from...].prefix { $0 != "\"" })
        }
        let task = try described("task", after: "_text(\"")
        let holds = try described("holds", after: "\"description\": \"")
        let newRun = OperatorCommand.brief(run: OperatorFixtures.run(taskSettings: OperatorFixtures.taskSettings), projects: [])
        let stopped = "worker is itself stopped on the answer", fixRounds = "or when its fix rounds are used up (about: fixRounds)"
        #expect(holds.contains(stopped) && newRun.contains(stopped))
        #expect(holds.contains(fixRounds) && newRun.contains(fixRounds))
        #expect(holds.hasPrefix("False when the task can go on without the answer") && newRun.contains("otherwise set holds false"))
        #expect(task.contains("Other questions about your own next step"))
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

    /// Each tool's traits are one exhaustive answer: a tool only looks or changes something, a veto is the Oracle's yes
    /// (`vetoes`), and the Activity tab mutes exactly the tools that look.
    @Test func eachToolHasItsTraits() {
        #expect(OperatorTool.allCases.filter(\.isReadOnly) == [.runStatus, .jiraSearch, .jiraBoard, .readTask, .findUser])
        #expect(OperatorTool.allCases.allSatisfy { $0.isReadOnly != $0.isMutating })
        #expect(OperatorTool.allCases.filter { $0.challengeClass == .veto } == OperatorTool.allCases.filter(\.isVeto))
        #expect(OperatorTool.allCases.filter { $0.challengeClass == .critique } == [.submitPlan, .markTask])
        #expect(OperatorTool.allCases.filter { $0.challengeClass == .relay } == [.relayQuestion])
        #expect(OperatorTool.allCases.filter { $0.actKind == .onTask }
                == [.reviewTask, .requestReview, .replyThread, .messageTask, .markTask, .finishTask])
        #expect(ActivityLine.reads == Set(OperatorTool.allCases.filter(\.isReadOnly).map(\.rawValue) + ["shell_read"]))
    }
}


extension OperatorToolTests {
    /// Read the daemon's declared list itself; the served schema and its frozen fixture stay untouched.
    @Test func theDaemonAndSwiftChallengeTheSameTools() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/aitermd/operator_mcp.py")
        let python = try String(contentsOf: file, encoding: .utf8)
        let list = try #require(python.firstMatch(of: try Regex(#"(?s)CHALLENGED_TOOLS\s*=\s*\((.*?)\)"#))?.output[1].substring)
        let names = String(list).matches(of: try Regex(#""([a-z_]+)""#)).compactMap { $0.output[1].substring.map(String.init) }
        #expect(!names.isEmpty)
        #expect(Set(names) == Set(OperatorTool.allCases.filter { $0.challengeClass != .never }.map(\.rawValue)))
    }
}
