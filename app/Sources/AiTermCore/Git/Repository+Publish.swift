import Foundation

/// Why `push` refused before asking git to push.
public enum PublishRefusal: Error, Equatable, LocalizedError {
    case defaultBranch(String), noOrigin
    /// A name git does not take as a branch, or that git could read as an option or as a place to look.
    case invalidBranch(String)
    /// Something other than a full commit id, which git could read as a ref, an option or a second refspec.
    case invalidCommit(String)
    /// No default branch to compare with: AiTerm cannot tell that a push would not reach it.
    case unknownDefaultBranch
    /// Origin pushes somewhere other than its one URL: a second `url`, a `pushurl`, a `pushInsteadOf`.
    case pushDestination(String)
    /// Origin did not say what its own default branch is, so AiTerm cannot tell that a push would not reach it.
    case originUnreadable
    /// The branch is, on origin, another name for a branch: a push to it moves the other.
    case symbolicBranch(String)
    /// The branch is on origin already, at the default branch's commit: it cannot be told apart from
    /// a symbolic ref to it, which an old server or protocol does not show.
    case atDefaultCommit(String)

    public var errorDescription: String? {
        switch self {
        case .defaultBranch(let branch): return "AiTerm never pushes to the default branch, \(branch)."
        case .noOrigin: return "The project has no origin to push to."
        case .invalidBranch(let name): return "\(name) is not a branch name AiTerm can push to."
        case .invalidCommit(let sha): return "\(sha) is not a full commit id."
        case .unknownDefaultBranch: return "AiTerm does not know the project's default branch, so it pushes nothing."
        case .pushDestination(let why): return "AiTerm pushes only to origin's own URL, and \(why)."
        case .originUnreadable: return "AiTerm could not read origin's default branch, so it pushes nothing."
        case .symbolicBranch(let branch): return "The branch \(branch) on origin is another name for a branch, so AiTerm pushes nothing to it."
        case .atDefaultCommit(let branch):
            return "The branch \(branch) on origin is at the default branch's commit and cannot be told apart from it, so AiTerm pushes nothing to it."
        }
    }
}

/// The one push AiTerm makes on purpose: an operator's `finish_task` (spec §4.3). Everything else
/// AiTerm does to a repository stays on this machine.
extension Repository {
    /// A pre-push hook may run a project's tests, so a push gets the checkout's deadline, not a fetch's.
    public static let pushTimeout: TimeInterval = 300

    /// The commit `branch` points at here; nil when there is no such branch.
    public func tip(of branch: String) throws -> String? {
        try commit("refs/heads/" + branch)
    }

    /// Whether `ancestor` is in `commit`'s history: a stacked task's result must contain its parent's
    /// accepted commit.
    public func contains(_ ancestor: String, in commit: String) throws -> Bool {
        try isAncestor(ancestor, of: commit)
    }

