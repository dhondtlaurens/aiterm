import Foundation

/// Settings › Operator's profile, kept as JSON in UserDefaults under `operator.profile`. The Operator reads it for
/// its next session. Oracle changes also invalidate checks already running.
public enum OperatorProfileStore {
    static let key = "operator.profile"
    private static let oracleRevisionKey = "operator.oracleRevision"
    public static let didSave = Notification.Name("AiTerm.OperatorProfileSaved")

    public static func saved(_ defaults: UserDefaults) -> OperatorProfile? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(OperatorProfile.self, from: $0) }
    }

    public static func oracleRevision(_ defaults: UserDefaults) -> Int { defaults.integer(forKey: oracleRevisionKey) }

    /// The default Operator profile uses the standard Oracle and no standing instructions.
    public static func load(_ defaults: UserDefaults = .standard, claudeDefault: (model: String, reasoning: String?), installed: Set<AgentKind> = Set(AgentKind.allCases)) -> OperatorProfile {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(OperatorProfile.self, from: data) { return saved }
        var profile = OperatorProfile(model: claudeDefault.model, reasoning: claudeDefault.reasoning)
        profile.oracle.isOn = installed.contains(.codex)
        return profile
    }

    /// Writes `profile` and notifies its readers.
    public static func save(_ profile: OperatorProfile, _ defaults: UserDefaults = .standard) {
        // The profile is plain strings and bools.
        let data = try! JSONEncoder().encode(profile)
        if saved(defaults)?.oracle != profile.oracle {
            defaults.set(oracleRevision(defaults) + 1, forKey: oracleRevisionKey)
        }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: didSave, object: defaults)
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
