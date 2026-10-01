import Foundation
import AiTermCore

/// A failed operation, as the banner above the list says it: what happened, why, and the ways out.
/// The three parts `LocalizedError` keeps apart — description, failure reason, recovery — kept
/// apart here too, so no one joins them with `+` and loses a full stop between.
///
/// Its actions are cases, not closures: the controller maps each to its call, so an issue stays
/// `Equatable` — a test asserts on it, and `@Observable` skips a repeat of the same one.
struct OperationIssue: Equatable {
    enum Action: Equatable {
        /// Finish removing the task, leaving its branch.
        case keepBranch(UUID)
        /// Delete the task's branch with the commits only it has — after asking — then finish.
        case deleteBranch(UUID)
        /// Replay the project's local default branch on origin's, after a pull found them diverged.
        case rebaseDefault(UUID)

        var title: String {
            switch self {
            case .keepBranch: "Keep Branch"
            case .deleteBranch: "Delete Branch…"
            case .rebaseDefault: "Rebase"
            }
        }
    }

    var title: String
    var reason: String? = nil
    var actions: [Action] = []
    /// The task it is about. The banner goes when that task does: the question has gone with the row.
    var subject: UUID? = nil

    init(title: String, reason: String? = nil, actions: [Action] = [], subject: UUID? = nil) {
        self.title = title; self.reason = reason; self.actions = actions; self.subject = subject
    }

    /// A failure and the error behind it: `title` is AiTerm's own sentence, and the error's goes in
    /// `reason`, by the one rule every report follows (`reason(of:)`).
    init(title: String, error: Error, actions: [Action] = [], subject: UUID? = nil) {
        self.init(title: title, reason: Self.reason(of: error), actions: actions, subject: subject)
    }

    /// Whether the issue names a task or a project that `state` no longer has: the question has
    /// gone with it, and its actions would find nothing to act on.
    func isStale(in state: AppState) -> Bool {
        if let subject, state.task(id: subject) == nil { return true }
        return actions.contains { action in
            switch action {
            case .keepBranch(let id), .deleteBranch(let id): state.task(id: id) == nil
            case .rebaseDefault(let id): state.project(id: id) == nil
            }
        }
    }

    /// An error as a sentence to show after AiTerm's own: git's failure lines tidied into one
    /// (`GitError.sentence`), and any other error's own description.
    static func reason(of error: Error) -> String {
        error is GitError ? GitError.sentence(of: error) : error.localizedDescription
    }

    /// A removed task's branch that git would not delete. Only `.notMerged` offers Delete: `-D`
    /// answers commits the base lacks, not a refusal for any other reason.
    static func branchKept(_ branch: String, of task: UUID, because refusal: TaskWorkflow.BranchRefusal) -> OperationIssue {
        switch refusal {
        case .notMerged(let base):
            OperationIssue(title: "Branch \(branch) kept.",
                           reason: "It has commits that aren’t on \(base.isEmpty ? "its base" : base).",
                           actions: [.keepBranch(task), .deleteBranch(task)], subject: task)
        case .other(let reason):
            OperationIssue(title: "Branch \(branch) kept.", reason: reason, actions: [.keepBranch(task)], subject: task)
        }
    }

    /// "Pull main" that found `project`'s default branch diverged: how far apart, and the rebase.
    static func pullRefused(_ error: Error, in project: UUID) -> OperationIssue {
        let title = "Couldn’t pull the default branch."
        guard case WorktreeError.defaultBranchDiverged = error, let reason = (error as? LocalizedError)?.errorDescription else {
            return OperationIssue(title: title, error: error)
        }
        return OperationIssue(title: title, reason: reason + " Rebase puts yours on top of origin’s; nothing is pushed.",
                              actions: [.rebaseDefault(project)])
    }
}