    /// `sha` pushed to origin as `branch` — exactly that commit, whatever the branch's tip is now.
    /// Never forced: the refspec has no `+`, so origin takes only a fast-forward, and a rewritten
    /// branch fails with git's own words. Never the default branch, under any spelling of it (case
    /// folded, since macOS and some hosts are case-insensitive; `refs/heads/` in front; `HEAD`), and
    /// not only the one the caller names: origin is asked for its own `HEAD` right before the push,
    /// and a branch that is a symbolic ref there is refused. A branch the host protects is refused
    /// before this is called (`TaskPublisher`, which asks the host). Pushing what origin already
    /// has is git's no-op, so a repeated `finish_task` pushes nothing new.
    ///
    /// The push runs under the user's and the repository's git configuration, which a worker can
    /// write: the arguments below take back what it could add — tags (`push.followTags`), push
    /// options a host acts on (`push.pushOption`, GitLab's `merge_request.*`), submodule pushes —
    /// and origin must have exactly one URL to push to, the one it is fetched from. Pre-push hooks
    /// still run; they are the project's own.
    public func push(_ sha: String, as branch: String, defaultBranch: String) throws {
        // A commit id only: a ref name, an option or `a:b` would change what the refspec says.
        guard Self.isCommitId(sha) else { throw PublishRefusal.invalidCommit(sha) }
        guard !branch.isEmpty, !branch.hasPrefix("-"), branch != "@" else { throw PublishRefusal.invalidBranch(branch) }
        guard !defaultBranch.isEmpty, !Self.shortBranch(defaultBranch).isEmpty else { throw PublishRefusal.unknownDefaultBranch }
        let name = Self.shortBranch(branch), fallback = Self.shortBranch(defaultBranch)
        if name.isEmpty || Self.folded(name) == Self.folded(fallback) || Self.folded(name) == "head" {
            throw PublishRefusal.defaultBranch(defaultBranch)
        }
        // git's own judgement of the name. `--branch` also expands `@{-1}` to the previous branch, so
        // a name that comes back different was never a branch name. (A lone `@` is HEAD's alias, which
        // git takes as a component but never as a branch: refused above.)
        guard try git.ask(["check-ref-format", "--branch", branch], in: path, none: [1, 128]) == branch else {
            throw PublishRefusal.invalidBranch(branch)
        }
        guard let fetchURL = try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) else { throw PublishRefusal.noOrigin }
        try requireOneDestination(like: fetchURL)
        try requireOriginsOwnDefaultBranchIsNot(branch: branch, name: name)
        try git.run(GitRunner.stallGuard + ["-c", "push.pushOption=", "push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules",
                                            "origin", "\(sha):refs/heads/\(branch)"],
                    in: path, timeout: Self.pushTimeout)
    }

    /// The push goes to one URL, and to the repository origin is fetched from. A second
    /// `remote.origin.url` would push to both, a `pushurl` or a `url.*.pushInsteadOf` to another
    /// repository, and the host's protection rules AiTerm asked about are the fetched one's. A
    /// `pushInsteadOf` that only changes the scheme (https to ssh) names the same host and path.
    private func requireOneDestination(like fetchURL: String) throws {
        let pushURLs = try git.run(["remote", "get-url", "--push", "--all", "origin"], in: path)
            .split(separator: "\n").map(String.init)
        guard pushURLs.count == 1 else { throw PublishRefusal.pushDestination("origin has \(pushURLs.count) URLs to push to") }
        guard Self.sameLocation(pushURLs[0], fetchURL) else {
            throw PublishRefusal.pushDestination("origin pushes to \(pushURLs[0]), not to where it is fetched from")
        }
    }

    /// Origin's own `HEAD` and `refs/heads/<branch>`, asked of origin right before the push: the
    /// caller's default branch comes from a local guess that fails open to `main`.
    ///
    /// Protocol 2 is asked for, because only it lists every symbolic ref; version 0 lists HEAD's alone
    /// (and a v0-only server cannot do better). So whatever the protocol, a branch already on origin
    /// at HEAD's own commit is refused too: it may be a symref to the default branch. A branch not
    /// on origin yet, the usual case, is unaffected. (`remote.origin.receivepack` is left alone: only
    /// deliberate configuration sets it, and overriding it could break a real setup.)
    private func requireOriginsOwnDefaultBranchIsNot(branch: String, name: String) throws {
        let listing = try git.runRemote(["-c", "protocol.version=2", "ls-remote", "--symref", "origin", "HEAD", "refs/heads/" + branch], in: path)
        var head: String?, target: String?, headCommit: String?, branchCommit: String?
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            if fields[0].hasPrefix("ref: refs/heads/") {
                // `ref: <target>\t<name>` for a symbolic ref.
                let to = String(fields[0].dropFirst("ref: refs/heads/".count))
                if fields[1] == "HEAD" { head = to } else if fields[1] == "refs/heads/" + branch { target = to }
            } else if fields[1] == "HEAD" {
                headCommit = String(fields[0])
            } else if fields[1] == "refs/heads/" + branch {
                branchCommit = String(fields[0])
            }
        }
        guard let head else { throw PublishRefusal.originUnreadable }
        if Self.folded(head) == Self.folded(name) { throw PublishRefusal.defaultBranch(head) }
        if target != nil { throw PublishRefusal.symbolicBranch(branch) }
        if let branchCommit, branchCommit == headCommit { throw PublishRefusal.atDefaultCommit(branch) }
    }

    /// Whether two remote URLs name the same host and path, whatever the scheme, user, port, a
    /// trailing `.git` or slash, or case: `https://host/a/b.git` and `git@host:a/b`. A local path
    /// has no host.
    static func sameLocation(_ a: String, _ b: String) -> Bool {
        func parts(_ url: String) -> (host: String, path: String) {
            var rest = url, host = ""
            if let scheme = rest.range(of: "://") {
                rest = String(rest[scheme.upperBound...])
                if url.hasPrefix("file:") { rest = rest.hasPrefix("/") ? rest : "/" + rest }
                else if let slash = rest.firstIndex(of: "/") { host = String(rest[..<slash]); rest = String(rest[slash...]) }
                else { host = rest; rest = "" }
            } else if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains("/") {
                // scp-like `user@host:path`
                host = String(rest[..<colon]); rest = String(rest[rest.index(after: colon)...])
            }
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
            while rest.hasSuffix("/") { rest.removeLast() }
            if rest.hasSuffix(".git") { rest.removeLast(4) }
            while rest.hasPrefix("/") && !host.isEmpty { rest.removeFirst() }
            return (folded(host), folded(rest))
        }
        return parts(a) == parts(b)
    }

    /// A full object name: 40 hex digits (SHA-1) or 64 (SHA-256).
    private static func isCommitId(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

    /// `name` without a leading `refs/heads/`: `refs/heads/main` names the default branch's own ref.
    private static func shortBranch(_ name: String) -> String {
        name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }

    /// `name` compared the way a case-insensitive or normalising file system or host would.
    private static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }
}
