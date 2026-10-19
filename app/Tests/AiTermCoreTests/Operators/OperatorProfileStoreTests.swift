import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Operator's one profile, kept as JSON under `operator.profile`.
@Suite struct OperatorProfileStoreTests {
    @Test func firstLoadUsesClaudesDefaultAndTheStandardOracle() {
        let profile = OperatorProfileStore.load(ScratchDefaults.make(), claudeDefault: (model: "claude-opus-5-5", reasoning: "high"))
        #expect(profile.model == "claude-opus-5-5")
        #expect(profile.reasoning == "high")
        #expect(profile.slices == .none)
        #expect(profile.oracle == .standard)
        #expect(profile.instructions == "")
    }

    @Test func theStandardOracleIsCodexOnAstraAtMedium() {
        #expect(OracleSetting.standard == OracleSetting(isOn: true, agent: .codex, model: "gpt-6-astra", reasoning: "medium"))
        #expect(Slices.none == Slices(jira: false, review: false, merge: false))
    }

    @Test func saveThenLoadRoundTrips() {
        let defaults = ScratchDefaults.make()
        let profile = OperatorProfile(model: "claude-sonnet-5", reasoning: nil, slices: Slices(jira: true, review: false, merge: true),
                                      oracle: OracleSetting(isOn: false, agent: .claude, model: "claude-opus-5-5", reasoning: "low"),
                                      instructions: "Run the linter before you accept.")
        OperatorProfileStore.save(profile, defaults)
        #expect(OperatorProfileStore.load(defaults, claudeDefault: (model: "claude-opus-5-5", reasoning: "high")) == profile)
        #expect(defaults.data(forKey: "operator.profile") != nil, "kept as JSON under operator.profile")
    }

    /// What is saved but cannot be read starts over from the defaults, rather than failing a broadcast.
    @Test func anUnreadableProfileLoadsTheDefaults() {
        let defaults = ScratchDefaults.make()
        defaults.set(Data("not json".utf8), forKey: "operator.profile")
        let profile = OperatorProfileStore.load(defaults, claudeDefault: (model: "claude-opus-5-5", reasoning: nil))
        #expect(profile == OperatorProfile(model: "claude-opus-5-5", reasoning: nil))
    }

    /// Claude's default from Settings › Agents, else the catalogue's first model, else Claude's own alias.
    @Test func claudesDefaultComesFromSettingsThenTheCatalogue() {
        let models = [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: ["low", "high"], defaultEffort: "high"),
                      AgentModel(id: "claude-sonnet-5", label: "Sonnet 5", detail: nil, efforts: ["low", "medium"], defaultEffort: "medium")]
        let fromCatalogue = OperatorProfileStore.claudeDefault(models: models, defaults: ScratchDefaults.make())
        #expect(fromCatalogue.model == "claude-opus-5-5" && fromCatalogue.reasoning == "high")
        let none = OperatorProfileStore.claudeDefault(models: [], defaults: ScratchDefaults.make())
        #expect(none.model == "opus" && none.reasoning == "high")
        let defaults = ScratchDefaults.make()
        ModelSettings.save(ModelPreference(model: "claude-sonnet-5", reasoning: "low"), for: .claude, defaults: defaults)
        let saved = OperatorProfileStore.claudeDefault(models: models, defaults: defaults)
        #expect(saved.model == "claude-sonnet-5" && saved.reasoning == "low")
    }
}
