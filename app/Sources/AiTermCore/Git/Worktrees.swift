import Foundation

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
    /// The local default branch with `local` commits origin lacks while origin has `remote` it lacks.
    case defaultBranchDiverged(String, local: Int, remote: Int)
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

/// What `Worktrees.releaseReviewBranch` did with a review's local branch.
public enum ReviewBranchRelease: Equatable, Sendable {
    case deleted
    /// Kept, and why — it holds work that exists nowhere else.
    case kept(String)
    /// Absent, or with no origin to judge it against.
    case untouched
}

/// What `Worktrees.pullDefaultBranch` found, each with the branch it is about.
public enum DefaultBranchPull: Equatable, Sendable {
    case upToDate(String)
    case fastForwarded(String, commits: Int)
    /// Local commits origin lacks, and nothing of origin's to take: left as it is.
    case ahead(String, commits: Int)

    /// The toast that says it.
    public var summary: String {
        switch self {
        case .upToDate(let branch): "\(branch) is already up to date."
        case .fastForwarded(let branch, let count): "\(branch) updated with \(commits(count, adjective: "new"))."
        case .ahead(let branch, let count): "\(branch) is \(commits(count)) ahead of origin, so there was nothing to pull."
        }
    }
}

/// What `Worktrees.rebaseDefaultBranch` left: the branch, and how many commits it now has that origin lacks.
public struct DefaultBranchRebase: Equatable, Sendable {
    public var branch: String, ahead: Int
    public init(branch: String, ahead: Int) { self.branch = branch; self.ahead = ahead }

    /// The toast that says it. Never pushed: that stays the person's to do.
    public var summary: String {
        ahead == 0 ? "\(branch) rebased onto origin: it now matches origin."
            : "\(branch) rebased onto origin: \(commits(ahead)) ahead, not pushed."
    }
}

/// "1 commit", "3 new commits": a count of commits, as the toasts and errors above say it.
private func commits(_ count: Int, adjective: String? = nil) -> String {
    ([String(count)] + [adjective].compactMap { $0 } + [count == 1 ? "commit" : "commits"]).joined(separator: " ")
}

/// One entry of `git worktree list --porcelain`. `lockReason` is `nil` for an unlocked worktree and
/// `""` for one locked without a reason (git prints a bare `locked` line for that).
public struct Worktree: Equatable, Sendable {
    public var path: String, branch: String?, lockReason: String?
    public init(path: String, branch: String?, lockReason: String?) {
        self.path = path; self.branch = branch; self.lockReason = lockReason
    }
}

public enum Worktrees {
    public static let directoryName = ".worktrees"

