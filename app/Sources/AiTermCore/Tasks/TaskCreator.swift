import Foundation

public struct TaskDraft: AgentDraft, Equatable, Sendable {
    public var ticket: JiraTicket?
    /// The branch is kept as its two halves — the type the select shows and the name the field
    /// shows — so each can be changed without the other.
    public private(set) var title = "", branchType = BranchType.feat, branchName = ""
    public var baseBranch: String, agent: AgentKind, model: String, reasoning: String?
    public var promptText = "", appendTicket = true
    /// Whether the new worktree starts with what the project's `.worktreeinclude` selects: step 1's
    /// checkbox, ticked unless the person unticks it. `TaskCreator` reads the files again when it
    /// creates, so one made after the sheet opened still comes.
    public var copiesWorktreeInclude = true
    private var titleEdited = false, branchEdited = false, typeEdited = false

    public var branch: String { "\(branchType.rawValue)/\(branchName)" }

    /// The branch's worktree directory before a taken one is skipped (`BranchNaming.unused`, which
    /// the sheet applies): nothing while the name field is empty, rather than the type alone that
    /// `BranchNaming.worktreeSlug` falls back to for a bare `feat/`.
    public var worktreeSlug: String {
        branchName.trimmingCharacters(in: .whitespaces).isEmpty ? "" : BranchNaming.worktreeSlug(branch: branch)
    }

    /// A draft with no ticket and no title yet. `initial(project:state:git:agent:catalog:)` is the one a sheet
    /// opens with; this one is for a caller that knows the base branch without asking git.
    public init(ticket: JiraTicket?, baseBranch: String, agent: AgentKind, model: String, reasoning: String?) {
        self.ticket = ticket; self.baseBranch = baseBranch; self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    /// A draft for `agent`, its model chosen from `catalog` — which the caller has read already. The
    /// base branch is `defaultBranch` when the caller knows the project's — the checkout monitor
    /// reads it on every pass — and git's answer otherwise.
    public static func initial(project: Project, state: AppState, git: any GitRunning, agent: AgentKind,
                               catalog: [AgentModel], defaultBranch: String? = nil, defaults: UserDefaults = .standard) -> TaskDraft {
        let preference = Self.preference(for: agent, state: state, catalog: catalog, defaults: defaults)
        return TaskDraft(ticket: nil, baseBranch: defaultBranch ?? Repository(project.path, git: git).defaultBranch(), agent: agent,
                         model: preference.model, reasoning: preference.reasoning)
    }

    /// Clearing the ticket keeps the type it chose: nothing else has a better idea of the work.
    public mutating func apply(ticket: JiraTicket?) {
        self.ticket = ticket
        if !titleEdited { title = ticket?.summary ?? title }
        if !typeEdited, let ticket { branchType = BranchType(issueType: ticket.issueType) }
        if !branchEdited { branchName = BranchNaming.branchSlug(key: ticket?.key, summary: ticket?.summary ?? title) }
    }

    /// Both guard against being handed what they already hold: SwiftUI writes a `TextField`'s value
    /// back through its binding when editing begins and ends, not only when the text changes, so a
    /// click into another field would otherwise mark the branch hand-edited and stop it following
    /// the task name.
    public mutating func setTitle(_ t: String) {
        guard t != title else { return }
        title = t; titleEdited = true
        if !branchEdited { branchName = BranchNaming.branchSlug(key: ticket?.key, summary: t) }
    }

    /// The branch field's text: a name, or a whole branch whose known type prefix moves into the
    /// select — typing `fix/` is picking the type.
    public mutating func setBranch(_ b: String) {
        let split = BranchType.split(b)
        if let split { branchType = split.type; typeEdited = true }
        guard (split?.name ?? b) != branchName else { return }
        branchName = split?.name ?? b; branchEdited = true
    }

    public mutating func setBranchType(_ type: BranchType) {
        guard type != branchType else { return }
        branchType = type; typeEdited = true
    }
}

public enum TaskCreator {
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidBranch(String), emptyTitle, emptyModel
        public var errorDescription: String? {
            switch self {
            case .invalidBranch(let branch): return "“\(branch)” is not a valid Git branch name."
            case .emptyTitle: return "Enter a task name."
            case .emptyModel: return "Choose an available model."
            }
        }
    }

