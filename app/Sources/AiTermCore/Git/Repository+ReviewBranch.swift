import Foundation

/// What ``Repository/releaseReviewBranch(_:target:)`` did with a review's local branch.
public enum ReviewBranchRelease: Equatable, Sendable {
    case deleted
    /// Kept, and why — it holds work that exists nowhere else, or that could not be ruled out.
    case kept(Kept)
    /// Absent, or with no origin to judge it against.
    case untouched

    /// Why a review's local branch was kept.
    public enum Kept: Equatable, Sendable {
        /// A worktree has it checked out, at this path.
        case checkedOut(at: String)
        /// Origin could not be asked, for git's reason.
        case originUnreachable(String)
        /// Origin's tip of the branch could not be fetched to compare against.
        case originNotFetched
        /// It has this many commits origin's branch lacks.
        case unpushed(commits: Int)
        /// Origin no longer has it, and its work is not on this target — `""` for a review that has
        /// none.
        case unmerged(target: String)
        /// git refused to delete it, for this reason.
        case notDeleted(String)
    }
}

/// A removed review's local branch let go of, when that loses nothing.
extension Repository {
    /// The local branch a removed review leaves behind, deleted when that loses nothing: every
    /// commit on it is on origin's branch, or — once GitLab has deleted that after a merge — in
    /// `target`, the branch the merge request landed on. Otherwise it is kept, with the reason.
    /// Origin's branch is never touched, and without an origin there is nothing to judge by.
    ///
    /// Origin is asked directly (`ls-remote`), never through `refs/remotes/origin/*`: those are
    /// whatever the last fetch saw. A branch deleted or force-pushed on origin since would still
    /// vouch for commits origin no longer has — and the next prune would take the only other copy.
    /// So a branch origin confirms it lacks is judged against the target, and if origin cannot be
    /// asked at all (offline, refused credentials) the branch is kept: that proves nothing either way.
    public func releaseReviewBranch(_ branch: String, target: String) -> ReviewBranchRelease {
        guard hasOrigin, let local = sha("refs/heads/" + branch) else { return .untouched }
        if let holder = (try? worktrees())?.first(where: { $0.branch == branch }) {
            return .kept(.checkedOut(at: holder.path))
        }
        let onOrigin: [String: String]
        do { onOrigin = try originHeads([branch, target].filter { !$0.isEmpty }) }
        catch { return .kept(.originUnreachable(GitError.reason(of: error))) }
        if let remote = onOrigin[branch] {
            guard fetched(remote, branch: branch) else { return .kept(.originNotFetched) }
            guard !isAncestor(local, of: remote) else { return delete(branch) }
            return .kept(.unpushed(commits: count(remote, local)))
        }
        // Origin no longer has the branch. Its commits are safe only where they still live: on the
        // target as origin has it now, or on a local branch of that name — never a cached copy.
        let retained = !target.isEmpty && target != branch && (
            onOrigin[target].map { fetched($0, branch: target) && isAncestor(local, of: $0) } == true
                || sha("refs/heads/" + target).map { isAncestor(local, of: $0) } == true)
        guard retained else { return .kept(.unmerged(target: target)) }
        return delete(branch)
    }

    /// What origin has for each of `branches` right now: a name absent from the answer is a branch
    /// origin confirms it does not have. Throws when origin could not be asked.
    private func originHeads(_ branches: [String]) throws -> [String: String] {
        let refs = branches.map { "refs/heads/" + $0 }
        var heads: [String: String] = [:]
        for line in try git.runRemote(["ls-remote", "origin"] + refs, in: path).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            // `ls-remote` matches a pattern against the tail of a ref name; only the exact ref counts.
            guard fields.count == 2, let i = refs.firstIndex(of: fields[1]) else { continue }
            heads[branches[i]] = fields[0]
        }
        return heads
    }

    /// Whether `commit` — the tip origin reported for `branch` — is here to compare against,
    /// fetching the branch when it is not. The tracking ref is updated too, forced: it may be the
    /// stale value that was about to be trusted.
    private func fetched(_ commit: String, branch: String) -> Bool {
        if sha(commit) != nil { return true }
        try? fetchFromOrigin(branch)
        return sha(commit) != nil
    }

    /// `-D` because the question `-d` asks — merged into HEAD or the upstream — is not the one
    /// answered above, and the project's checkout is usually on some other branch.
    private func delete(_ branch: String) -> ReviewBranchRelease {
        do { try git.run(["branch", "-D", branch], in: path); return .deleted }
        catch { return .kept(.notDeleted(GitError.reason(of: error))) }
    }
}
