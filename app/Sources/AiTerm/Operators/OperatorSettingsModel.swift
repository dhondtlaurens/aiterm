import Foundation
import Observation
import AiTermCore

/// Settings › Operator's edits (spec §8), staged until the sheet's Save writes them through
/// `OperatorProfileStore.save`; Cancel drops the model and with it every edit. Each part of the
/// profile is its own property, so a keystroke in Instructions redraws that group alone.
@MainActor
@Observable
final class OperatorSettingsModel {
    /// What `load` reads off the main actor: the saved profile, the catalogues the Selects offer, the
    /// model each agent defaults to (which picking the Oracle's agent takes), and what `/` lists.
    struct Loaded: Sendable {
        var profile: OperatorProfile
        var models: [AgentKind: [AgentModel]]
        var agentDefaults: [AgentKind: ModelPreference]
        var skills: [AgentCompletion]
    }

    /// The agents that can be the Oracle: every one, since `ChallengeLaunch` runs each headless.
    nonisolated static let oracleAgents: [AgentKind] = AgentKind.allCases

    private(set) var isLoaded = false
    /// The Operator's model and reasoning: always Claude's.
    private(set) var model = ""
    private(set) var reasoning: String?
    var slices = Slices.none
    var oracle = OracleSetting.standard
    var instructions = ""
    private(set) var models: [AgentKind: [AgentModel]] = [:]
    /// What `/` lists in Instructions.
    let completions = PromptCompletions()
    @ObservationIgnored private var agentDefaults: [AgentKind: ModelPreference] = [:]
    /// The profile as loaded, so Save writes only a change.
    @ObservationIgnored private var original: OperatorProfile?
    @ObservationIgnored private let read: @Sendable () -> Loaded
    @ObservationIgnored private let write: @MainActor (OperatorProfile) throws -> Void
    /// The agent CLIs this machine has, read live (`AgentIntegrations.availableAgents`), so the
    /// Oracle's Agent follows a probe or an install landing while Settings is open.
    @ObservationIgnored private let installed: @MainActor () -> Set<AgentKind>

    init(installed: @escaping @MainActor () -> Set<AgentKind> = { Set(AgentKind.allCases) },
         load: @escaping @Sendable () -> Loaded, save: @escaping @MainActor (OperatorProfile) throws -> Void) {
        self.installed = installed
        read = load
        write = save
    }

    /// What the Oracle's Agent offers: the Oracle agents installed here, and the one saved or picked
    /// even when it is not, shown as it is rather than swapped for another.
    var oracleAgentChoices: [AgentKind] {
        let present = installed()
        return Self.oracleAgents.filter { present.contains($0) || $0 == oracle.agent || $0 == original?.oracle.agent }
    }

    /// The profile as it stands, edits and all.
    var profile: OperatorProfile {
        OperatorProfile(model: model, reasoning: reasoning, slices: slices, oracle: oracle, instructions: instructions)
    }

    /// Reads the profile, the catalogues and the skills off the main actor, as Settings opens.
    func load() async {
        let read = self.read
        let loaded = await BackgroundWork.run { read() }
        guard !Task.isCancelled else { return }
        received(loaded)
    }

