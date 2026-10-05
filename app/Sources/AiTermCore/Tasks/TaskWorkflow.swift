import Foundation

/// Git work runs on one user-initiated queue, away from presentation and the cooperative
/// executor. Creation and removal share it so mutations cannot race in one app.
public struct TaskWorkflow: Sendable {
    public struct Created: Sendable {
        public let task: TaskItem
        public let command: String?
        public let launchWarning: String?
    }
    public struct Removed: Sendable {
        /// The checkout is gone. A failed branch deletion remains independently retryable.
        public let branchRefusal: BranchRefusal?
        /// A review's local branch left in place because it holds work origin lacks. Nothing to
        /// retry — the review is removed — only something worth saying.
        public var keptBranch: String? = nil
    }

    /// Why a removed task's branch is still there.
    public enum BranchRefusal: Sendable, Equatable {
        /// It has commits `base` lacks: git's "not fully merged".
        case notMerged(base: String)
        /// Anything else, in git's words (`GitError.sentence`).
        case other(reason: String)
    }

    private static let queue = DispatchQueue(label: "aiterm.task-workflows", qos: .userInitiated)
    public init() {}

    public func create(draft: TaskDraft, project: Project) async throws -> Created {
        let prompt = AgentCommand.composePrompt(userText: draft.promptText, ticket: draft.ticket, appendTicket: draft.appendTicket)
        return try await checkOut(draft, prompt: prompt) { try TaskCreator.create(draft: draft, project: project, git: $0) }
    }

    public func createReview(draft: ReviewDraft, project: Project) async throws -> Created {
        // No ticket: a review's prompt is whatever was typed, and step 3 offers no "include
        // details" checkbox.
        let prompt = AgentCommand.composePrompt(userText: draft.promptText, ticket: nil, appendTicket: false)
        return try await checkOut(draft, prompt: prompt) { try TaskCreator.createReview(draft: draft, project: project, git: $0) }
    }

    /// The reviewer's command for a review that opens in `task`, which already has the branch
    /// checked out: no checkout is made, so nothing exists that a failure here would have to keep,
    /// and it is thrown rather than turned into a launch warning.
    public func reviewCommand(draft: ReviewDraft, in task: TaskItem) async throws -> String {
        let prompt = AgentCommand.composePrompt(userText: draft.promptText, ticket: nil, appendTicket: false)
        return try await BackgroundWork.run(on: Self.queue) {
            try AgentCommand.build(agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                                   prompt: prompt, worktreePath: task.worktreePath)
        }
    }

    /// Makes the checkout, then the agent command for it. A command that cannot be built is a
    /// launch warning, never a failure: it must not discard a real checkout.
    private func checkOut(_ draft: some AgentDraft & Sendable, prompt: String?,
                          _ make: @escaping @Sendable (GitRunner) throws -> TaskItem) async throws -> Created {
        try await BackgroundWork.run(on: Self.queue) {
            let task = try make(GitRunner())
            do {
                let command = try AgentCommand.build(agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                                                     prompt: prompt, worktreePath: task.worktreePath)
                return Created(task: task, command: command, launchWarning: nil)
            } catch {
                return Created(task: task, command: nil, launchWarning: error.localizedDescription)
            }
        }
    }

    /// Whether removing the task's worktree without `force` would be refused for its uncommitted
    /// changes or untracked files.
    public func hasUnsavedWork(task: TaskItem, project: Project) async throws -> Bool {
        try await BackgroundWork.run(on: Self.queue) {
            try Worktrees.hasUnsavedWork(repo: project.path, path: task.worktreePath, git: GitRunner())
        }
    }

    public func remove(task: TaskItem, project: Project, deleteBranch: Bool, force: Bool) async throws -> Removed {
        try await BackgroundWork.run(on: Self.queue) {
            let git = GitRunner()
            // A review's branch is the merge request's: never deleted on request — a caller may ask and
            // simply not get it — but released by `releaseReviewBranch` below, which deletes only a
            // local copy with nothing origin lacks. The worktree is ours and is removed as a task's is.
            let deleteBranch = deleteBranch && task.kind != .review
            if FileManager.default.fileExists(atPath: task.worktreePath) {
                try Worktrees.remove(repo: project.path, path: task.worktreePath, deleteBranch: nil, force: force, git: git)
            } else {
                // Locked worktrees cannot be pruned until their lock is released.
                _ = try? git.run(["worktree", "unlock", task.worktreePath], in: project.path, timeout: GitRunner.checkoutTimeout)
                try git.run(["worktree", "prune"], in: project.path)
            }
            if task.kind == .review {
                let release = Worktrees.releaseReviewBranch(repo: project.path, branch: task.branch, target: task.baseBranch, git: git)
                guard case .kept(let why) = release else { return Removed(branchRefusal: nil) }
                return Removed(branchRefusal: nil, keptBranch: "Branch \(task.branch) kept: \(why).")
            }
            guard deleteBranch else { return Removed(branchRefusal: nil) }
            do {
                // Already-deleted branches are a successful retry.
                let refs = try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + task.branch], in: project.path)
                if refs.split(separator: "\n").contains(Substring("refs/heads/" + task.branch)) {
                    // Force authorizes discarding checkout changes, never unmerged commits — so the
                    // question is only ever whether the commits survive somewhere else. `git branch -d`
                    // answers a narrower one, asking about HEAD and the branch's upstream, and the
                    // project's checkout is usually sitting on some other task's branch; that refused
                    // branches already merged into their base. Ask about the base ourselves, and `-D` is
                    // then no less safe than `-d`: the commits demonstrably live on in the base.
                    let merged = Worktrees.isMerged(branch: task.branch, into: task.baseBranch, repo: project.path, git: git)
                    // Not merged there: let git have the last word, and say what it says.
                    try git.run(["branch", merged ? "-D" : "-d", task.branch], in: project.path)
                }
                return Removed(branchRefusal: nil)
            } catch let error as GitError where error.stderr.contains("not fully merged") {
                return Removed(branchRefusal: .notMerged(base: task.baseBranch))
            } catch {
                return Removed(branchRefusal: .other(reason: GitError.sentence(of: error)))
            }
        }
    }

    /// "Pull main", on the queue creation and removal use: all three move branches.
    public func pullDefaultBranch(of project: Project) async throws -> DefaultBranchPull {
        try await BackgroundWork.run(on: Self.queue) {
            try Worktrees.pullDefaultBranch(repo: project.path, git: GitRunner())
        }
    }

    /// The rebase a diverged pull offers, on the same queue.
    public func rebaseDefaultBranch(of project: Project) async throws -> DefaultBranchRebase {
        try await BackgroundWork.run(on: Self.queue) {
            try Worktrees.rebaseDefaultBranch(repo: project.path, git: GitRunner())
        }
    }

    /// `git branch -D`: the branch goes with the commits only it has. Only once someone has agreed
    /// to lose them, after `remove` refused with `.notMerged`.
    public func deleteUnmergedBranch(of task: TaskItem, in project: Project) async throws {
        try await BackgroundWork.run(on: Self.queue) {
            _ = try GitRunner().run(["branch", "-D", task.branch], in: project.path)
        }
    }
}