    /// The lock reason `create` writes. A refused removal restores it verbatim.
    public static let taskLockReason = "aiterm task"
    /// The lock reason `checkout` writes. It is the only thing on disk that distinguishes a
    /// review's worktree from a task's, so `existing` reports it and `remove` preserves it —
    /// losing it would make a re-imported review a task, and a task's branch is deletable.
    public static let reviewLockReason = "aiterm review"

    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = "", lastDash = true
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 48 { out = String(out.prefix(48)); while out.hasSuffix("-") { out.removeLast() } }
        return out
    }

    /// The part of a task branch after its type: the ticket key, then the slugged summary.
    public static func branchSlug(key: String?, summary: String) -> String {
        [key?.lowercased(), slug(summary)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "-")
    }

    public static func toplevel(of path: String, git: any GitRunning) throws -> String? {
        do { return try git.run(["rev-parse", "--show-toplevel"], in: path) }
        catch let e as GitError where e.code == 128 { return nil }
    }

    /// The remote a project pushes to: the one the checked-out branch tracks, else `origin`, else the
    /// first there is; `nil` when the repository has none. That is git's answer. When git cannot be
    /// asked — it timed out, or did not start — this throws, since "no remote" would read as the
    /// project having lost its remote.
    public static func remoteUrl(repo: String, git: any GitRunning) throws -> String? {
        // 128 is "no upstream configured" (or a detached HEAD): the next steps ask again, and fail loudly.
        if let upstream = try git.ask(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repo, none: [128]),
           let remote = upstream.split(separator: "/").first,
           let url = try git.ask(["remote", "get-url", String(remote)], in: repo, none: [2]) { return url }
        if let url = try git.ask(["remote", "get-url", "origin"], in: repo, none: [2]) { return url }
        if let first = try git.run(["remote"], in: repo).split(separator: "\n").first {
            return try git.ask(["remote", "get-url", String(first)], in: repo, none: [2])
        }
        return nil
    }

    /// The name the project menu and a new task's base branch fall back to when a repository gives
    /// no default branch away.
    public static let fallbackDefaultBranch = "main"

    /// The default branch, or `nil` when the repository does not say: no usable `origin/HEAD` and
    /// none of the usual names. Throws when git cannot be asked, which says nothing either way.
    public static func detectDefaultBranch(repo: String, git: any GitRunning) throws -> String? {
        // One `for-each-ref` over every ref the answer can come from. It lists only refs that
        // resolve, which is exactly what is wanted: `origin/HEAD` names a branch only while origin
        // still has it — a rename on origin leaves the old name in a clone's `origin/HEAD` — and a
        // usual name counts only if it exists.
        let prefix = "refs/remotes/origin/"
        let usual = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        let listing = try git.run(["for-each-ref", "--format=%(refname) %(symref)", prefix + "HEAD"] + usual, in: repo)
        var existing = Set<String>(), originHead: String?
        for line in listing.split(separator: "\n") {
            // A ref name has no spaces; what follows the first is the symref's target, empty for a plain ref.
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            existing.insert(String(fields[0]))
            if fields[0] == prefix + "HEAD", fields.count == 2, fields[1].hasPrefix(prefix) { originHead = String(fields[1]) }
        }
        // The whole name after `origin/`: a default branch can have slashes in it.
        if let originHead { return String(originHead.dropFirst(prefix.count)) }
        // No usable `origin/HEAD` — a clone of an empty repository, a remote added by hand: whichever
        // of the usual names exists, origin's first.
        return usual.first(where: existing.contains).map { String($0.split(separator: "/").last!) }
    }

    /// ``detectDefaultBranch(repo:git:)``, or ``fallbackDefaultBranch`` when there is none or git
    /// cannot be asked — for a caller that must show some name and will be asked again.
    public static func defaultBranch(repo: String, git: any GitRunning) -> String {
        ((try? detectDefaultBranch(repo: repo, git: git)) ?? nil) ?? fallbackDefaultBranch
    }

    /// "Pull main": the local default branch brought to origin's, fast-forward only. Checked
    /// out somewhere — usually the project's own checkout — it is merged there, so the files move
    /// with it and git refuses to overwrite uncommitted changes; checked out nowhere, only the ref
    /// moves. Ahead of origin it is left alone, and diverged it is refused: nothing here merges,
    /// rebases or resets.
    ///
    /// Unlike the fetch before a new worktree, this one's failure is thrown: pulling is the point.
    public static func pullDefaultBranch(repo: String, git: any GitRunning) throws -> DefaultBranchPull {
        let (branch, local, remote) = try fetchDefaultBranch(repo: repo, git: git)
        if local == remote { return .upToDate(branch) }
        if isAncestor(remote, of: local, repo: repo, git: git) { return .ahead(branch, commits: count(remote, local, repo: repo, git: git)) }
        guard isAncestor(local, of: remote, repo: repo, git: git) else {
            throw WorktreeError.defaultBranchDiverged(branch, local: count(remote, local, repo: repo, git: git),
                                                      remote: count(local, remote, repo: repo, git: git))
        }
        let commits = count(local, remote, repo: repo, git: git)
        removeAbandonedScratch(repo: repo, git: git)
        if let holder = try holder(of: branch, repo: repo, git: git) {
            // No autostash, whatever the config says: stashed, the changes git cannot put back end
            // as conflict markers in the files, and the merge still exits 0.
            try git.run(["merge", "--ff-only", "--no-autostash", "--quiet", remote], in: holder.path, timeout: GitRunner.checkoutTimeout)
        } else {
            try fastForward(branch, repo: repo, git: git)
        }
        return .fastForwarded(branch, commits: commits)
    }

    /// `branch` brought to `origin/<branch>` where no checkout lists it: a fetch from the repository
    /// into itself, not `update-ref`. A branch mid-rebase or mid-bisect is listed nowhere — that
    /// checkout's HEAD is detached — and git's fetch refuses such a branch as it refuses a checked-out
    /// one. The refspec is not forced, so anything but a fast-forward of the ref as it is now, a
    /// concurrent change included, is refused too.
    private static func fastForward(_ branch: String, repo: String, git: any GitRunning) throws {
        try git.run(["fetch", "--quiet", "--no-write-fetch-head", "--no-prune", "--no-recurse-submodules", ".",
                     "refs/remotes/origin/\(branch):refs/heads/\(branch)"], in: repo)
    }

    /// The answer to a diverged "Pull main": the local default branch's own commits replayed on
    /// origin's, with `git rebase` — which drops merge commits, so a branch merged locally arrives
    /// as its commits. Rebased where it is checked out, so the files move with it and git refuses
    /// uncommitted changes; checked out nowhere, in a checkout of its own outside `.worktrees/`
    /// (where the sidebar would pick it up), removed afterwards. That checkout is only scratch:
    /// making it runs no hook and fetches no LFS file. A conflict aborts the rebase and leaves the
    /// branch as it was. Nothing is pushed.
    public static func rebaseDefaultBranch(repo: String, git: any GitRunning) throws -> DefaultBranchRebase {
        let (branch, _, remote) = try fetchDefaultBranch(repo: repo, git: git)
        removeAbandonedScratch(repo: repo, git: git)
        if let holder = try holder(of: branch, repo: repo, git: git) {
            try rebase(branch, onto: remote, in: holder.path, git: git)
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(scratchPrefix + UUID().uuidString).path
            try git.run(["-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet", scratch, branch], in: repo,
                        timeout: GitRunner.checkoutTimeout, environment: ["GIT_LFS_SKIP_SMUDGE": "1"])
            defer {
                _ = try? git.run(["worktree", "remove", "--force", scratch], in: repo, timeout: GitRunner.checkoutTimeout)
                _ = try? git.run(["worktree", "prune"], in: repo)
            }
            try rebase(branch, onto: remote, in: scratch, git: git)
        }
        guard let local = sha("refs/heads/" + branch, repo: repo, git: git) else { throw WorktreeError.noLocalBranch(branch) }
        return DefaultBranchRebase(branch: branch, ahead: count(remote, local, repo: repo, git: git))
    }

    /// What names the checkouts `rebaseDefaultBranch` makes for itself in the temporary directory.
    private static let scratchPrefix = "aiterm-rebase-"

    /// The rebase checkouts an app that died mid-rebase never removed. Each is still registered with
    /// the branch checked out, so every `git checkout` of it fails, and the next pull would merge in
    /// there; they are removed before the next pull or rebase looks for where the branch is.
    private static func removeAbandonedScratch(repo: String, git: any GitRunning) {
        let temporary = FileManager.default.temporaryDirectory.path
        let prefixes = Set([temporary, resolved(temporary)].map { ($0.hasSuffix("/") ? $0 : $0 + "/") + scratchPrefix })
        let abandoned = ((try? listed(repo: repo, git: git)) ?? []).filter { worktree in
            prefixes.contains { worktree.path.hasPrefix($0) || resolved(worktree.path).hasPrefix($0) }
        }
        guard !abandoned.isEmpty else { return }
        for worktree in abandoned {
            _ = try? git.run(["worktree", "remove", "--force", worktree.path], in: repo, timeout: GitRunner.checkoutTimeout)
        }
        _ = try? git.run(["worktree", "prune"], in: repo)
    }

    /// `git rebase` in `checkout`, aborted if it stops on a conflict. A rebase already under way
    /// there is someone else's: git refuses this one, and theirs is not aborted. What it does is
    /// pinned on the command line, since config can change each part of it: no autostash (see
    /// `pullDefaultBranch`), merges dropped, and no other branch moved along with the commits.
    private static func rebase(_ branch: String, onto remote: String, in checkout: String, git: any GitRunning) throws {
        let underWay = isRebasing(checkout, git: git)
        let pinned = ["--no-autostash", "--no-update-refs", "--no-rebase-merges"]
        do { try git.run(["rebase", "--quiet"] + pinned + [remote, branch], in: checkout, timeout: GitRunner.checkoutTimeout) }
        catch {
            guard !underWay, isRebasing(checkout, git: git) else { throw error }
            _ = try? git.run(["rebase", "--abort"], in: checkout, timeout: GitRunner.checkoutTimeout)
            throw WorktreeError.rebaseConflicted(branch)
        }
    }

    /// Whether a rebase is stopped in `checkout`: git keeps its state in `rebase-merge` (or, for
    /// the old apply backend, `rebase-apply`) in that checkout's own git directory.
    private static func isRebasing(_ checkout: String, git: any GitRunning) -> Bool {
        guard let paths = try? git.run(["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge", "--git-path", "rebase-apply"],
                                       in: checkout) else { return false }
        return paths.split(separator: "\n").contains { FileManager.default.fileExists(atPath: String($0)) }
    }

    /// The default branch, fetched: its name, the local tip and origin's. An explicit refspec, so
    /// the tracking ref compared against is updated whatever `remote.origin.fetch` says.
    private static func fetchDefaultBranch(repo: String, git: any GitRunning) throws -> (branch: String, local: String, remote: String) {
        guard (try? git.run(["remote", "get-url", "origin"], in: repo)) != nil else { throw WorktreeError.noOrigin }
        let branch = try detectDefaultBranch(repo: repo, git: git) ?? fallbackDefaultBranch
        try git.runRemote(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], in: repo)
        guard let local = sha("refs/heads/" + branch, repo: repo, git: git) else { throw WorktreeError.noLocalBranch(branch) }
        guard let remote = sha("refs/remotes/origin/" + branch, repo: repo, git: git) else { throw WorktreeError.noOrigin }
        return (branch, local, remote)
    }

    /// The checkout that has `branch` checked out, usually the project's own; nil when none does.
    private static func holder(of branch: String, repo: String, git: any GitRunning) throws -> Worktree? {
        try listed(repo: repo, git: git).first { $0.branch == branch }
    }

    /// How many commits `to` has that `from` lacks.
    private static func count(_ from: String, _ to: String, repo: String, git: any GitRunning) -> Int {
        Int((try? git.run(["rev-list", "--count", from + ".." + to], in: repo)) ?? "") ?? 0
    }

    /// Every branch the base-branch popup can offer: local branches most-recently-committed first,
    /// then branches that exist only on `origin` (offered under their short name, because that is
    /// what `git worktree add` resolves). The repository's default branch is always first, even
    /// when it has not been touched in months.
    public static func branches(repo: String, git: any GitRunning) -> [String] {
        // One listing of both, newest first within each: the locals are the refs under `refs/heads/`
        // and the others, `origin`'s.
        let listing = lines(try? git.run(["for-each-ref", "--format=%(refname)", "--sort=-committerdate", "refs/heads", "refs/remotes/origin"], in: repo))
        let locals = listing.compactMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        let remotes = listing.compactMap { ref -> String? in
            guard ref.hasPrefix("refs/remotes/origin/") else { return nil }
            let name = String(ref.dropFirst("refs/remotes/origin/".count))
            return name == "HEAD" ? nil : name
        }
        var out: [String] = [], seen = Set<String>()
        for name in [defaultBranch(repo: repo, git: git)] + locals + remotes where seen.insert(name).inserted { out.append(name) }
        return out
    }

    private static func lines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether every commit on `branch` also lives on the work `base` names — the local branch, or
    /// `origin/<base>` when the local one is missing or behind.
    ///
    /// `git branch -d` asks a narrower question: it judges "merged" against HEAD and the branch's
    /// own upstream only. The project's checkout is rarely sitting on the base branch — another
    /// task's branch is usually checked out there — so git refuses branches whose work is demonstrably
    /// safe in `main`. This answers the question the app actually means.
    public static func isMerged(branch: String, into base: String, repo: String, git: any GitRunning) -> Bool {
        guard !base.isEmpty, base != branch else { return false }
        // A ref that does not exist makes `--is-ancestor` fail like one that is not an ancestor, so
        // there is nothing to check for first.
        return ["refs/heads/" + base, "refs/remotes/origin/" + base].contains { ref in
            (try? git.run(["merge-base", "--is-ancestor", branch, ref], in: repo)) != nil
        }
    }

    public static func validateBranch(_ name: String, git: any GitRunning) -> Bool {
        (try? git.run(["check-ref-format", "--branch", name], in: "/")) != nil
    }

    public static func create(repo: String, slug: String, branch: String, base: String, git: any GitRunning) throws -> String {
        let path = try prepare(repo: repo, slug: slug, git: git)
        let hasOrigin = fetchFromOrigin(base, repo: repo, git: git)
        let start = hasOrigin && (try? git.run(["rev-parse", "--verify", "--quiet", "origin/\(base)"], in: repo)) != nil ? "origin/\(base)" : base
        try git.run(["worktree", "add", "--lock", "--reason", taskLockReason, "-b", branch, path, start], in: repo,
                    timeout: GitRunner.checkoutTimeout)
        return path
    }

    /// A review's worktree, on the branch itself, so the reviewer can commit its fixes and push them.
    ///
    /// The branch is brought to what origin has first: a local branch is whatever was last pulled,
    /// and the fetch never moves it. Behind origin, it is fast-forwarded; ahead, its unpushed commits
    /// are kept; diverged, it is refused rather than moved. Only on origin, it gets a local branch
    /// tracking origin's, which `releaseReviewBranch` takes back once the review is removed. Every
    /// refusal comes before anything is created, and no failure path deletes a branch that holds
    /// anything origin lacks — this one is someone's merge request.
    public static func checkout(repo: String, slug: String, branch: String, git: any GitRunning) throws -> String {
        let hasOrigin = fetchFromOrigin(branch, repo: repo, git: git)
        let local = sha("refs/heads/" + branch, repo: repo, git: git)
        let remote = hasOrigin ? sha("refs/remotes/origin/" + branch, repo: repo, git: git) : nil
        if let holder = try listed(repo: repo, git: git).first(where: { $0.branch == branch }) {
            throw WorktreeError.branchCheckedOut(branch, at: holder.path)
        }
        switch (local, remote) {
        case (nil, nil): throw WorktreeError.branchNotOnOrigin(branch)
        case let (l?, r?) where l != r && !isAncestor(r, of: l, repo: repo, git: git):
            guard isAncestor(l, of: r, repo: repo, git: git) else { throw WorktreeError.branchDiverged(branch) }
            // Behind: a fast-forward, which git refuses for a branch being rebased in some checkout.
            try fastForward(branch, repo: repo, git: git)
        default: break
        }
        let path = try prepare(repo: repo, slug: slug, git: git)
        let created = local == nil
        try git.run(["worktree", "add", "--lock", "--reason", reviewLockReason]
                    + (created ? ["-b", branch, path, "origin/" + branch] : [path, branch]), in: repo,
                    timeout: GitRunner.checkoutTimeout)
        // So that a plain `git push` from the review lands on origin's branch. Written as config
        // rather than asked of `--track` or `--set-upstream-to`, which refuse an `origin/<branch>`
        // that `remote.origin.fetch` does not cover — a single-branch clone's.
        if created || remote != nil {
            _ = try? git.run(["config", "branch.\(branch).remote", "origin"], in: repo)
            _ = try? git.run(["config", "branch.\(branch).merge", "refs/heads/" + branch], in: repo)
        }
        return path
    }

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
    public static func releaseReviewBranch(repo: String, branch: String, target: String, git: any GitRunning) -> ReviewBranchRelease {
        guard (try? git.run(["remote", "get-url", "origin"], in: repo)) != nil,
              let local = sha("refs/heads/" + branch, repo: repo, git: git) else { return .untouched }
        if let holder = (try? listed(repo: repo, git: git))?.first(where: { $0.branch == branch }) {
            return .kept("checked out at \(holder.path)")
        }
        let onOrigin: [String: String]
        do { onOrigin = try originHeads([branch, target].filter { !$0.isEmpty }, repo: repo, git: git) }
        catch { return .kept("couldn’t check origin (\(GitError.reason(of: error)))") }
        if let remote = onOrigin[branch] {
            guard fetched(remote, branch: branch, repo: repo, git: git) else {
                return .kept("couldn’t fetch origin’s \(branch) to compare")
            }
            guard !isAncestor(local, of: remote, repo: repo, git: git) else { return delete(branch, repo: repo, git: git) }
            let missing = Int((try? git.run(["rev-list", "--count", remote + ".." + local], in: repo)) ?? "") ?? 0
            return .kept("\(missing) commit\(missing == 1 ? "" : "s") not on origin")
        }
        // Origin no longer has the branch. Its commits are safe only where they still live: on the
        // target as origin has it now, or on a local branch of that name — never a cached copy.
        let retained = !target.isEmpty && target != branch && (
            onOrigin[target].map { fetched($0, branch: target, repo: repo, git: git) && isAncestor(local, of: $0, repo: repo, git: git) } == true
                || sha("refs/heads/" + target, repo: repo, git: git).map { isAncestor(local, of: $0, repo: repo, git: git) } == true)
        guard retained else {
            return .kept("not on origin and not merged into \(target.isEmpty ? "its target" : target)")
        }
        return delete(branch, repo: repo, git: git)
    }

    /// What origin has for each of `branches` right now: a name absent from the answer is a branch
    /// origin confirms it does not have. Throws when origin could not be asked.
    private static func originHeads(_ branches: [String], repo: String, git: any GitRunning) throws -> [String: String] {
        let refs = branches.map { "refs/heads/" + $0 }
        var heads: [String: String] = [:]
        for line in try git.runRemote(["ls-remote", "origin"] + refs, in: repo).split(separator: "\n") {
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
    private static func fetched(_ commit: String, branch: String, repo: String, git: any GitRunning) -> Bool {
        if sha(commit, repo: repo, git: git) != nil { return true }
        _ = try? git.runRemote(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], in: repo)
        return sha(commit, repo: repo, git: git) != nil
    }

    /// `-D` because the question `-d` asks — merged into HEAD or the upstream — is not the one
    /// answered above, and the project's checkout is usually on some other branch.
    private static func delete(_ branch: String, repo: String, git: any GitRunning) -> ReviewBranchRelease {
        do { try git.run(["branch", "-D", branch], in: repo); return .deleted }
        catch { return .kept(GitError.reason(of: error)) }
    }

    private static func sha(_ ref: String, repo: String, git: any GitRunning) -> String? {
        (try? commit(ref, repo: repo, git: git)) ?? nil
    }

    /// The commit `ref` names, `nil` when git says there is none (exit 1 under `--quiet`); thrown
    /// when git could not be asked.
    private static func commit(_ ref: String, repo: String, git: any GitRunning) throws -> String? {
        try git.ask(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: repo, none: [1])
    }

    private static func isAncestor(_ ancestor: String, of commit: String, repo: String, git: any GitRunning) -> Bool {
        (try? git.run(["merge-base", "--is-ancestor", ancestor, commit], in: repo)) != nil
    }

    /// Where a new worktree goes, made ready for `git worktree add`: never through a symlink, with
    /// `.worktrees/` in the repository's exclude file so it does not show as untracked.
    private static func prepare(repo: String, slug: String, git: any GitRunning) throws -> String {
        let dir = repo + "/" + directoryName, path = dir + "/" + slug
        for p in [dir, path] where (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil { throw WorktreeError.symlinkRefused(p) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try ensureExcluded(repo: repo, git: git)
        return path
    }

    /// Best-effort fetch of `ref` so a new worktree starts from the remote's latest; `false` when
    /// the repository has no `origin` at all. An explicit, forced refspec, as the other fetches
    /// here: `git fetch origin <ref>` updates `refs/remotes/origin/<ref>` only when
    /// `remote.origin.fetch` covers it, which a single-branch or shallow clone's does not.
    @discardableResult
    private static func fetchFromOrigin(_ ref: String, repo: String, git: any GitRunning) -> Bool {
        guard (try? git.run(["remote", "get-url", "origin"], in: repo)) != nil else { return false }
        _ = try? git.runRemote(["fetch", "--quiet", "origin", "+refs/heads/\(ref):refs/remotes/origin/\(ref)"], in: repo)
        return true
    }

    /// Whether `git worktree remove` would refuse `path` without `--force`: git's own check, asked
    /// ahead of it so the task's window can close before anything is deleted. `false` for a folder
    /// git does not know as a worktree — `git status` there would answer for the project's checkout.
    public static func hasUnsavedWork(repo: String, path: String, git: any GitRunning) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path), try isRegistered(repo: repo, path: path, git: git) else { return false }
        return try !git.run(["status", "--porcelain", "--ignore-submodules=none"], in: path).isEmpty
    }

    public static func remove(repo: String, path: String, deleteBranch: String?, force: Bool, git: any GitRunning) throws {
        if try isRegistered(repo: repo, path: path, git: git) {
            try removeRegistered(repo: repo, path: path, force: force, git: git)
        } else {
            // A removal git gave up on halfway, retried: there is nothing left to unlock or refuse.
            try deleteLeftover(repo: repo, path: path)
        }
        // The checkout is gone either way, so a branch git refuses to delete must not skip the prune.
        defer { _ = try? git.run(["worktree", "prune"], in: repo) }
        if let b = deleteBranch { try git.run(["branch", force ? "-D" : "-d", b], in: repo) }
    }

    private static func removeRegistered(repo: String, path: String, force: Bool, git: any GitRunning) throws {
        // Read the lock reason *before* unlocking: it is the only marker on disk that says whether
        // this worktree is a review's, and a refused removal must put back what was there rather
        // than stamping every survivor "aiterm task".
        let reason = lockReason(repo: repo, path: path, git: git) ?? taskLockReason
        _ = try? git.run(["worktree", "unlock", path], in: repo, timeout: GitRunner.checkoutTimeout)
        do { try git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: repo, timeout: GitRunner.checkoutTimeout) }
        catch {
            // git drops its record of the worktree even when it cannot delete all of it — a process
            // still running there wrote files back — and every later `remove` then fails "is not a
            // working tree". The checkout is gone; what is left is files nothing tracks.
            if (try? isRegistered(repo: repo, path: path, git: git)) == false { return try deleteLeftover(repo: repo, path: path) }
            // A refused removal leaves a live task; restore its protection from pruning.
            _ = try? git.run(["worktree", "lock", path] + (reason.isEmpty ? [] : ["--reason", reason]), in: repo,
                             timeout: GitRunner.checkoutTimeout)
            throw error
        }
    }

    /// Whether git lists `path` as one of `repo`'s worktrees.
    static func isRegistered(repo: String, path: String, git: any GitRunning) throws -> Bool {
        let wanted = resolved(path)
        return try listed(repo: repo, git: git).contains { resolved($0.path) == wanted }
    }

    /// What a half-finished removal left of a worktree git no longer knows. Only ever a folder under
    /// the project's `.worktrees/`, and never through a symlink: anywhere else, a folder git does not
    /// know is not AiTerm's to delete.
    private static func deleteLeftover(repo: String, path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard resolved(parent) == resolved(repo + "/" + directoryName),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { throw WorktreeError.notAWorktree(path) }
        try FileManager.default.removeItem(atPath: path)
    }

    /// Every worktree of `repo` that lives under `.worktrees/` and has a branch, with the lock
    /// reason git records for it. The reason matters: `checkout` writes `reviewLockReason` where
    /// `create` writes `taskLockReason`, and that is the only thing on disk that says which kind a
    /// worktree is — so an import that threw it away would turn a review back into a task, whose
    /// branch the app is willing to delete.
    public static func existing(repo: String, git: any GitRunning) throws -> [Worktree] {
        let prefix = resolved(repo) + "/" + directoryName + "/"
        return try listed(repo: repo, git: git).filter { $0.branch != nil && resolved($0.path).hasPrefix(prefix) }
    }

    /// The reason `path` is locked with. `nil` when the worktree is unlocked or unknown to git,
    /// `""` when it is locked without a reason.
    public static func lockReason(repo: String, path: String, git: any GitRunning) -> String? {
        let wanted = resolved(path)
        return ((try? listed(repo: repo, git: git)) ?? []).first { resolved($0.path) == wanted }?.lockReason
    }

    /// `git worktree list --porcelain`: blank-line-separated records of `worktree <path>`,
    /// `branch refs/heads/<name>` and `locked <reason>` — or a bare `locked` when the lock carries none.
    public static func listed(repo: String, git: any GitRunning) throws -> [Worktree] {
        var out: [Worktree] = [], current: Worktree?
        for line in try git.run(["worktree", "list", "--porcelain"], in: repo).split(separator: "\n", omittingEmptySubsequences: false) {
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

    static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// The `info/exclude` file that applies to `path`, whether `path` is an ordinary checkout or a
    /// linked worktree. Asking git (`rev-parse --git-path info/exclude`) instead of assuming
    /// `<path>/.git/info/exclude` is what makes the linked-worktree case work: there `.git` is a
    /// *file* pointing at the common dir, so the assumed path is not a directory we may create.
    /// git answers with an absolute path from inside a linked worktree and a relative one from a
    /// normal checkout; both are handled. `nil` means "not a git repository" (or git is missing).
    public static func excludeFile(forWorktreeOrRepo path: String, git: any GitRunning) -> URL? {
        guard let answer = try? git.run(["rev-parse", "--git-path", "info/exclude"], in: path), !answer.isEmpty else { return nil }
        return URL(fileURLWithPath: answer.hasPrefix("/") ? answer : path + "/" + answer)
    }

    /// Appends `pattern` to an exclude file, creating the containing directory and the file if
    /// needed. Idempotent: a line that already matches exactly is left alone.
    public static func appendExclude(_ pattern: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(where: { $0 == pattern }) else { return }
        try (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func ensureExcluded(repo: String, git: any GitRunning) throws {
        guard let excludeURL = excludeFile(forWorktreeOrRepo: repo, git: git) else { return }
        try appendExclude(directoryName + "/", to: excludeURL)
    }
}
