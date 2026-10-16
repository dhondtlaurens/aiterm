import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Agents' "Agents at once", as `AgentIntegrations` keeps it and the group words it.
@MainActor struct AgentsAtOnceTests {
    private func integrations(_ defaults: UserDefaults) -> AgentIntegrations {
        AgentIntegrations(harnessHome: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                          bundledResourcesURL: nil, locateAgents: { nil }, rememberedModels: { [:] }, defaults: defaults)
    }

    @Test func theCountIsSavedOnEveryChangeAndReadAtTheNextLaunch() {
        let defaults = ScratchDefaults.make()
        let first = integrations(defaults)
        #expect(first.agentsAtOnce == 2)
        var told = 0
        first.agentsAtOnceChanged = { told += 1 }
        first.agentsAtOnce = 4
        first.agentsAtOnce = 4
        #expect(told == 1, "an equal write is no change")
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 4)
        #expect(integrations(defaults).agentsAtOnce == 4)
    }

    @Test func theHelpSaysWhatTheCountDoes() {
        #expect(AgentsAtOnceGroup.help(1) == "Operators start one agent at a time, across every operation, each in its own worktree and window. Lowering it stops no agent that is running.")
        #expect(AgentsAtOnceGroup.help(3) == "Operators run up to 3 agents at once, across every operation, each in its own worktree and window. Lowering it stops no agent that is running.")
    }

    @Test func theImageIsDrawnLastInTheSettingsSetAndTheSameTwice() throws {
        let snapshot = try #require(SettingsSnapshots.all.last)
        #expect(snapshot.file == "settings-agents-at-once.png")
        let first = try #require(Snapshots.png(of: snapshot), "\(snapshot.file) drew nothing")
        let second = try #require(Snapshots.png(of: snapshot))
        #expect(first.count > 1_000, "\(snapshot.file) is empty")
        #expect(first == second, "\(snapshot.file) is not drawn the same twice")
    }
}
