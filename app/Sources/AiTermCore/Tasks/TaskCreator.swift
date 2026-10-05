import Foundation

public struct TaskDraft: AgentDraft, Equatable, Sendable {
    public var ticket: JiraTicket?
    /// The branch is kept as its two halves — the type the select shows and the name the field
    /// shows — so each can be changed without the other.
    public private(set) var title = "", branchType = BranchType.feat, branchName = ""
    public var baseBranch: String, agent: AgentKind, model: String, reasoning: String?
    public var promptText = "", appendTicket = true
    private var titleEdited = false, branchEdited = false, typeEdited = false

    public var branch: String { "\(branchType.rawValue)/\(branchName)" }

    /// The branch's worktree directory before a taken one is skipped (`TaskCreator.unused`, which
    /// the sheet applies): nothing while the name field is empty, rather than the type alone that
    /// `TaskCreator.worktreeSlug` falls back to for a bare `feat/`.
    public var worktreeSlug: String {
        branchName.trimmingCharacters(in: .whitespaces).isEmpty ? "" : TaskCreator.worktreeSlug(branch: branch)
    }

    /// A draft with no ticket and no title yet. `initial(project:state:git:)` is the one a sheet
    /// opens with; this one is for a caller that knows the base branch without asking git.
    public init(ticket: JiraTicket?, baseBranch: String, agent: AgentKind, model: String, reasoning: String?) {
        self.ticket = ticket; self.baseBranch = baseBranch; self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    public static func initial(project: Project, state: AppState, git: GitRunner,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               defaults: UserDefaults = .standard) -> TaskDraft {
        let agent = state.lastAgentByProject[project.id] ?? .claude
        return initial(project: project, state: state, git: git, agent: agent,
                       catalog: ModelCatalog.models(for: agent, home: home), defaults: defaults)
    }

    /// A draft for `agent`, its model chosen from `catalog` — which the caller has read already.
    public static func initial(project: Project, state: AppState, git: GitRunner, agent: AgentKind,
                               catalog: [AgentModel], defaults: UserDefaults = .standard) -> TaskDraft {
        let preference = Self.preference(for: agent, state: state, catalog: catalog, defaults: defaults)
        return TaskDraft(ticket: nil, baseBranch: Worktrees.defaultBranch(repo: project.path, git: git), agent: agent,
                         model: preference.model, reasoning: preference.reasoning)
    }

    /// Clearing the ticket keeps the type it chose: nothing else has a better idea of the work.
    public mutating func apply(ticket: JiraTicket?) {
        self.ticket = ticket
        if !titleEdited { title = ticket?.summary ?? title }
        if !typeEdited, let ticket { branchType = BranchType(issueType: ticket.issueType) }
        if !branchEdited { branchName = Worktrees.branchSlug(key: ticket?.key, summary: ticket?.summary ?? title) }
    }

    /// Both guard against being handed what they already hold: SwiftUI writes a `TextField`'s value
    /// back through its binding when editing begins and ends, not only when the text changes, so a
    /// click into another field would otherwise mark the branch hand-edited and stop it following
    /// the task name.
    public mutating func setTitle(_ t: String) {
        guard t != title else { return }
        title = t; titleEdited = true
        if !branchEdited { branchName = Worktrees.branchSlug(key: ticket?.key, summary: t) }
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

    /// The worktree directory for `branch`, less its type: `feat/login` works in `.worktrees/login`.
    public static func worktreeSlug(branch: String) -> String {
        let withoutPrefix = branch.split(separator: "/").dropFirst().joined(separator: "-")
        var slug = Worktrees.slug(withoutPrefix.isEmpty ? branch : withoutPrefix)
        // `Worktrees.slug` keeps ASCII letters and digits only, so a branch like `feat/日本語` or
        // `feat/--` can slug to nothing at all — and an empty slug would make the worktree path the
        // `.worktrees` directory itself, which git would then be asked to create a checkout in.
        // Fall back to the whole branch name, then to a random but valid directory name.
        if slug.isEmpty { slug = Worktrees.slug(branch) }
        if slug.isEmpty { slug = "task-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased() }
        return slug
    }

    /// A review's worktree directory, prefixed so a review and a task on related branches cannot
    /// collide on a path and so the directory says which it is.
    public static func reviewSlug(branch: String) -> String { "review-" + worktreeSlug(branch: branch) }

    /// `slug`, else the first of `slug-2`, `slug-3`… that is not already in `repo`'s worktree
    /// directory: dropping the type makes `feat/login` and `fix/login` want the same one. Create
    /// and the sheets' preview both ask this, so the directory named is the one made.
    public static func unused(_ slug: String, in repo: String) -> String {
        let directory = repo + "/" + Worktrees.directoryName + "/"
        var candidate = slug, n = 1
        while FileManager.default.fileExists(atPath: directory + candidate) { n += 1; candidate = "\(slug)-\(n)" }
        return candidate
    }

    /// Whether `title` names a task or review. Create refuses one that does not, and the sheets hold
    /// their first step on the same rule rather than letting it through to fail at the last.
    public static func isNamed(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func create(draft: TaskDraft, project: Project, git: GitRunner = GitRunner()) throws -> TaskItem {
        guard isNamed(draft.title) else { throw Failure.emptyTitle }
        guard !draft.model.isEmpty else { throw Failure.emptyModel }
        guard Worktrees.validateBranch(draft.branch, git: git) else { throw Failure.invalidBranch(draft.branch) }
        let slug = unused(worktreeSlug(branch: draft.branch), in: project.path)
        let path = try Worktrees.create(repo: project.path, slug: slug, branch: draft.branch, base: draft.baseBranch, git: git)
        return TaskItem(id: UUID(), projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path, baseBranch: draft.baseBranch,
                        jira: draft.ticket.map { JiraRef(key: $0.key, summary: $0.summary, url: $0.url) }, agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                        firstPrompt: draft.promptText.isEmpty ? nil : draft.promptText, appendTicket: draft.appendTicket, createdAt: Date(), windowId: nil)
    }

    public static func createReview(draft: ReviewDraft, project: Project, git: GitRunner = GitRunner()) throws -> TaskItem {
        guard isNamed(draft.title) else { throw Failure.emptyTitle }
        guard !draft.model.isEmpty else { throw Failure.emptyModel }
        guard !draft.branch.trimmingCharacters(in: .whitespaces).isEmpty,
              Worktrees.validateBranch(draft.branch, git: git) else { throw Failure.invalidBranch(draft.branch) }
        let slug = unused(reviewSlug(branch: draft.branch), in: project.path)
        let path = try Worktrees.checkout(repo: project.path, slug: slug, branch: draft.branch, git: git)
        return TaskItem(id: UUID(), projectId: project.id, title: draft.title, branch: draft.branch, worktreePath: path,
                        baseBranch: draft.mr?.targetBranch ?? "", jira: nil, kind: .review,
                        mr: draft.mr.map { MergeRequestRef(iid: $0.iid, title: $0.title, url: $0.url) },
                        agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                        firstPrompt: draft.promptText.isEmpty ? nil : draft.promptText, appendTicket: false,
                        createdAt: Date(), windowId: nil)
    }
}
