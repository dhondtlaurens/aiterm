import Foundation

/// The New Review form's state. A sibling of `TaskDraft`, not a mode of it: a review names a
/// branch that already exists, so it has no base branch, no branch-name derivation and no ticket.
public struct ReviewDraft: AgentDraft, Equatable, Sendable {
    public private(set) var mr: MergeRequest?
    public private(set) var title = "", branch = ""
    public var agent: AgentKind, model: String, reasoning: String?
    public var promptText = ""
    private var titleEdited = false, branchEdited = false

    public init(mr: MergeRequest?, agent: AgentKind, model: String, reasoning: String?) {
        self.mr = mr; self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    public static func initial(project: Project, state: AppState,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               defaults: UserDefaults = .standard) -> ReviewDraft {
        let agent = state.lastAgentByProject[project.id] ?? .claude
        return initial(state: state, agent: agent, catalog: ModelCatalog.models(for: agent, home: home), defaults: defaults)
    }

    /// A draft for `agent`, its model chosen from `catalog` — which the caller has read already.
    public static func initial(state: AppState, agent: AgentKind, catalog: [AgentModel],
                               defaults: UserDefaults = .standard) -> ReviewDraft {
        let preference = Self.preference(for: agent, state: state, catalog: catalog, defaults: defaults)
        return ReviewDraft(mr: nil, agent: agent, model: preference.model, reasoning: preference.reasoning)
    }

    public mutating func apply(mr: MergeRequest?) {
        self.mr = mr
        guard let mr else { return }   // Clearing leaves both fields: they are still what you are reviewing.
        if !titleEdited { title = mr.title }
        if !branchEdited { branch = mr.sourceBranch }
    }

    /// Both setters guard against being handed what they already hold: SwiftUI writes a field's
    /// value back through its binding when editing begins and ends, not only when the text
    /// changes, so a click into another field would otherwise mark it hand-edited — and for the
    /// branch, would clear the merge request.
    public mutating func setTitle(_ t: String) {
        guard t != title else { return }
        title = t; titleEdited = true
    }

    /// Editing the branch drops the merge request: the `!4` chip is clickable, and above a branch
    /// that is not the merge request's source branch it would be a lie that navigates somewhere.
    public mutating func setBranch(_ b: String) {
        guard b != branch else { return }
        branch = b; branchEdited = true
        mr = nil
    }
}