    /// Whether `title` names a task or review. Create refuses one that does not, and the sheets hold
    /// their first step on the same rule rather than letting it through to fail at the last.
    public static func isNamed(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A task or review made: its row, and what copying its `.worktreeinclude` came to — which the
    /// app says when something was left out. Never a failure of the create.
    public struct Made: Sendable {
        public let task: TaskItem
        public let worktreeInclude: WorktreeInclude.Outcome
    }

    public static func create(draft: TaskDraft, project: Project, reserved: Set<String> = [], git: any GitRunning) throws -> Made {
        guard isNamed(draft.title) else { throw Failure.emptyTitle }
        guard !draft.model.isEmpty else { throw Failure.emptyModel }
        guard BranchNaming.isValid(draft.branch, git: git) else { throw Failure.invalidBranch(draft.branch) }
        let slug = BranchNaming.unused(BranchNaming.worktreeSlug(branch: draft.branch), in: project.path, reserved: reserved)
        let repository = Repository(project.path, git: git)
        let path = try repository.addTaskWorktree(slug: slug, branch: draft.branch, base: draft.baseBranch)
        let task = TaskItem(id: UUID(), projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path, baseBranch: draft.baseBranch,
                            jira: draft.ticket.map { JiraRef(key: $0.key, summary: $0.summary, url: $0.url) }, agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                            firstPrompt: draft.promptText.isEmpty ? nil : draft.promptText, appendTicket: draft.appendTicket, createdAt: Date(), windowId: nil)
        return Made(task: task, worktreeInclude: copyIncludes(draft.copiesWorktreeInclude, from: repository, into: path))
    }

    public static func createReview(draft: ReviewDraft, project: Project, reserved: Set<String> = [], git: any GitRunning) throws -> Made {
        guard isNamed(draft.title) else { throw Failure.emptyTitle }
        guard !draft.model.isEmpty else { throw Failure.emptyModel }
        guard !draft.branch.trimmingCharacters(in: .whitespaces).isEmpty,
              BranchNaming.isValid(draft.branch, git: git) else { throw Failure.invalidBranch(draft.branch) }
        let slug = BranchNaming.unused(BranchNaming.reviewSlug(branch: draft.branch), in: project.path, reserved: reserved)
        let repository = Repository(project.path, git: git)
        let path = try repository.addReviewWorktree(slug: slug, branch: draft.branch)
        let task = TaskItem(id: UUID(), projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path,
                            baseBranch: draft.mr?.targetBranch ?? "", jira: nil, kind: .review,
                            mr: draft.mr.map { MergeRequestRef(iid: $0.iid, title: $0.title, url: $0.url) },
                            agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                            firstPrompt: draft.promptText.isEmpty ? nil : draft.promptText, appendTicket: false,
                            createdAt: Date(), windowId: nil)
        return Made(task: task, worktreeInclude: copyIncludes(draft.copiesWorktreeInclude, from: repository, into: path))
    }

    /// An operator's worker's worktree, made when AiTerm starts the task: a new branch from `start` — the
    /// default branch, or a stacked task's parent's accepted commit. A relaunch adopts what an earlier
    /// attempt left: the worktree it made for the branch, or the branch it made, checked out afresh.
    public static func checkOutWorker(_ task: TaskItem, project: Project, start: String, reserved: Set<String> = [],
                                      git: any GitRunning) throws -> Made {
        let repository = Repository(project.path, git: git)
        var checkedOut = task
        checkedOut.baseBranch = start
        if let earlier = try repository.worktrees().first(where: { $0.branch == task.branch && $0.path != project.path }) {
            checkedOut.worktreePath = earlier.path
            return Made(task: checkedOut, worktreeInclude: .complete)
        }
        let slug = BranchNaming.unused(BranchNaming.worktreeSlug(branch: task.branch), in: project.path, reserved: reserved)
        if try repository.commit("refs/heads/" + task.branch) != nil {
            checkedOut.worktreePath = project.path + "/" + Worktree.directoryName + "/" + slug
            try repository.restoreWorktree(at: checkedOut.worktreePath, branch: task.branch, kind: .task)
        } else {
            checkedOut.worktreePath = try repository.addTaskWorktree(slug: slug, branch: task.branch, base: start)
        }
        return Made(task: checkedOut, worktreeInclude: copyIncludes(true, from: repository, into: checkedOut.worktreePath))
    }

    /// An archived row's worktree back where it was, with what `.worktreeinclude` selects copied in
    /// again — never over a file already there — and the row windowless, owed its window.
    public static func restore(_ task: TaskItem, project: Project, git: any GitRunning) throws -> Made {
        let repository = Repository(project.path, git: git)
        try repository.restoreWorktree(at: task.worktreePath, branch: task.branch, kind: task.kind)
        var restored = task
        restored.windowId = nil
        return Made(task: restored, worktreeInclude: copyIncludes(true, from: repository, into: task.worktreePath))
    }

    /// What the project's `.worktreeinclude` selects, copied into the new worktree when the draft
    /// kept step 1's checkbox: after `git worktree add`, before the window opens, so the agent
    /// starts with the files.
    private static func copyIncludes(_ wanted: Bool, from repository: Repository, into worktree: String) -> WorktreeInclude.Outcome {
        wanted ? WorktreeInclude.copy(from: repository, into: worktree) : .complete
    }
}
