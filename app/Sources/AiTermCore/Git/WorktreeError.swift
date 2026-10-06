import Foundation

/// Why git work on a project's worktrees or default branch was refused, in words to show.
public enum WorktreeError: Error, Equatable, LocalizedError {
    case symlinkRefused(String), notARepository(String)
    /// A review's branch that git will not check out a second time, and where it already is.
    case branchCheckedOut(String, at: String)
    /// A review's local branch with commits origin lacks while origin has commits it lacks.
    case branchDiverged(String)
    case branchNotOnOrigin(String)
    /// A folder git does not know as a worktree, outside the project's `.worktrees/`.
    case notAWorktree(String)
    /// "Pull main" in a project with no `origin` to pull from.
    case noOrigin
    /// "Pull main" with no local branch of the default's name to bring up to date.
    case noLocalBranch(String)
    /// The local default branch with `local` commits origin lacks while origin has `remote` it lacks;
    /// either is `nil` when git could not count them.
    case defaultBranchDiverged(String, local: Int?, remote: Int?)
    /// Rebasing the default branch onto origin's stopped on a conflict, and was aborted.
    case rebaseConflicted(String)

    public var errorDescription: String? {
        switch self {
        case .symlinkRefused(let path): return "Refusing to create a worktree through the symlink at \(path)."
        case .notARepository(let path): return "\(path) is not a Git repository."
        case .branchCheckedOut(let branch, let path):
            return "“\(branch)” is checked out at \(path). Switch that checkout to another branch, then review it."
        case .branchDiverged(let branch):
            return "Your local “\(branch)” and origin’s have diverged. Reconcile them (pull or reset), then review it."
        case .branchNotOnOrigin(let branch):
            return "“\(branch)” is not on origin, so a review couldn’t push to it. A fork’s branch is not supported."
        case .notAWorktree(let path): return "\(path) is not a worktree of this project, so it was left in place."
        case .noOrigin: return "This project has no origin to pull from."
        case .noLocalBranch(let branch): return "There is no local “\(branch)” to bring up to date."
        case .defaultBranchDiverged(let branch, let local, let remote):
            return "Your local “\(branch)” has \(commits(local)) that \(local == 1 ? "isn’t" : "aren’t") on origin, "
                + "and origin has \(commits(remote)) it doesn’t."
        case .rebaseConflicted(let branch):
            return "Rebasing “\(branch)” onto origin’s hit a conflict, so it was left as it was. Rebase it by hand."
        }
    }
}

/// "1 commit", "3 commits": a count of commits, as the errors above say it — or just "commits" when
/// git could not count them.
private func commits(_ count: Int?) -> String { count.map { "\($0) \($0 == 1 ? "commit" : "commits")" } ?? "commits" }
