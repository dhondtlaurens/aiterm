import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Operator (spec §8): its agent, its autonomy, the Oracle and its instructions, staged in
/// `OperatorSettingsModel` and written by the sheet's Save through `OperatorProfileStore.save`.
@MainActor struct OperatorSettingsPaneTests {
    nonisolated static let opus = AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")
    nonisolated static let sonnet = AgentModel(id: "claude-sonnet-5", label: "Sonnet 5", detail: nil, efforts: [], defaultEffort: nil)
    nonisolated static let astra = AgentModel(id: "gpt-6-astra", label: "gpt-6-astra", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "medium")
    nonisolated static let mini = AgentModel(id: "gpt-6-mini", label: "gpt-6-mini", detail: nil, efforts: ["low", "high"], defaultEffort: "low")
    nonisolated static let sol = AgentModel(id: "openai-codex/gpt-5.6-sol", label: "openai-codex / gpt-5.6-sol", detail: nil,
                                            efforts: PiModelCatalog.thinkingLevels, defaultEffort: "medium")

    /// A model over `defaults`, as Settings makes it: the saved profile loaded from them, Claude's and
    /// Codex's catalogues, and Save writing back to them.
    private func settings(_ defaults: UserDefaults) -> OperatorSettingsModel {
        // UserDefaults is thread-safe, though not marked Sendable.
        nonisolated(unsafe) let defaults = defaults
        return OperatorSettingsModel(load: {
            OperatorSettingsModel.Loaded(
                profile: OperatorProfileStore.load(defaults, claudeDefault: (model: "claude-opus-5-5", reasoning: "high")),
                models: [.claude: [Self.opus, Self.sonnet], .codex: [Self.mini, Self.astra], .pi: [Self.sol]],
                agentDefaults: [.claude: ModelPreference(model: "claude-opus-5-5", reasoning: "high"),
                                .codex: ModelPreference(model: "gpt-6-mini", reasoning: "low"),
                                .pi: ModelPreference(model: "openai-codex/gpt-5.6-sol", reasoning: "medium")],
                skills: [])
        }, save: { try OperatorProfileStore.save($0, defaults) })
    }

    /// A model already loaded with `profile`, over `installed` agents and the catalogues given.
    private func loaded(_ profile: OperatorProfile, installed: Set<AgentKind>,
                        models: [AgentKind: [AgentModel]] = [.claude: [Self.opus], .codex: [Self.astra]],
                        agentDefaults: [AgentKind: ModelPreference] = [:],
                        into defaults: UserDefaults = ScratchDefaults.make()) -> OperatorSettingsModel {
        nonisolated(unsafe) let defaults = defaults
        let settings = OperatorSettingsModel(installed: { installed }, load: { fatalError("handed in") },
                                             save: { try OperatorProfileStore.save($0, defaults) })
        settings.received(.init(profile: profile, models: models, agentDefaults: agentDefaults, skills: []))
        return settings
    }

    private func saved(_ defaults: UserDefaults) -> OperatorProfile {
        OperatorProfileStore.load(defaults, claudeDefault: (model: "unsaved", reasoning: nil))
    }

