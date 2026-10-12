import Foundation

/// A project's worktrees: listed, made for a task or a review under `.worktrees/`, and removed.
extension Repository {
    /// Every worktree git lists for the repository, its own checkout first.
    public func worktrees() throws -> [Worktree] {
        Worktree.parse(porcelain: try git.run(["worktree", "list", "--porcelain"], in: path))
    }

    /// Every worktree that lives under `.worktrees/` and has a branch, with the lock reason git
    /// records for it. The reason matters: a review's worktree is locked with
    /// ``Worktree/reviewLockReason`` where a task's has ``Worktree/taskLockReason``, and that is the
    /// only thing on disk that says which kind a worktree is — so an import that threw it away would
    /// turn a review back into a task, whose branch the app is willing to delete.
    public func managedWorktrees() throws -> [Worktree] {
        let prefix = Worktree.resolved(path) + "/" + Worktree.directoryName + "/"
        return try worktrees().filter { $0.branch != nil && Worktree.resolved($0.path).hasPrefix(prefix) }
    }

    /// The reason the worktree at `worktreePath` is locked with. `nil` when it is unlocked or unknown
    /// to git, `""` when it is locked without a reason.
    func lockReason(of worktreePath: String) -> String? {
        (Log.git.attempt("Listing the worktrees of \(path)") { try worktree(at: worktreePath) } ?? nil)?.lockReason
    }

    /// The worktree git lists at `worktreePath`, whatever symlinks either path goes through; `nil`
    /// when git lists none there.
    func worktree(at worktreePath: String) throws -> Worktree? {
        let wanted = Worktree.resolved(worktreePath)
        return try worktrees().first { Worktree.resolved($0.path) == wanted }
    }

    /// A task's worktree on a new `branch` from `base` — origin's when there is one — locked as
    /// the task's from the moment git makes it.
    ///
    /// A `worktree add` that fails can still leave a worktree behind: git keeps the checkout when
    /// only its `post-checkout` hook failed, and keeps it *locked*, since the lock is part of the
    /// add. Nothing may assume git cleaned up after a failed add. The same holds for a review's.
    public func addTaskWorktree(slug: String, branch: String, base: String) throws -> String {
        let hasOrigin = try hasOrigin
        let worktreePath = try prepareWorktree(slug: slug)
        // Best-effort, so a new worktree starts from the remote's latest when it can: offline, it
        // starts from what was last fetched. Whether origin has the base at all is not: a git that
        // cannot say has not said no, and the local base can be far behind origin's.
        if hasOrigin { Log.git.attempt("Fetching \(base) before adding a worktree", level: .default) { try fetchFromOrigin(base) } }
        let start = try hasOrigin && commit("refs/remotes/origin/" + base) != nil ? "origin/\(base)" : base
        try git.run(["worktree", "add", "--lock", "--reason", Worktree.taskLockReason, "-b", branch, worktreePath, start], in: path,
                    timeout: GitRunner.checkoutTimeout)
        return worktreePath
    }

    /// A review's worktree, on the branch itself, so the reviewer can commit its fixes and push them.
    ///
    /// The branch is brought to what origin has first: a local branch is whatever was last pulled,
    /// and the fetch never moves it. Behind origin, it is fast-forwarded; ahead, its unpushed commits
    /// are kept; diverged, it is refused rather than moved, with how far apart the two are — the
    /// sheet offers `rebaseOntoOrigin` for it. Checked out somewhere, it is refused with where — and
    /// in the project's own folder, with what `switchProjectFolder` would do. Only on origin, it gets a local branch
    /// tracking origin's, which `releaseReviewBranch` takes back once the review is removed. Every
    /// refusal comes before anything is created, and no failure path deletes a branch that holds
    /// anything origin lacks — this one is someone's merge request.
    public func addReviewWorktree(slug: String, branch: String) throws -> String {
        let prepared = try prepareReviewBranch(branch)
        let worktreePath = try prepareWorktree(slug: slug)
        try addWorktree(at: worktreePath, on: branch, lockReason: Worktree.reviewLockReason, fromOrigin: prepared.fromOrigin)
        if prepared.onOrigin { setUpstream(of: branch) }
        return worktreePath
    }

