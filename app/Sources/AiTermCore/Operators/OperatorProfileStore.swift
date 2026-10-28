import Foundation

/// Settings › Operator's profile, kept as JSON in UserDefaults under `operator.profile`. A broadcast
/// copies it when it starts. Oracle changes also apply to running broadcasts.
public enum OperatorProfileStore {
    static let key = "operator.profile"
    private static let oracleRevisionKey = "operator.oracleRevision"
    public static let didSave = Notification.Name("AiTerm.OperatorProfileSaved")

    public static func saved(_ defaults: UserDefaults) -> OperatorProfile? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(OperatorProfile.self, from: $0) }
    }

    public static func oracleRevision(_ defaults: UserDefaults) -> Int { defaults.integer(forKey: oracleRevisionKey) }

    /// The saved profile; before the first save, or when what is saved cannot be read, Claude's default
    /// model with every slice off, the standard Oracle and no instructions.
    public static func load(_ defaults: UserDefaults = .standard, claudeDefault: (model: String, reasoning: String?), installed: Set<AgentKind> = Set(AgentKind.allCases)) -> OperatorProfile {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(OperatorProfile.self, from: data) { return saved }
        var profile = OperatorProfile(model: claudeDefault.model, reasoning: claudeDefault.reasoning)
        profile.oracle.isOn = installed.contains(.codex)
        return profile
    }

    /// Writes `profile`; an encoding failure throws and leaves what was saved before.
    public static func save(_ profile: OperatorProfile, _ defaults: UserDefaults = .standard) throws {
        let data = try JSONEncoder().encode(profile)
        if saved(defaults)?.oracle != profile.oracle {
            defaults.set(oracleRevision(defaults) + 1, forKey: oracleRevisionKey)
        }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: didSave, object: defaults)
    }

    static let lastAgentsKey = "operator.lastBroadcastAgents"

    /// The last broadcast's Agents rows, which New Broadcast's Agents step starts from: none before a broadcast saved
    /// some, or when what is saved cannot be read.
    public static func lastAgents(_ defaults: UserDefaults = .standard) -> [AgentChoice] {
        guard let data = defaults.data(forKey: lastAgentsKey) else { return [] }
        return (try? JSONDecoder().decode([AgentChoice].self, from: data)) ?? []
    }

    /// Writes `rows` as the last broadcast's; an encoding failure throws and leaves what was saved before.
    public static func saveLastAgents(_ rows: [AgentChoice], _ defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(rows), forKey: lastAgentsKey)
    }

    /// Claude's default as `load` takes it: the model Settings › Agents makes Claude's default, or
    /// without one the first the catalogue lists, at that model's default reasoning; with no catalogue
    /// at all, Claude's own `opus` alias, which every install answers to.
    public static func claudeDefault(models: [AgentModel], defaults: UserDefaults = .standard) -> (model: String, reasoning: String?) {
        let preference = ModelSettings.resolve(for: .claude, catalog: models, defaults: defaults)
        return preference.model.isEmpty ? (fallbackModel, fallbackReasoning) : (preference.model, preference.reasoning)
    }

    static let fallbackModel = "opus"
    static let fallbackReasoning = "high"
}