    /// Save writes what was changed, through `OperatorProfileStore.save`; with nothing changed it
    /// writes nothing, so Claude's default from Settings › Agents keeps flowing into an unsaved profile.
    @Test func savesTheProfile() async {
        let defaults = ScratchDefaults.make()
        let settings = settings(defaults)
        settings.save()
        #expect(defaults.data(forKey: "operator.profile") == nil, "nothing loaded yet, nothing written")
        await settings.load()
        #expect(settings.isLoaded)
        settings.save()
        #expect(defaults.data(forKey: "operator.profile") == nil, "nothing changed, nothing written")

        settings.select(model: Self.sonnet)
        #expect(settings.reasoning == nil, "Sonnet 5 takes no reasoning")
        settings.slices.merge = true
        settings.slices.jira = true
        settings.instructions = "Draft MRs only on Fridays."
        settings.save()
        #expect(saved(defaults) == OperatorProfile(model: "claude-sonnet-5", reasoning: nil, slices: Slices(jira: true, merge: true),
                                                   oracle: .standard, instructions: "Draft MRs only on Fridays."))
    }

    /// Cancel is not saving: the edits stay in the model the sheet drops.
    @Test func cancelDiscards() async throws {
        let defaults = ScratchDefaults.make()
        let kept = OperatorProfile(model: "claude-opus-5-5", reasoning: "low", slices: Slices(review: true))
        try OperatorProfileStore.save(kept, defaults)
        let settings = settings(defaults)
        await settings.load()
        #expect(settings.profile == kept)
        settings.slices.review = false
        settings.select(reasoning: "high")
        #expect(saved(defaults) == kept)
    }

    /// The Oracle off dims its fields and keeps them: Save writes it off with its agent, model and
    /// reasoning as they were, and turning it back on finds them there.
    @Test func oracleOffDimsAndKeeps() async {
        let defaults = ScratchDefaults.make()
        let settings = settings(defaults)
        await settings.load()
        #expect(!OperatorSettingsPane.oracleFieldsDimmed(settings.oracle))
        settings.oracle.isOn = false
        #expect(OperatorSettingsPane.oracleFieldsDimmed(settings.oracle))
        #expect(settings.oracle == OracleSetting(isOn: false, agent: .codex, model: "gpt-6-astra", reasoning: "medium"))
        settings.save()
        #expect(saved(defaults).oracle == OracleSetting(isOn: false, agent: .codex, model: "gpt-6-astra", reasoning: "medium"))
        settings.oracle.isOn = true
        #expect(settings.oracle == .standard)
    }

    /// Picking the Oracle's agent takes that agent's default model at its reasoning; picking a model
    /// keeps the reasoning it can run at, else takes the model's own.
    @Test func pickingTheOraclesAgentTakesItsDefault() async {
        let settings = settings(ScratchDefaults.make())
        await settings.load()
        #expect(OperatorSettingsModel.oracleAgents == [.claude, .codex, .pi])
        #expect(settings.oracleAgentChoices == [.claude, .codex, .pi], "all installed")
        settings.select(oracleAgent: .claude)
        #expect(settings.oracle == OracleSetting(isOn: true, agent: .claude, model: "claude-opus-5-5", reasoning: "high"))
        settings.select(oracleAgent: .codex)
        #expect(settings.oracle == OracleSetting(isOn: true, agent: .codex, model: "gpt-6-mini", reasoning: "low"))
        settings.select(oracleModel: Self.astra)
        #expect(settings.oracle.reasoning == "low", "Astra runs at low too")
        settings.select(oracleReasoning: "medium")
        settings.select(oracleModel: Self.mini)
        #expect(settings.oracle.reasoning == "low", "Mini has no medium, so its own default")
        settings.select(oracleAgent: .pi)
        #expect(settings.oracle == OracleSetting(isOn: true, agent: .pi, model: "openai-codex/gpt-5.6-sol", reasoning: "medium"))
    }

    /// The Oracle's Agent offers the agents installed here; the saved one stays, shown as it is,
    /// though it is not installed, and one neither installed nor saved is no pick.
    @Test func theOraclesAgentIsOneInstalled() {
        let opusProfile = OperatorProfile(model: "claude-opus-5-5", reasoning: "high")
        let codexSaved = loaded(opusProfile, installed: [.claude])
        #expect(codexSaved.oracleAgentChoices == [.claude, .codex], "Codex is saved: shown, not swapped")
        codexSaved.select(oracleAgent: .claude)
        #expect(codexSaved.oracle.agent == .claude)
        #expect(codexSaved.oracleAgentChoices == [.claude, .codex], "still the saved one, to go back to")

        let claudeOracle = OracleSetting(isOn: true, agent: .claude, model: "claude-opus-5-5", reasoning: "high")
        let claudeSaved = loaded(OperatorProfile(model: "claude-opus-5-5", reasoning: "high", oracle: claudeOracle), installed: [.claude])
        #expect(claudeSaved.oracleAgentChoices == [.claude])
        claudeSaved.select(oracleAgent: .codex)
        #expect(claudeSaved.oracle == claudeOracle, "Codex is not installed")
        let both = loaded(OperatorProfile(model: "claude-opus-5-5", reasoning: "high", oracle: claudeOracle), installed: [.claude, .codex])
        #expect(both.oracleAgentChoices == [.claude, .codex])

        let piOracle = OracleSetting(isOn: true, agent: .pi, model: "openai-codex/gpt-5.6-sol", reasoning: "medium")
        let piSaved = loaded(OperatorProfile(model: "claude-opus-5-5", reasoning: "high", oracle: piOracle), installed: [.claude])
        #expect(piSaved.oracleAgentChoices == [.claude, .pi], "PI is saved: shown, not swapped")
    }

    /// No pick leaves a model empty, and Save never writes one: the loaded model stands in.
    @Test func anEmptyModelIsNeverSaved() {
        let defaults = ScratchDefaults.make()
        let profile = OperatorProfile(model: "claude-opus-5-5", reasoning: "high")
        let settings = loaded(profile, installed: [.claude, .codex], models: [:], into: defaults)
        settings.select(oracleAgent: .claude)
        #expect(settings.oracle == .standard, "Claude has no model to take here, so it is no pick")

        settings.select(model: AgentModel(id: "", label: "Unavailable", detail: nil, efforts: [], defaultEffort: nil))
        settings.oracle.model = ""
        settings.slices.jira = true
        settings.save()
        let written = saved(defaults)
        #expect(written.model == "claude-opus-5-5" && written.reasoning == "high")
        #expect(written.oracle == .standard)
        #expect(written.slices.jira, "the rest of the edit is kept")
    }

    /// A saved model the catalogue no longer lists is still offered, by its id, with its reasoning.
    @Test func aModelOffTheCatalogueIsStillOffered() {
        let options = OperatorSettingsModel.options([Self.opus], keeping: "opus", reasoning: "high")
        #expect(options.map(\.id) == ["opus", "claude-opus-5-5"])
        #expect(options[0].label == "opus")
        #expect(OperatorSettingsModel.efforts(of: options[0], keeping: "high") == ["high"])
        #expect(OperatorSettingsModel.efforts(of: Self.opus, keeping: "xhigh") == ["xhigh", "low", "medium", "high"])
        #expect(OperatorSettingsModel.efforts(of: Self.sonnet, keeping: nil).isEmpty)
        #expect(OperatorSettingsModel.options([Self.opus], keeping: "claude-opus-5-5", reasoning: nil).map(\.id) == ["claude-opus-5-5"])
    }

    /// The groups' copy, as drawn in p-op-settings.
    @Test func theCopyIsAsDrawn() {
        typealias Pane = OperatorSettingsPane
        #expect(Pane.agentHelp == "It plans the work and steers the agents in your tasks. It reads code but never writes it.")
        #expect(Pane.autonomyHelp == "What it does without asking you. Each switch is one slice of trust on top of the base. Changes apply to the next broadcast.")
        #expect(Pane.slices.map(\.title) == ["Jira", "Review", "Merge"])
        #expect(Pane.never == [
            "Never writes code itself. Its agents do.",
            "Never deploys, force-pushes, or pushes to a default or protected branch.",
            "Never answers an agent’s permission prompt. That’s always yours.",
        ])
        #expect(Pane.oracleHelp.hasSuffix("Changes apply to the next broadcast."))
        #expect(Pane.oracleHelp.contains("PI checks with read-only tools, not a sandbox."))
        #expect(Pane.instructionsHelp == "House rules for every broadcast. Type / for the agents’ skills.")
        let copy = [Pane.agentHelp, Pane.autonomyHelp, Pane.baseHelp, Pane.oracleHelp, Pane.instructionsHelp]
            + Pane.slices.map(\.help) + Pane.never
        #expect(copy.allSatisfy { !$0.contains("—") && !$0.contains("'") }, "no em dashes, curly apostrophes")
    }
}
