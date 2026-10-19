import Foundation

/// A local merge end (spec §5): the accepted commit merged into the default branch of the project's own
/// checkout, with a merge commit (`--no-ff`), so the task stays one commit to read or revert. It stops at the
/// merge: nothing is pushed, ever; pushing the default branch is the person's.
public enum LocalMerge {
    /// Why nothing was merged, as `finish_task` answers it.
    public enum Refusal: Error, Equatable, LocalizedError {
        /// Tracked files changed or staged in the checkout: a merge would mix them into it, or stop halfway.
        case uncommittedChanges(String)
        /// The checkout is on another branch, or on none (`current` nil).
        case notOnDefaultBranch(String, current: String?, defaultBranch: String)
        /// The commit conflicts with the default branch: the merge was taken back.
        case conflicted(sha: String, defaultBranch: String)
        /// Something other than a full commit id, which git could read as a ref or an option.
        case invalidCommit(String)

        public var errorDescription: String? {
            switch self {
            case .uncommittedChanges(let path):
                return "The project’s checkout at \(path) has uncommitted changes, so AiTerm merged nothing: commit them or set them aside, then call finish_task again."
            case .notOnDefaultBranch(let path, let current, let defaultBranch):
                return "The project’s checkout at \(path) is on \(current ?? "no branch"), not \(defaultBranch), so AiTerm merged nothing: switch it to \(defaultBranch), then call finish_task again."
            case .conflicted(let sha, let defaultBranch):
                return "\(sha.prefix(7)) conflicts with \(defaultBranch) in the project’s checkout, so AiTerm merged nothing and left \(defaultBranch) as it was: have the task’s agent rebase onto \(defaultBranch), accept the new commit, then call finish_task again."
            case .invalidCommit(let sha):
                return "\(sha) is not a full commit id."
            }
        }
    }

    /// `sha` merged into `defaultBranch` in `repo`'s own checkout, which must be on that branch with no tracked
    /// change uncommitted; the merge commit. A commit already in the branch (a repeat after a lost answer) is
    /// merged again by nothing: the branch's tip is answered. A conflict is taken back with `merge --abort`.
    /// Never pushes.
    public static func merge(sha: String, into defaultBranch: String, in repo: Repository) async throws -> String {
        try await BackgroundWork.run { try mergeNow(sha: sha, into: defaultBranch, in: repo) }
    }

    private static func mergeNow(sha: String, into defaultBranch: String, in repo: Repository) throws -> String {
        let git = repo.git, path = repo.path
        guard sha.count >= 40, sha.allSatisfy(\.isHexDigit) else { throw Refusal.invalidCommit(sha) }
        // `symbolic-ref --quiet` exits 1 on a detached HEAD.
        let current = try git.ask(["symbolic-ref", "--quiet", "--short", "HEAD"], in: path, none: [1])
        guard let current, Repository.folded(Repository.shortBranch(current)) == Repository.folded(Repository.shortBranch(defaultBranch)) else {
            throw Refusal.notOnDefaultBranch(path, current: current, defaultBranch: defaultBranch)
        }
        // Untracked files stay where they are; git refuses itself to overwrite one.
        guard try git.run(["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=none"], in: path).isEmpty else {
            throw Refusal.uncommittedChanges(path)
        }
        if try repo.isAncestor(sha, of: "HEAD") { return try git.run(["rev-parse", "HEAD"], in: path) }
        do {
            // Hooks may run the project's checks, so the merge gets a checkout's deadline.
            try git.run(["merge", "--no-ff", "--no-edit", "--quiet", sha], in: path, timeout: GitRunner.checkoutTimeout)
        } catch let error as GitError where !error.timedOut {
            let merging = (try? git.ask(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: path, none: [1])) ?? nil
            if merging != nil {
                Log.git.attempt("Taking back the conflicted merge of \(sha.prefix(7)) in \(path)") { try git.run(["merge", "--abort"], in: path) }
                throw Refusal.conflicted(sha: sha, defaultBranch: defaultBranch)
            }
            throw error
        }
        return try git.run(["rev-parse", "HEAD"], in: path)
    }
}
