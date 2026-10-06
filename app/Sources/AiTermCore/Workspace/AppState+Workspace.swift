import Foundation

/// Where the saved workspace meets what git and the checkout monitor read off disk. Kept out of
/// `Models.swift` so the model names no type of the folders built on it.
extension AppState {
    /// The row in `projectId` whose worktree git reports `branch` checked out in — where a review
    /// of that branch opens, since git lets a branch be checked out in one worktree only. A task or
    /// an earlier review: whichever row that worktree belongs to.
    ///
    /// Decided by `worktrees` (`Repository.worktrees()`), never by `TaskItem.branch`: that is the branch a
    /// row is bound to, and its worktree can drift onto another one. Routing by the saved name would
    /// open a review of one branch in a checkout of another. `nil` when no row's worktree has the
    /// branch — including when the project's own checkout or an untracked worktree has it, which
    /// `Repository.addReviewWorktree` then refuses by path.
    public func task(checkingOut branch: String, in projectId: UUID, worktrees: [Worktree]) -> TaskItem? {
        guard !branch.isEmpty, let holder = worktrees.first(where: { $0.branch == branch }) else { return nil }
        let path = Worktree.resolved(holder.path)
        return tasks.first { $0.projectId == projectId && Worktree.resolved($0.worktreePath) == path }
    }

    /// Adopts each project's remote as the checkout monitor last read it, where it differs from the
    /// stored one: a remote added, changed or removed after the project was — `git remote add` in a
    /// terminal is not something the app can be told about, and the stored value is what the
    /// provider badge and every merge-request link are built from, so a stale one would outlive
    /// the change indefinitely. A project `detected` has no entry for is left as it is.
    public mutating func adoptRemotes(_ detected: [UUID: WorkspaceScan.Remote]) {
        for (id, found) in detected {
            updateProject(id: id) { project in
                guard project.provider != found.provider || project.remoteUrl != found.url else { return }
                project.provider = found.provider; project.remoteUrl = found.url
            }
        }
    }
}