    /// Loads unless a test or a snapshot has already handed the model what it would find.
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await load()
    }

    /// What a load found; the snapshots hand it in directly.
    func received(_ loaded: Loaded) {
        let profile = loaded.profile
        model = profile.model
        reasoning = profile.reasoning
        slices = profile.slices
        oracle = profile.oracle
        instructions = profile.instructions
        models = loaded.models
        agentDefaults = loaded.agentDefaults
        original = profile
        completions.all = loaded.skills
        completions.close()
        isLoaded = true
    }

    /// The sheet's Save: writes the profile when it changed, and nothing otherwise, so a profile never
    /// saved keeps following Claude's default in Settings › Agents. An empty model is never written:
    /// the one loaded stands in for it.
    func save() {
        guard isLoaded, let original else { return }
        var saving = profile
        if saving.model.isEmpty { saving.model = original.model; saving.reasoning = original.reasoning }
        if saving.oracle.model.isEmpty {
            saving.oracle = OracleSetting(isOn: saving.oracle.isOn, agent: original.oracle.agent,
                                          model: original.oracle.model, reasoning: original.oracle.reasoning)
        }
        guard saving != original else { return }
        // One that could not be written is still a change to save.
        guard (try? write(saving)) != nil else { return }
        self.original = saving
    }

    // -- picking --------------------------------------------------------------------

    func select(model picked: AgentModel) {
        model = picked.id
        reasoning = Self.reasoning(keeping: reasoning, on: picked)
    }

    func select(reasoning picked: String) { reasoning = picked }

    /// Takes the agent's default model at its reasoning; the Oracle stays on or off as it was. An
    /// agent not offered, or with no model to take, is no pick.
    func select(oracleAgent agent: AgentKind) {
        guard agent != oracle.agent, oracleAgentChoices.contains(agent) else { return }
        let choice = defaultChoice(for: agent)
        guard !choice.model.isEmpty else { return }
        oracle = OracleSetting(isOn: oracle.isOn, agent: agent, model: choice.model, reasoning: choice.reasoning)
    }

    func select(oracleModel picked: AgentModel) {
        oracle.model = picked.id
        oracle.reasoning = Self.reasoning(keeping: oracle.reasoning, on: picked)
    }

    func select(oracleReasoning picked: String) { oracle.reasoning = picked }

    /// The agent's default (Settings › Agents' card, else its catalogue's first model), else the
    /// first model its catalogue lists, else the standard Oracle's for Codex.
    private func defaultChoice(for agent: AgentKind) -> ModelPreference {
        if let choice = agentDefaults[agent], !choice.model.isEmpty { return choice }
        if let first = models[agent]?.first { return ModelPreference(model: first.id, reasoning: first.defaultEffort ?? first.efforts.first) }
        if agent == OracleSetting.standard.agent {
            return ModelPreference(model: OracleSetting.standard.model, reasoning: OracleSetting.standard.reasoning)
        }
        return ModelPreference(model: "", reasoning: nil)
    }

    /// The reasoning a picked model runs at: the one kept while it can, else its own default.
    private static func reasoning(keeping current: String?, on model: AgentModel) -> String? {
        if let current, model.efforts.contains(current) { return current }
        return model.defaultEffort ?? model.efforts.first
    }

    // -- what the Selects offer -----------------------------------------------------

    /// The catalogue, led by the saved model when it no longer lists it (or there is none), named by
    /// its id, so a Select never shows a model that is not the one saved.
    static func options(_ models: [AgentModel], keeping id: String, reasoning: String?) -> [AgentModel] {
        guard !id.isEmpty, !models.contains(where: { $0.id == id }) else { return models }
        let kept = AgentModel(id: id, label: id, detail: nil, efforts: reasoning.map { [$0] } ?? [], defaultEffort: reasoning)
        return [kept] + models
    }

    /// A model's reasoning levels, led by the saved one when the model does not list it. Empty: the
    /// model takes no reasoning, and Reasoning is not drawn.
    static func efforts(of model: AgentModel, keeping reasoning: String?) -> [String] {
        guard let reasoning, !model.efforts.contains(reasoning) else { return model.efforts }
        return [reasoning] + model.efforts
    }
}

extension OperatorSettingsModel {
    /// The live model: the profile, the catalogues and the skills as these defaults and this machine
    /// have them, and Save writing to the same defaults.
    static func live(defaults: UserDefaults, catalogue: ModelCatalogue, installed: @escaping @MainActor () -> Set<AgentKind>,
                     skills: @escaping @Sendable (AgentKind) -> [AgentCompletion] = { SkillCatalog.discover(agent: $0, projectPath: nil) }) -> OperatorSettingsModel {
        // UserDefaults is thread-safe, though not marked Sendable.
        nonisolated(unsafe) let store = defaults
        let installedNow = installed()
        return OperatorSettingsModel(installed: installed, load: {
            var models: [AgentKind: [AgentModel]] = [:], agentDefaults: [AgentKind: ModelPreference] = [:]
            for agent in oracleAgents {
                let listed = (try? catalogue.models(for: agent)) ?? []
                models[agent] = listed
                agentDefaults[agent] = ModelSettings.resolve(for: agent, catalog: listed, defaults: store)
            }
            let claude = OperatorProfileStore.claudeDefault(models: models[.claude] ?? [], defaults: store)
            agentDefaults[.claude] = ModelPreference(model: claude.model, reasoning: claude.reasoning)
            return Loaded(profile: OperatorProfileStore.load(store, claudeDefault: claude, installed: installedNow), models: models,
                          agentDefaults: agentDefaults, skills: OperatorSkills.listed(at: [nil]) { agent, _ in skills(agent) })
        }, save: { try OperatorProfileStore.save($0, store) })
    }
}
