import Foundation

/// Git work runs on one user-initiated queue, away from presentation and the cooperative
/// executor. Creation and removal share it so mutations cannot race in one app.
public struct TaskWorkflow: Sendable {
    public struct Created: Sendable {
        public let task: TaskItem
        public let command: String?
        public let launchWarning: String?
        /// What copying the project's `.worktreeinclude` came to, for the app to say when something
        /// was left out.
        public let worktreeInclude: WorktreeInclude.Outcome
    }
    public struct Removed: Sendable {
        /// The checkout is gone. A failed branch deletion remains independently retryable.
        public let branchRefusal: BranchRefusal?
        /// Why a review's local branch was left in place: it holds work origin lacks, or that could
        /// not be ruled out. Nothing to retry — the review is removed — only something worth saying.
        public var keptBranch: ReviewBranchRelease.Kept? = nil
    }

    /// Why a removed task's branch is still there.
    public enum BranchRefusal: Sendable, Equatable {
        /// It has commits `base` lacks: git's "not fully merged".
        case notMerged(base: String)
        /// Anything else, in git's words (`GitError.sentence`).
        case other(reason: String)
    }

    private static let queue = DispatchQueue(label: "aiterm.task-workflows", qos: .userInitiated)
    /// Runs every git command of a creation, removal or pull. A test passes one that runs git without
    /// the developer's own configuration.
    private let git: any GitRunning
    public init(git: any GitRunning) { self.git = git }

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
        let git = git
        return try await BackgroundWork.run(on: Self.queue) {
            try AgentCommand.build(agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                                   prompt: prompt, worktreePath: task.worktreePath, git: git)
        }
    }

    /// Makes the checkout, then the agent command for it. A command that cannot be built is a
    /// launch warning, never a failure: it must not discard a real checkout.
    private func checkOut(_ draft: some AgentDraft & Sendable, prompt: String?,
                          _ make: @escaping @Sendable (any GitRunning) throws -> TaskCreator.Made) async throws -> Created {
        let git = git
        return try await BackgroundWork.run(on: Self.queue) {
            let made = try make(git), task = made.task
            do {
                let command = try AgentCommand.build(agent: draft.agent, model: draft.model, reasoning: draft.reasoning,
                                                     prompt: prompt, worktreePath: task.worktreePath, git: git)
                return Created(task: task, command: command, launchWarning: nil, worktreeInclude: made.worktreeInclude)
            } catch {
                return Created(task: task, command: nil, launchWarning: error.localizedDescription, worktreeInclude: made.worktreeInclude)
            }
        }
    }

    /// Whether removing the task's worktree without `force` would be refused for its uncommitted
    /// changes or untracked files.
    public func hasUnsavedWork(task: TaskItem, project: Project) async throws -> Bool {
        let git = git
        return try await BackgroundWork.run(on: Self.queue) {
            try Repository(project.path, git: git).hasUnsavedWork(at: task.worktreePath)
        }
    }

    public func remove(task: TaskItem, project: Project, deleteBranch: Bool, force: Bool) async throws -> Removed {
        let git = git
        return try await BackgroundWork.run(on: Self.queue) {
            let repository = Repository(project.path, git: git)
            // A review's branch is the merge request's: never deleted on request — a caller may ask and
            // simply not get it — but released by `releaseReviewBranch` below, which deletes only a
            // local copy with nothing origin lacks. The worktree is ours and is removed as a task's is.
            let deleteBranch = deleteBranch && task.kind != .review
            if FileManager.default.fileExists(atPath: task.worktreePath) {
                try repository.removeWorktree(at: task.worktreePath, deleteBranch: nil, force: force)
            } else {
                // Locked worktrees cannot be pruned until their lock is released. Refused for one
                // that is not locked, which is no reason to stop.
                _ = try? git.run(["worktree", "unlock", task.worktreePath], in: project.path, timeout: GitRunner.checkoutTimeout)
                try git.run(["worktree", "prune"], in: project.path)
            }
            if task.kind == .review {
                guard case .kept(let why) = repository.releaseReviewBranch(task.branch, target: task.baseBranch) else {
                    return Removed(branchRefusal: nil)
                }
                return Removed(branchRefusal: nil, keptBranch: why)
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
                    let merged = try repository.isMerged(task.branch, into: task.baseBranch)
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
        let git = git
        return try await BackgroundWork.run(on: Self.queue) {
            try Repository(project.path, git: git).pullDefaultBranch()
        }
    }

    /// The rebase a diverged pull offers, on the same queue.
    public func rebaseDefaultBranch(of project: Project) async throws -> DefaultBranchRebase {
        let git = git
        return try await BackgroundWork.run(on: Self.queue) {
            try Repository(project.path, git: git).rebaseDefaultBranch()
        }
    }

    /// `git branch -D`: the branch goes with the commits only it has. Only once someone has agreed
    /// to lose them, after `remove` refused with `.notMerged`.
    public func deleteUnmergedBranch(of task: TaskItem, in project: Project) async throws {
        let git = git
        try await BackgroundWork.run(on: Self.queue) {
            _ = try git.run(["branch", "-D", task.branch], in: project.path)
        }
    }
}
