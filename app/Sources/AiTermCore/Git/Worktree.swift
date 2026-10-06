import Foundation

/// One entry of `git worktree list --porcelain`. `lockReason` is `nil` for an unlocked worktree and
/// `""` for one locked without a reason (git prints a bare `locked` line for that).
public struct Worktree: Equatable, Sendable {
    public var path: String, branch: String?, lockReason: String?
    public init(path: String, branch: String?, lockReason: String?) {
        self.path = path; self.branch = branch; self.lockReason = lockReason
    }

    /// The folder in a project that AiTerm's worktrees live in.
    public static let directoryName = ".worktrees"

    /// The lock reason a task's worktree is made with. A refused removal restores it verbatim.
    public static let taskLockReason = "aiterm task"
    /// The lock reason a review's worktree is made with. It is the only thing on disk that
    /// distinguishes a review's worktree from a task's, so `managedWorktrees` reports it and
    /// `removeWorktree` preserves it — losing it would make a re-imported review a task, and a
    /// task's branch is deletable.
    public static let reviewLockReason = "aiterm review"

    /// Which kind a task imported from this worktree is. This is the whole reason
    /// `managedWorktrees()` reports a lock reason: removing a project leaves its worktrees on disk,
    /// so re-adding it re-imports them, and an import that guessed `.task` for a review would hand
    /// the Remove alert an "Also delete branch" checkbox over a merge request's branch — the one
    /// thing this app must never do.
    ///
    /// The lock reason a review's worktree is made with is the authority. The `review-` directory
    /// prefix is a weaker fallback for a worktree whose lock was dropped by hand or lost in a copy
    /// of the repository; it can mislabel a task on a branch like `feat/review-dashboard`, which
    /// costs that task its delete-branch checkbox and nothing else. The costs are not symmetric.
    public var importedKind: TaskKind? {
        if lockReason == Self.reviewLockReason { return .review }
        return URL(fileURLWithPath: path).lastPathComponent.hasPrefix("review-") ? .review : nil
    }

    /// `git worktree list --porcelain`: blank-line-separated records of `worktree <path>`,
    /// `branch refs/heads/<name>` and `locked <reason>` — or a bare `locked` when the lock carries none.
    static func parse(porcelain listing: String) -> [Worktree] {
        var out: [Worktree] = [], current: Worktree?
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { current = Worktree(path: String(line.dropFirst(9)), branch: nil, lockReason: nil) }
            else if line.hasPrefix("branch ") {
                let ref = line.dropFirst(7)
                current?.branch = String(ref.hasPrefix("refs/heads/") ? ref.dropFirst("refs/heads/".count) : ref)
            }
            else if line == "locked" { current?.lockReason = "" }
            else if line.hasPrefix("locked ") { current?.lockReason = String(line.dropFirst(7)) }
            else if line.isEmpty, let done = current { out.append(done); current = nil }
        }
        if let current { out.append(current) }
        return out
    }

    /// `path` with its symlinks resolved, which is how two names for one worktree are compared.
    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
}
