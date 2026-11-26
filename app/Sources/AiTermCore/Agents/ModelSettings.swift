import Foundation

public struct ModelPreference: Equatable, Sendable {
    public var model: String
    public var reasoning: String?

    public init(model: String, reasoning: String?) {
        self.model = model
        self.reasoning = reasoning
    }

    /// Keep a supported effort when changing models; otherwise use the new model's default.
    public mutating func select(_ model: AgentModel) {
        self.model = model.id
        if let reasoning, model.efforts.contains(reasoning) { return }
        reasoning = model.defaultEffort.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.efforts.first
    }
}

public enum ModelPreferenceResolution: Equatable, Sendable {
    case valid(ModelPreference)
    case missing(ModelPreference)
    case empty
}

/// App-wide defaults are separate from last-used models, so a one-off task cannot replace them.
public enum ModelSettings {
    private static func key(for agent: AgentKind) -> String { "modelDefaults.\(agent.rawValue)" }

    public static func load(for agent: AgentKind, defaults: UserDefaults = .standard) -> ModelPreference? {
        guard let value = defaults.dictionary(forKey: key(for: agent)),
              let model = value["model"] as? String, !model.isEmpty else { return nil }
        return ModelPreference(model: model, reasoning: value["reasoning"] as? String)
    }

    public static func save(_ preference: ModelPreference, for agent: AgentKind, defaults: UserDefaults = .standard) {
        var value = ["model": preference.model]
        value["reasoning"] = preference.reasoning
        defaults.set(value, forKey: key(for: agent))
    }

    /// A saved app-wide default is deliberate. If its exact identifier disappears, preserve it as
    /// missing rather than silently crossing providers or choosing a different model.
    public static func resolution(for agent: AgentKind, catalog: [AgentModel], remembered: String? = nil,
                                  defaults: UserDefaults = .standard) -> ModelPreferenceResolution {
        if let saved = load(for: agent, defaults: defaults) {
            guard let (model, effort) = find(saved.model, in: catalog) else { return .missing(saved) }
            var preference = ModelPreference(model: model.id, reasoning: effort ?? saved.reasoning)
            preference.select(model)
            return .valid(preference)
        }
        let found = remembered.flatMap { find($0, in: catalog) }
        guard let model = found?.model ?? catalog.first else { return .empty }
        var preference = ModelPreference(model: model.id, reasoning: found?.effort)
        preference.select(model)
        return .valid(preference)
    }

    /// The catalogue's model for `id`, or for an id that names its effort as well: Antigravity's
    /// were saved as `gemini-4-neon-high` before its catalogue folded them into `gemini-4-neon` at
    /// `high` (`AgyModelCatalog`).
    private static func find(_ id: String, in catalog: [AgentModel]) -> (model: AgentModel, effort: String?)? {
        if let model = catalog.first(where: { $0.id == id }) { return (model, nil) }
        for model in catalog {
            if let effort = model.efforts.first(where: { id == model.id + "-" + $0 }) { return (model, effort) }
        }
        return nil
    }

    /// Convert explicit resolution into the draft value. A missing saved model stays empty so it
    /// cannot reach a launch command; the saved preference itself remains untouched in defaults.
    public static func resolve(for agent: AgentKind, catalog: [AgentModel], remembered: String? = nil,
                               defaults: UserDefaults = .standard) -> ModelPreference {
        switch resolution(for: agent, catalog: catalog, remembered: remembered, defaults: defaults) {
        case .valid(let preference): return preference
        case .missing, .empty: return ModelPreference(model: "", reasoning: nil)
        }
    }
}
