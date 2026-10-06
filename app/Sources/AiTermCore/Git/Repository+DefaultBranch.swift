import Foundation

/// What ``Repository/pullDefaultBranch()`` found, each with the branch it is about.
public enum DefaultBranchPull: Equatable, Sendable {
    case upToDate(String)
    case fastForwarded(String, commits: Int)
    /// Local commits origin lacks, and nothing of origin's to take: left as it is.
    case ahead(String, commits: Int)
}

/// What ``Repository/rebaseDefaultBranch()`` left: the branch, and how many commits it now has that
/// origin lacks. Never pushed: that stays the person's to do.
public struct DefaultBranchRebase: Equatable, Sendable {
    public var branch: String, ahead: Int
    public init(branch: String, ahead: Int) { self.branch = branch; self.ahead = ahead }
}

/// The local default branch kept up with origin's: "Pull main", and the rebase a diverged pull offers.
extension Repository {
    /// "Pull main": the local default branch brought to origin's, fast-forward only. Checked
    /// out somewhere — usually the project's own checkout — it is merged there, so the files move
    /// with it and git refuses to overwrite uncommitted changes; checked out nowhere, only the ref
    /// moves. Ahead of origin it is left alone, and diverged it is refused: nothing here merges,
    /// rebases or resets.
    ///
    /// Unlike the fetch before a new worktree, this one's failure is thrown: pulling is the point.
    public func pullDefaultBranch() throws -> DefaultBranchPull {
        let (branch, local, remote) = try fetchDefaultBranch()
        if local == remote { return .upToDate(branch) }
        if try isAncestor(remote, of: local) { return .ahead(branch, commits: count(remote, local)) }
        guard try isAncestor(local, of: remote) else {
            throw WorktreeError.defaultBranchDiverged(branch, local: count(remote, local), remote: count(local, remote))
        }
        let commits = count(local, remote)
        if let holder = try checkoutsLessAbandonedScratch().first(where: { $0.branch == branch }) {
            // No autostash, whatever the config says: stashed, the changes git cannot put back end
            // as conflict markers in the files, and the merge still exits 0.
            try git.run(["merge", "--ff-only", "--no-autostash", "--quiet", remote], in: holder.path, timeout: GitRunner.checkoutTimeout)
        } else {
            try fastForward(branch)
        }
        return .fastForwarded(branch, commits: commits)
    }

    /// The answer to a diverged "Pull main": the local default branch's own commits replayed on
    /// origin's, with `git rebase` — which drops merge commits, so a branch merged locally arrives
    /// as its commits. Rebased where it is checked out, so the files move with it and git refuses
    /// uncommitted changes; checked out nowhere, in a checkout of its own outside `.worktrees/`
    /// (where the sidebar would pick it up), removed afterwards. That checkout is only scratch:
    /// making it runs no hook and fetches no LFS file. A conflict aborts the rebase and leaves the
    /// branch as it was. Nothing is pushed.
    public func rebaseDefaultBranch() throws -> DefaultBranchRebase {
        let (branch, _, remote) = try fetchDefaultBranch()
        if let holder = try checkoutsLessAbandonedScratch().first(where: { $0.branch == branch }) {
            try rebase(branch, onto: remote, in: holder.path)
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(Self.scratchPrefix + UUID().uuidString).path
            try git.run(["-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet", scratch, branch], in: path,
                        timeout: GitRunner.checkoutTimeout, environment: ["GIT_LFS_SKIP_SMUDGE": "1"])
            // One left behind is removed before the next pull or rebase (`checkoutsLessAbandonedScratch`).
            defer {
                Log.git.attempt("Removing the rebase checkout \(scratch)") {
                    try git.run(["worktree", "remove", "--force", scratch], in: path, timeout: GitRunner.checkoutTimeout)
                }
                Log.git.attempt("Pruning the worktrees of \(path)") { try git.run(["worktree", "prune"], in: path) }
            }
            try rebase(branch, onto: remote, in: scratch)
        }
        guard let local = sha("refs/heads/" + branch) else { throw WorktreeError.noLocalBranch(branch) }
        return DefaultBranchRebase(branch: branch, ahead: count(remote, local))
    }

