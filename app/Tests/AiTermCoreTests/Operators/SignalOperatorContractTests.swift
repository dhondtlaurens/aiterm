import Foundation
import Testing
@testable import AiTermCore

@Suite struct SignalOperatorContractTests {
    @Test func theSurfaceHasThirteenToolsAndExplicitTraits() throws {
        #expect(OperatorTool.allCases.count == 13)
        #expect(Set(OperatorTool.allCases.filter { !$0.mutating }.map(\.rawValue)) == ["run_status", "read_task", "jira_search"])
        #expect(OperatorTool.answerWorker.requiresKey && OperatorTool.askOracle.requiresKey)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/operator-signals")
        #expect(try String(contentsOf: folder.appendingPathComponent("brief.md"), encoding: .utf8) == OperatorLaunch.brief)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(try Data(contentsOf: folder.appendingPathComponent("tools.json")) == Data(contentsOf: root.appendingPathComponent("daemon/aitermd/signal_tools.json")))
        let tools = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: folder.appendingPathComponent("tools.json")))
        #expect(Set(tools.compactMap { $0["name"]?.stringValue }) == Set(OperatorTool.allCases.map(\.rawValue)))
        for tool in tools {
            let kind = try #require(tool["name"]?.stringValue.flatMap(OperatorTool.init(rawValue:)))
            let required = tool["inputSchema"]?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let agent = tool["inputSchema"]?["properties"]?["agent"]
            if agent != nil || [.openTab, .resumeTask, .chooseAgent].contains(kind) {
                #expect(agent?["enum"]?.arrayValue?.compactMap(\.stringValue) == AgentCommand.workerAgents.map(\.rawValue))
            }
            if kind.requiresKey { #expect(required.contains("key")) }
            if kind.taskRequired { #expect(required.contains("task") && required.contains("stage") && required.contains("ownership")) }
        }
    }
}
