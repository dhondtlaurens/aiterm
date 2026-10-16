import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct OperatorDefaultsTests {
    private let catalogue = [
        AgentModel(id: "claude-opus-5-5", label: "Opus", detail: nil, efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "xhigh"),
        AgentModel(id: "claude-sonnet-5", label: "Sonnet", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "medium"),
    ]

    @Test func aNewOperatorLeadsWithTheCataloguesFirstModelAtItsDefaultEffort() {
        let p = OperatorPersona.defaultNew(claudeModels: catalogue, defaults: ScratchDefaults.make())
        #expect(p.model == "claude-opus-5-5" && p.effort == "xhigh")
        #expect(p.secondOpinion == SecondOpinion(level: .healthyDoubt, agent: .codex, model: "gpt-6-astra", effort: "medium"))
        #expect(p.autonomy == .routine)
        #expect(p.limits == OperatorLimits(retries: 2, runtimeMinutes: 90))
        #expect(p.alwaysAsk.isEmpty && p.lessons.isEmpty)
        #expect(p.persona == OperatorPersona.starterPersona && !p.persona.isEmpty)
        #expect(p.handle == "operator" && OperatorLibrary.isValidHandle(p.handle))
    }

    /// Claude's default in Settings › Agents wins over the catalogue's order.
    @Test func theClaudeDefaultFromSettingsWins() {
        let defaults = ScratchDefaults.make()
        ModelSettings.save(ModelPreference(model: "claude-sonnet-5", reasoning: "high"), for: .claude, defaults: defaults)
        let p = OperatorPersona.defaultNew(claudeModels: catalogue, defaults: defaults)
        #expect(p.model == "claude-sonnet-5" && p.effort == "high")
    }

    @Test func withNoCatalogueTheLeadIsTheOpusAlias() {
        let p = OperatorPersona.defaultNew(claudeModels: [], defaults: ScratchDefaults.make())
        #expect(p.model == "opus" && p.effort == "high")
    }

    /// The default writes a file the library reads back as it was.
    @Test func theDefaultSurvivesItsFile() throws {
        let p = OperatorPersona.defaultNew(claudeModels: catalogue, defaults: ScratchDefaults.make())
        #expect(try OperatorFile.parse(OperatorFile.render(p)) == p)
    }
}
