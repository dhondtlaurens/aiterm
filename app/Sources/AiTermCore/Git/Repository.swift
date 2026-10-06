import Foundation

/// A project's git repository and the git that answers for it, held once: every question about the
/// repository is asked of one of these. What it can do is split by job — its refs and remote here,
/// its worktrees (`Repository+Worktrees`), its default branch kept up with origin's
/// (`Repository+DefaultBranch`) and a review's branch let go of (`Repository+ReviewBranch`).
public struct Repository: Sendable {
    public let path: String
    public let git: any GitRunning

    public init(_ path: String, git: any GitRunning) { self.path = path; self.git = git }

    /// The top of the checkout `path` is in; `nil` when it is in none.
    public static func toplevel(of path: String, git: any GitRunning) throws -> String? {
        do { return try git.run(["rev-parse", "--show-toplevel"], in: path) }
        catch let e as GitError where e.code == 128 { return nil }
    }

    /// The remote a project pushes to: the one the checked-out branch tracks, else `origin`, else the
    /// first there is; `nil` when the repository has none. That is git's answer. When git cannot be
    /// asked — it timed out, or did not start — this throws, since "no remote" would read as the
    /// project having lost its remote.
    public func remoteUrl() throws -> String? {
        // 128 is "no upstream configured" (or a detached HEAD): the next steps ask again, and fail loudly.
        if let upstream = try git.ask(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: path, none: [128]),
           let remote = upstream.split(separator: "/").first,
           let url = try git.ask(["remote", "get-url", String(remote)], in: path, none: [2]) { return url }
        if let url = try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) { return url }
        if let first = try git.run(["remote"], in: path).split(separator: "\n").first {
            return try git.ask(["remote", "get-url", String(first)], in: path, none: [2])
        }
        return nil
    }

    /// The name the project menu and a new task's base branch fall back to when a repository gives
    /// no default branch away.
    public static let fallbackDefaultBranch = "main"

    /// The default branch, or `nil` when the repository does not say: no usable `origin/HEAD` and
    /// none of the usual names. Throws when git cannot be asked, which says nothing either way.
    public func detectDefaultBranch() throws -> String? {
        // One `for-each-ref` over every ref the answer can come from. It lists only refs that
        // resolve, which is exactly what is wanted: `origin/HEAD` names a branch only while origin
        // still has it — a rename on origin leaves the old name in a clone's `origin/HEAD` — and a
        // usual name counts only if it exists.
        let prefix = "refs/remotes/origin/"
        let usual = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        let listing = try git.run(["for-each-ref", "--format=%(refname) %(symref)", prefix + "HEAD"] + usual, in: path)
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

    /// ``detectDefaultBranch()``, or ``fallbackDefaultBranch`` when there is none or git cannot be
    /// asked — for a caller that must show some name and will be asked again.
    public func defaultBranch() -> String {
        (Log.git.attempt("Reading the default branch of \(path)") { try detectDefaultBranch() } ?? nil) ?? Self.fallbackDefaultBranch
    }

    /// Every branch the base-branch popup can offer: local branches most-recently-committed first,
    /// then branches that exist only on `origin` (offered under their short name, because that is
    /// what `git worktree add` resolves). The repository's default branch is always first, even
    /// when it has not been touched in months.
    public func branches() -> [String] {
        // One listing of both, newest first within each: the locals are the refs under `refs/heads/`
        // and the others, `origin`'s.
        let listing = Log.git.attempt("Listing the branches of \(path)") {
            try git.run(["for-each-ref", "--format=%(refname)", "--sort=-committerdate", "refs/heads", "refs/remotes/origin"], in: path)
        }
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        let locals = listing.compactMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        let remotes = listing.compactMap { ref -> String? in
            guard ref.hasPrefix("refs/remotes/origin/") else { return nil }
            let name = String(ref.dropFirst("refs/remotes/origin/".count))
            return name == "HEAD" ? nil : name
        }
        var out: [String] = [], seen = Set<String>()
        for name in [defaultBranch()] + locals + remotes where seen.insert(name).inserted { out.append(name) }
        return out
    }

    /// Whether every commit on `branch` also lives on the work `base` names — the local branch, or
    /// `origin/<base>` when the local one is missing or behind.
    ///
    /// `git branch -d` asks a narrower question: it judges "merged" against HEAD and the branch's
    /// own upstream only. The project's checkout is rarely sitting on the base branch — another
    /// task's branch is usually checked out there — so git refuses branches whose work is demonstrably
    /// safe in `main`. This answers the question the app actually means.
    ///
    /// Thrown when git could not answer — it timed out, say — which is no "not merged".
    public func isMerged(_ branch: String, into base: String) throws -> Bool {
        guard !base.isEmpty, base != branch else { return false }
        for ref in ["refs/heads/" + base, "refs/remotes/origin/" + base] {
            // A ref that does not exist is a `fatal:` (128) from `--is-ancestor`: the work is not
            // there either, so there is nothing to check for first.
            if try git.ask(["merge-base", "--is-ancestor", branch, ref], in: path, none: [1, 128]) != nil { return true }
        }
        return false
    }

    // MARK: Refs and origin, for the jobs in the other files

    /// The commit `ref` names; `nil` when there is none or git could not be asked.
    func sha(_ ref: String) -> String? {
        Log.git.attempt("Reading \(ref) in \(path)") { try commit(ref) } ?? nil
    }

    /// The commit `ref` names, `nil` when git says there is none (exit 1 under `--quiet`); thrown
    /// when git could not be asked.
    func commit(_ ref: String) throws -> String? {
        try git.ask(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: path, none: [1])
    }

    /// Whether `ancestor` is in `commit`'s history. git's "no" is exit 1; anything else — a
    /// timeout, a commit it cannot find — is thrown, so it is never taken for a no.
    func isAncestor(_ ancestor: String, of commit: String) throws -> Bool {
        try git.ask(["merge-base", "--is-ancestor", ancestor, commit], in: path, none: [1]) != nil
    }

    /// How many commits `to` has that `from` lacks; `nil` when git could not count them — it timed
    /// out, say — which is no count rather than none.
    func count(_ from: String, _ to: String) -> Int? {
        Log.git.attempt("Counting the commits from \(from) to \(to) in \(path)") {
            try git.run(["rev-list", "--count", from + ".." + to], in: path)
        }.flatMap { Int($0) }
    }

    /// Whether the repository has a remote called `origin`: git's answer is a failure (exit 2)
    /// when it has none. Any other failure — a timeout — is thrown, as no answer at all.
    var hasOrigin: Bool {
        get throws { try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) != nil }
    }

    /// `branch` fetched from origin into `origin/<branch>`. An explicit, forced refspec: `git fetch
    /// origin <branch>` updates the tracking ref only when `remote.origin.fetch` covers it, which a
    /// single-branch or shallow clone's does not.
    func fetchFromOrigin(_ branch: String) throws {
        try git.runRemote(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], in: path)
    }

    /// `branch` brought to `origin/<branch>` where no checkout lists it: a fetch from the repository
    /// into itself, not `update-ref`. A branch mid-rebase or mid-bisect is listed nowhere — that
    /// checkout's HEAD is detached — and git's fetch refuses such a branch as it refuses a checked-out
    /// one. The refspec is not forced, so anything but a fast-forward of the ref as it is now, a
    /// concurrent change included, is refused too.
    func fastForward(_ branch: String) throws {
        try git.run(["fetch", "--quiet", "--no-write-fetch-head", "--no-prune", "--no-recurse-submodules", ".",
                     "refs/remotes/origin/\(branch):refs/heads/\(branch)"], in: path)
    }
}
