import Foundation

/// The New Review form's state. A sibling of `TaskDraft`, not a mode of it: a review names a
/// branch that already exists, so it has no base branch and no branch-name derivation. Its merge
/// request and its ticket fill each other: picking one looks the other up (`ReviewCreation`), and
/// what the lookup finds goes in through `found(mr:from:)` and `found(ticket:from:)`, which never
/// overwrite a field set by hand.
public struct ReviewDraft: AgentDraft, Equatable, Sendable {
    public private(set) var mr: MergeRequest?
    public private(set) var ticket: JiraTicket?
    public private(set) var title = "", branch = ""
    /// What the merge request or the ticket was found from — `JVS-5793`, `!545` — while it is the
    /// one the lookup put there: the sheet says so under the field. Nil for one picked by hand.
    public private(set) var mrFoundFrom: String?, ticketFoundFrom: String?
    public var agent: AgentKind, model: String, reasoning: String?
    public var promptText = ""
    /// Step 3's "Include ticket details": the reviewer reads the ticket with the merge request.
    public var appendTicket = true
    /// As `TaskDraft.copiesWorktreeInclude`. Only read when the review gets a worktree of its own:
    /// one that opens in the task that has its branch makes none.
    public var copiesWorktreeInclude = true
    private var titleEdited = false, branchEdited = false

    public init(mr: MergeRequest?, agent: AgentKind, model: String, reasoning: String?) {
        self.mr = mr; self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    /// A draft for `agent`, its model chosen from `catalog` — which the caller has read already.
    public static func initial(state: AppState, agent: AgentKind, catalog: [AgentModel],
                               defaults: UserDefaults) -> ReviewDraft {
        let preference = Self.preference(for: agent, state: state, catalog: catalog, defaults: defaults)
        return ReviewDraft(mr: nil, agent: agent, model: preference.model, reasoning: preference.reasoning)
    }

    /// The merge request picked or cleared by hand. A ticket found from the one before goes with it:
    /// this one's lookup finds its own.
    public mutating func apply(mr: MergeRequest?) {
        mrFoundFrom = nil
        if ticketFoundFrom != nil { ticket = nil; ticketFoundFrom = nil }
        setRequest(mr)
    }

    /// The ticket picked or cleared by hand. A merge request found from the one before goes with it,
    /// and the name and branch it filled. A review with no merge request takes its name from the ticket.
    public mutating func apply(ticket: JiraTicket?) {
        ticketFoundFrom = nil
        if mrFoundFrom != nil {
            mr = nil; mrFoundFrom = nil
            if !titleEdited { title = "" }
            if !branchEdited { branch = "" }
        }
        self.ticket = ticket
        if let ticket, mr == nil, !titleEdited { title = ticket.summary }
    }

    /// The merge request the ticket's lookup found, unless one was picked by hand: an empty field,
    /// or one an earlier lookup filled, takes it. A branch typed meanwhile is the person's: a request
    /// from another branch would sit above it as a lie, so it is refused.
    public mutating func found(mr: MergeRequest, from key: String) {
        guard self.mr == nil || mrFoundFrom != nil, !branchEdited || branch == mr.sourceBranch else { return }
        setRequest(mr)
        mrFoundFrom = key
    }

    /// The ticket the merge request's lookup found, on the same terms.
    public mutating func found(ticket: JiraTicket, from reference: String) {
        guard self.ticket == nil || ticketFoundFrom != nil else { return }
        self.ticket = ticket
        ticketFoundFrom = reference
    }

    private mutating func setRequest(_ mr: MergeRequest?) {
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
        mr = nil; mrFoundFrom = nil
    }
}