    /// What names the checkouts `rebaseDefaultBranch` makes for itself in the temporary directory.
    private static let scratchPrefix = "aiterm-rebase-"

    /// Every checkout, once the rebase checkouts an app that died mid-rebase never removed are
    /// gone. Each is still registered with the branch checked out, so every `git checkout` of it
    /// fails, and the next pull would merge in there; they are removed before a pull or rebase
    /// looks for where the branch is. Listed once, and again only when there was one to remove.
    private func checkoutsLessAbandonedScratch() throws -> [Worktree] {
        let temporary = FileManager.default.temporaryDirectory.path
        let prefixes = Set([temporary, Worktree.resolved(temporary)].map { ($0.hasSuffix("/") ? $0 : $0 + "/") + Self.scratchPrefix })
        let listed = try worktrees()
        let abandoned = listed.filter { worktree in
            prefixes.contains { worktree.path.hasPrefix($0) || Worktree.resolved(worktree.path).hasPrefix($0) }
        }
        guard !abandoned.isEmpty else { return listed }
        for worktree in abandoned {
            Log.git.attempt("Removing the abandoned rebase checkout \(worktree.path)") {
                try git.run(["worktree", "remove", "--force", worktree.path], in: path, timeout: GitRunner.checkoutTimeout)
            }
        }
        Log.git.attempt("Pruning the worktrees of \(path)") { try git.run(["worktree", "prune"], in: path) }
        return try worktrees()
    }

    /// `git rebase` in `checkout`, aborted if it stops on a conflict. A rebase already under way
    /// there is someone else's: git refuses this one, and theirs is not aborted. What it does is
    /// pinned on the command line, since config can change each part of it: no autostash (see
    /// `pullDefaultBranch`), merges dropped, and no other branch moved along with the commits.
    private func rebase(_ branch: String, onto remote: String, in checkout: String) throws {
        let underWay = isRebasing(checkout)
        let pinned = ["--no-autostash", "--no-update-refs", "--no-rebase-merges"]
        do { try git.run(["rebase", "--quiet"] + pinned + [remote, branch], in: checkout, timeout: GitRunner.checkoutTimeout) }
        catch {
            guard !underWay, isRebasing(checkout) else { throw error }
            Log.git.attempt("Aborting the conflicted rebase of \(branch) in \(checkout)") {
                try git.run(["rebase", "--abort"], in: checkout, timeout: GitRunner.checkoutTimeout)
            }
            throw WorktreeError.rebaseConflicted(branch)
        }
    }

    /// Whether a rebase is stopped in `checkout`: git keeps its state in `rebase-merge` (or, for
    /// the old apply backend, `rebase-apply`) in that checkout's own git directory. A git that
    /// cannot say is read as no rebase: the caller then throws the failure it already has.
    private func isRebasing(_ checkout: String) -> Bool {
        guard let paths = try? git.run(["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge", "--git-path", "rebase-apply"],
                                       in: checkout) else { return false }
        return paths.split(separator: "\n").contains { FileManager.default.fileExists(atPath: String($0)) }
    }

    /// The default branch, fetched: its name, the local tip and origin's. An explicit refspec, so
    /// the tracking ref compared against is updated whatever `remote.origin.fetch` says.
    private func fetchDefaultBranch() throws -> (branch: String, local: String, remote: String) {
        guard try hasOrigin else { throw WorktreeError.noOrigin }
        let branch = try detectDefaultBranch() ?? Self.fallbackDefaultBranch
        try fetchFromOrigin(branch)
        guard let local = sha("refs/heads/" + branch) else { throw WorktreeError.noLocalBranch(branch) }
        guard let remote = sha("refs/remotes/origin/" + branch) else { throw WorktreeError.noOrigin }
        return (branch, local, remote)
    }
}
