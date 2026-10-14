import Foundation

/// A fix's result as it landed: the branch, where it was, where it is, and the backup's name.
public struct FixLanding: Equatable, Sendable {
    public var branch: String, old: String, new: String
    /// The old tip's name for a person: `refs/aiterm/backup/<branch>`, not under `refs/heads`, so no
    /// branch picker lists it.
    public var backup: String { "aiterm/backup/" + branch }
}

extension Repository {
    /// Brings a checked fix from its clone into this repository — AiTerm's own git, no agent. The
    /// new commits are fetched under `refs/aiterm/fix/` (hooks off), the old tip is kept as
    /// `refs/aiterm/backup/<branch>`, then the branch moves only if it is still where the clone
    /// started: `update-ref <new> <old>` where it is checked out nowhere, a fast-forward or
    /// `reset --keep` in its clean checkout otherwise. Untracked and ignored files are never
    /// touched, and a refusal leaves the branch, the checkout and any earlier backup as they were.
    ///
    /// Run it on `TaskWorkflow`'s queue (`TaskWorkflow.landFix`): it moves a branch.
    public func landFix(from clone: FixClone) throws(FixRefusal) -> FixLanding {
        let branch = clone.branch, old = clone.startTip
        let temporary = "refs/aiterm/fix/" + branch, backup = "refs/aiterm/backup/" + branch
        do {
            try git.run(["-c", "core.hooksPath=/dev/null", "fetch", "-q", "--no-tags", clone.path,
                         "+refs/heads/\(branch):\(temporary)"], in: path, timeout: GitRunner.checkoutTimeout)
            defer { _ = try? git.run(["update-ref", "-d", temporary], in: path) }
            let new = try git.run(["rev-parse", "--verify", temporary + "^{commit}"], in: path)
            guard try commit("refs/heads/" + branch) == old else { throw FixRefusal.branchMovedMeanwhile(branch) }

            // Everything that can refuse comes before the first write.
            let holder = try worktrees().first { $0.branch == branch }
            if let holder {
                guard try git.run(["status", "--porcelain", "--untracked-files=no"], in: holder.path).isEmpty else {
                    throw FixRefusal.checkoutHasChanges(holder.path)
                }
                guard try git.run(["rev-parse", "HEAD"], in: holder.path) == old else { throw FixRefusal.branchMovedMeanwhile(branch) }
            }

            let earlierBackup = try commit(backup)
            try git.run(["update-ref", backup, old], in: path)
            do {
                if let holder {
                    if try isAncestor(old, of: new) {
                        try git.run(["merge", "--ff-only", "--no-autostash", "-q", new], in: holder.path, timeout: GitRunner.checkoutTimeout)
                    } else {
                        try git.run(["reset", "-q", "--keep", new], in: holder.path, timeout: GitRunner.checkoutTimeout)
                    }
                } else {
                    // Compare-and-swap: git moves the ref only if it still holds `old`.
                    do { try git.run(["update-ref", "refs/heads/" + branch, new, old], in: path) }
                    catch let error as GitError where !error.timedOut && (try? commit("refs/heads/" + branch)) != old {
                        throw FixRefusal.branchMovedMeanwhile(branch)
                    }
                }
            } catch {
                // Nothing landed, so the backup an earlier fix left is put back rather than replaced.
                if let earlierBackup { _ = try? git.run(["update-ref", backup, earlierBackup], in: path) }
                else { _ = try? git.run(["update-ref", "-d", backup], in: path) }
                throw error
            }
            return FixLanding(branch: branch, old: old, new: new)
        } catch let refusal as FixRefusal {
            throw refusal
        } catch {
            throw .cloneFailed(OperationIssue.reason(of: error))
        }
    }
}
