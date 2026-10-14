import Foundation

/// A failed operation, as the banner above the list says it: what happened, why, and the ways out.
/// The three parts `LocalizedError` keeps apart — description, failure reason, recovery — kept
/// apart here too, so no one joins them with `+` and loses a full stop between.
///
/// Its actions are cases, not closures: the app maps each to its call, so an issue stays
/// `Equatable` — a test asserts on it, and `@Observable` skips a repeat of the same one.
public struct OperationIssue: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Finish removing the task, leaving its branch.
        case keepBranch(UUID)
        /// Delete the task's branch with the commits only it has — after asking — then finish.
        case deleteBranch(UUID)
        /// Replay the project's local default branch on origin's, after a pull found them diverged.
        case rebaseDefault(UUID)

        public var title: String {
            switch self {
            case .keepBranch: "Keep Branch"
            case .deleteBranch: "Delete Branch…"
            case .rebaseDefault: "Rebase"
            }
        }
    }

    public var title: String
    public var reason: String? = nil
    public var actions: [Action] = []
    /// The task it is about. The banner goes when that task does: the question has gone with the row.
    public var subject: UUID? = nil
    /// Git's whole output, when git said more than `reason` keeps: the banner's tooltip. What a
    /// fix's agent reads is `FixRequest.detail` alone, which the prompt neutralises.
    public var detail: String? = nil
    /// The problem an agent can be asked to fix, offered as the banner's Fix (`FixSession`).
    public var fix: FixRequest? = nil

    public init(title: String, reason: String? = nil, actions: [Action] = [], subject: UUID? = nil,
                detail: String? = nil, fix: FixRequest? = nil) {
        self.title = title; self.reason = reason; self.actions = actions; self.subject = subject
        self.detail = detail; self.fix = fix
    }

    /// A failure and the error behind it: `title` is AiTerm's own sentence, and the error's goes in
    /// `reason`, by the one rule every report follows (`reason(of:)`); a git failure's command and
    /// whole stderr in `detail`, as New Review's footer has them — when git said anything.
    public init(title: String, error: Error, actions: [Action] = [], subject: UUID? = nil) {
        let detail = (error as? GitError).flatMap { git in
            git.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : "git \(git.args.joined(separator: " ")) failed:\n\(git.stderr)"
        }
        self.init(title: title, reason: Self.reason(of: error), actions: actions, subject: subject, detail: detail)
    }

    /// Whether the issue names a task or a project that `state` no longer has: the question has
    /// gone with it, and its actions would find nothing to act on.
    public func isStale(in state: AppState) -> Bool {
        if let subject, state.task(id: subject) == nil { return true }
        if case .pullDefault(let id)? = fix?.retry, state.project(id: id) == nil { return true }
        return actions.contains { action in
            switch action {
            case .keepBranch(let id), .deleteBranch(let id): state.task(id: id) == nil
            case .rebaseDefault(let id): state.project(id: id) == nil
            }
        }
    }

    /// An error as a sentence to show after AiTerm's own: git's failure lines tidied into one
    /// (`GitError.sentence`), and any other error's own description.
    public static func reason(of error: Error) -> String {
        GitError.displayReason(of: error)
    }

    /// The one sentence for an action that needs the daemon when there is none: `action` finishes
    /// "Try …", as the person would say it once AiTerm has reconnected.
    public static func disconnected(_ action: String) -> OperationIssue {
        OperationIssue(title: "Disconnected. Try \(action) once AiTerm reconnects.")
    }

    /// A removed task's branch that git would not delete. Only `.notMerged` offers Delete: `-D`
    /// answers commits the base lacks, not a refusal for any other reason.
    public static func branchKept(_ branch: String, of task: UUID, because refusal: TaskWorkflow.BranchRefusal) -> OperationIssue {
        switch refusal {
        case .notMerged(let base):
            OperationIssue(title: "Branch \(branch) kept.",
                           reason: "It has commits that aren’t on \(base.isEmpty ? "its base" : base).",
                           actions: [.keepBranch(task), .deleteBranch(task)], subject: task)
        case .other(let reason):
            OperationIssue(title: "Branch \(branch) kept.", reason: reason, actions: [.keepBranch(task)], subject: task)
        }
    }

    /// "Pull main" that found `project`'s default branch diverged: how far apart, the rebase, and a
    /// Fix in `projectPath`. Any other failure — the network, a login — is reported with its error
    /// and git's words, and offers no Fix: it is not the branch's history.
    public static func pullRefused(_ error: Error, in project: UUID, projectPath: String) -> OperationIssue {
        let title = "Couldn’t pull the default branch."
        guard case WorktreeError.branchDiverged(let branch, _, _) = error, let reason = (error as? LocalizedError)?.errorDescription else {
            return OperationIssue(title: title, error: error)
        }
        let full = reason + " " + rebaseOffer
        return OperationIssue(title: title, reason: full, actions: [.rebaseDefault(project)],
                              fix: FixRequest(title: title, reason: full, detail: nil, projectPath: projectPath, branch: branch,
                                              recreateRebase: false, retry: .pullDefault(project)))
    }

    /// The banner's Rebase of the default branch, refused. A conflict offers the Fix, with git's
    /// words, and its sentence drops “Rebase it by hand.”: the Fix is the way out now. The banner
    /// puts it back when no fix can help. Once the fix has landed, the pull runs again.
    public static func rebaseRefused(_ error: Error, in project: UUID, projectPath: String) -> OperationIssue {
        let title = "Couldn’t rebase the default branch."
        guard case WorktreeError.rebaseConflicted(let branch, let gitWords) = error else { return OperationIssue(title: title, error: error) }
        var sentence = reason(of: error)
        let ending = " " + WorktreeError.rebaseByHand
        if sentence.hasSuffix(ending) { sentence.removeLast(ending.count) }
        return OperationIssue(title: title, reason: sentence, detail: gitWords,
                              fix: FixRequest(title: title, reason: sentence, detail: gitWords, projectPath: projectPath, branch: branch,
                                              recreateRebase: true, retry: .pullDefault(project)))
    }

    /// What a Rebase offered for a diverged branch does, said after how far apart the two are — the
    /// banner's for the default branch, New Review's footer for a review's.
    public static let rebaseOffer = "Rebase puts yours on top of origin’s; nothing is pushed."
}