    /// A review's branch made ready to check out: fetched, then fast-forwarded when behind origin,
    /// kept when ahead, refused when diverged, checked out elsewhere, or on neither side. Whether the
    /// checkout must create it from origin's, and whether origin has it.
    private func prepareReviewBranch(_ branch: String) throws -> (fromOrigin: Bool, onOrigin: Bool) {
        let hasOrigin = try hasOrigin
        if hasOrigin { Log.git.attempt("Fetching \(branch) before adding a review", level: .default) { try fetchFromOrigin(branch) } }
        let local = sha("refs/heads/" + branch)
        let remote = hasOrigin ? sha("refs/remotes/origin/" + branch) : nil
        if let holder = try worktrees().first(where: { $0.branch == branch }) {
            throw try refusal(of: branch, checkedOutAt: holder.path)
        }
        switch (local, remote) {
        case (nil, nil): throw WorktreeError.branchNotOnOrigin(branch)
        case let (l?, r?) where l != r:
            // Ahead: origin's tip is in it, and its unpushed commits are kept as they are.
            if try isAncestor(r, of: l) { break }
            guard try isAncestor(l, of: r) else { throw WorktreeError.branchDiverged(branch, local: count(r, l), remote: count(l, r)) }
            // Behind: a fast-forward, which git refuses for a branch being rebased in some checkout.
            try fastForward(branch)
        default: break
        }
        return (local == nil, remote != nil)
    }

    /// `git worktree add`, locked with `lockReason`: on `branch`, or on a new `branch` from origin's.
    private func addWorktree(at worktreePath: String, on branch: String, lockReason: String, fromOrigin: Bool) throws {
        try git.run(["worktree", "add", "--lock", "--reason", lockReason]
                    + (fromOrigin ? ["-b", branch, worktreePath, "origin/" + branch] : [worktreePath, branch]), in: path,
                    timeout: GitRunner.checkoutTimeout)
    }

    /// So that a plain `git push` lands on origin's branch. Written as config rather than asked of
    /// `--track` or `--set-upstream-to`, which refuse an `origin/<branch>` that `remote.origin.fetch`
    /// does not cover — a single-branch clone's. Best-effort: the checkout exists by now and works
    /// without an upstream — only a bare `git push` would need one — so a failed write must not fail
    /// the checkout and strand its worktree.
    private func setUpstream(of branch: String) {
        Log.git.attempt("Setting \(branch)'s upstream") {
            try git.run(["config", "branch.\(branch).remote", "origin"], in: path)
            try git.run(["config", "branch.\(branch).merge", "refs/heads/" + branch], in: path)
        }
    }

    /// Why a review cannot have `branch`, checked out at `holder`. The project's own folder can be
    /// switched to the default branch — unless that is the branch reviewed — so it says so, and
    /// whether changes there forbid it; any other checkout is only named.
    private func refusal(of branch: String, checkedOutAt holder: String) throws -> WorktreeError {
        guard Worktree.resolved(holder) == Worktree.resolved(path),
              case let target = try detectDefaultBranch() ?? Self.fallbackDefaultBranch, target != branch else {
            return .branchCheckedOut(branch, at: holder)
        }
        return .branchInProjectFolder(branch, at: holder, switchTo: target, hasChanges: try hasUnsavedWork(at: holder))
    }

