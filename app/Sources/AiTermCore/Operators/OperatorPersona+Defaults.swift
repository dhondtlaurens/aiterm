import Foundation

public extension OperatorPersona {
    /// What the New operator sheet starts from. The lead is Claude in v1 (spec §3), on the model
    /// Settings › Agents makes Claude's default — or, without one, the first the catalogue lists —
    /// at that model's default effort; with no catalogue at all, Claude's `opus` alias. The second
    /// opinion is `SecondOpinion.standard`, from another model family; autonomy is Routine.
    ///
    /// The handle is the placeholder `operator`: the sheet asks the library for a unique one from
    /// the name (`OperatorLibrary.uniqueHandle`) before the first save.
    static func defaultNew(claudeModels: [AgentModel], defaults: UserDefaults = .standard) -> OperatorPersona {
        let preference = ModelSettings.resolve(for: .claude, catalog: claudeModels, defaults: defaults)
        let model = preference.model.isEmpty ? Self.fallbackModel : preference.model
        let effort = preference.model.isEmpty ? Self.fallbackEffort : preference.reasoning
        return OperatorPersona(
            name: "New operator", handle: "operator", model: model, effort: effort,
            secondOpinion: .standard, autonomy: .routine, alwaysAsk: [], limits: OperatorLimits(),
            persona: Self.starterPersona, lessons: [])
    }

    /// Claude's own alias for its strongest model, which every install answers to.
    static let fallbackModel = "opus"
    static let fallbackEffort = "high"

    /// A persona that already works, for you to rewrite: what the sheet's editor starts with.
    static let starterPersona = """
        You are a senior software engineer leading a small team of coding agents. You split work into \
        tasks a single agent can finish, keep each change small, and ask when a ticket leaves a product \
        choice open. You accept a task only when its checks pass and you have read its diff.
        """
}