    /// The project's own folder moved off a review's `branch` onto `target`, so the review can
    /// check `branch` out; the branch and its commits stay as they are. The files under the
    /// person's editor change with it, so only while the folder is still on `branch` — one someone
    /// has moved since has nothing to switch — and has no uncommitted changes, which `git switch`
    /// would carry along to `target`.
    public func switchProjectFolder(off branch: String, to target: String) throws {
        guard try worktree(at: path)?.branch == branch else { return }
        guard try !hasUnsavedWork(at: path) else {
            throw WorktreeError.branchInProjectFolder(branch, at: path, switchTo: target, hasChanges: true)
        }
        try git.run(["switch", "--quiet", "--no-guess", target], in: path, timeout: GitRunner.checkoutTimeout)
    }

    /// Whether `git worktree remove` would refuse `worktreePath` without `--force`: git's own check,
    /// asked ahead of it so the task's window can close before anything is deleted. `false` for a
    /// folder git does not know as a worktree — `git status` there would answer for the project's
    /// checkout.
    public func hasUnsavedWork(at worktreePath: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: worktreePath), try worktree(at: worktreePath) != nil else { return false }
        return try !git.run(["status", "--porcelain", "--ignore-submodules=none"], in: worktreePath).isEmpty
    }

    /// The worktree at `worktreePath` removed, and then `deleteBranch` with it when one is named —
    /// `-D` under `force`, else `-d`.
    public func removeWorktree(at worktreePath: String, deleteBranch: String?, force: Bool) throws {
        if let worktree = try worktree(at: worktreePath) {
            try removeRegistered(worktreePath, lockedWith: worktree.lockReason, force: force)
        } else {
            // A removal git gave up on halfway, retried: there is nothing left to unlock or refuse.
            try deleteLeftover(worktreePath)
        }
        // The checkout is gone either way, so a branch git refuses to delete must not skip the prune.
        defer { Log.git.attempt("Pruning the worktrees of \(path)") { try git.run(["worktree", "prune"], in: path) } }
        if let b = deleteBranch { try git.run(["branch", force ? "-D" : "-d", b], in: path) }
    }

    /// `lockReason` is the one git listed *before* unlocking: it is the only marker on disk that says
    /// whether this worktree is a review's, and a refused removal must put back what was there rather
    /// than stamping every survivor "aiterm task".
    private func removeRegistered(_ worktreePath: String, lockedWith lockReason: String?, force: Bool) throws {
        let reason = lockReason ?? Worktree.taskLockReason
        // Refused for a worktree that is not locked, which is no reason to stop.
        _ = try? git.run(["worktree", "unlock", worktreePath], in: path, timeout: GitRunner.checkoutTimeout)
        do { try git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktreePath], in: path, timeout: GitRunner.checkoutTimeout) }
        catch {
            // git drops its record of the worktree even when it cannot delete all of it — a process
            // still running there wrote files back — and every later `remove` then fails "is not a
            // working tree". The checkout is gone; what is left is files nothing tracks.
            if (try? worktree(at: worktreePath) == nil) == true { return try deleteLeftover(worktreePath) }
            // A refused removal leaves a live task; restore its protection from pruning.
            Log.git.attempt("Locking \(worktreePath) again after its removal was refused") {
                try git.run(["worktree", "lock", worktreePath] + (reason.isEmpty ? [] : ["--reason", reason]), in: path,
                            timeout: GitRunner.checkoutTimeout)
            }
            throw error
        }
    }

    /// What a half-finished removal left of a worktree git no longer knows. Only ever a folder under
    /// the project's `.worktrees/`, and never through a symlink: anywhere else, a folder git does not
    /// know is not AiTerm's to delete.
    private func deleteLeftover(_ worktreePath: String) throws {
        guard FileManager.default.fileExists(atPath: worktreePath) else { return }
        let parent = URL(fileURLWithPath: worktreePath).deletingLastPathComponent().path
        guard Worktree.resolved(parent) == Worktree.resolved(path + "/" + Worktree.directoryName),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: worktreePath)) == nil else {
            throw WorktreeError.notAWorktree(worktreePath)
        }
        try FileManager.default.removeItem(atPath: worktreePath)
    }

    private func prepareWorktree(slug: String) throws -> String {
        let worktreePath = path + "/" + Worktree.directoryName + "/" + slug
        try prepareWorktree(at: worktreePath)
        return worktreePath
    }

    /// Where a worktree goes, made ready for `git worktree add`: inside the project's `.worktrees/`,
    /// never through a symlink, with `.worktrees/` in the repository's exclude file so it does not
    /// show as untracked.
    private func prepareWorktree(at worktreePath: String) throws {
        let dir = path + "/" + Worktree.directoryName
        guard URL(fileURLWithPath: worktreePath).deletingLastPathComponent().path == dir else {
            throw WorktreeError.notAWorktree(worktreePath)
        }
        for p in [dir, worktreePath] where (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil {
            throw WorktreeError.symlinkRefused(p)
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let exclude = ExcludeFile.url(forWorktreeOrRepo: path, git: git) { try ExcludeFile.append(Worktree.directoryName + "/", to: exclude) }
    }

    /// What a task's worktree is on now: a task's checkout can have moved to another branch since it
    /// was created, and a detached one holds commits no branch may have.
    public func head(at worktreePath: String) throws -> WorktreeHead {
        guard FileManager.default.fileExists(atPath: worktreePath), let worktree = try worktree(at: worktreePath) else { return .missing }
        return worktree.branch.map(WorktreeHead.branch) ?? .detached
    }

    /// An archived row's worktree back at `worktreePath` — its own path, since an agent keeps its
    /// conversations by directory — on `branch`, locked as `kind`'s. A worktree already there on
    /// `branch` is the row's own leftover — an archive cut short after its row was saved, or a restore
    /// git gave up on — and is adopted; anything else there is refused and left as it is. The branch
    /// comes from origin's when the local one has gone; a review's is brought up to origin's first, as
    /// creating a review does.
    public func restoreWorktree(at worktreePath: String, branch: String, kind: TaskKind) throws {
        let lockReason = kind == .review ? Worktree.reviewLockReason : Worktree.taskLockReason
        if let existing = try worktree(at: worktreePath) {
            guard existing.branch == branch else { throw WorktreeError.pathTaken(worktreePath) }
            _ = try? git.run(["worktree", "unlock", worktreePath], in: path, timeout: GitRunner.checkoutTimeout)
            try git.run(["worktree", "lock", "--reason", lockReason, worktreePath], in: path, timeout: GitRunner.checkoutTimeout)
            return
        }
        guard !FileManager.default.fileExists(atPath: worktreePath) else { throw WorktreeError.pathTaken(worktreePath) }
        let fromOrigin: Bool, onOrigin: Bool
        if kind == .review {
            do { (fromOrigin, onOrigin) = try prepareReviewBranch(branch) }
            catch WorktreeError.branchNotOnOrigin { throw WorktreeError.branchGone(branch) }
        } else {
            if let holder = try worktrees().first(where: { $0.branch == branch }) {
                throw WorktreeError.branchCheckedOut(branch, at: holder.path)
            }
            fromOrigin = sha("refs/heads/" + branch) == nil
            if fromOrigin {
                guard try hasOrigin else { throw WorktreeError.branchGone(branch) }
                Log.git.attempt("Fetching \(branch) before restoring a task", level: .default) { try fetchFromOrigin(branch) }
                guard sha("refs/remotes/origin/" + branch) != nil else { throw WorktreeError.branchGone(branch) }
            }
            onOrigin = fromOrigin
        }
        try prepareWorktree(at: worktreePath)
        try addWorktree(at: worktreePath, on: branch, lockReason: lockReason, fromOrigin: fromOrigin)
        if onOrigin { setUpstream(of: branch) }
    }
}

/// What a worktree is on now: its branch, a detached head, or nothing — no worktree there.
public enum WorktreeHead: Equatable, Sendable {
    case branch(String), detached, missing
}
