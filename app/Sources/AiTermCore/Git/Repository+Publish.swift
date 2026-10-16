import Foundation

/// Why `push` refused before asking git to push.
public enum PublishRefusal: Error, Equatable, LocalizedError {
    case defaultBranch(String), noOrigin
    /// A name git does not take as a branch, or that git could read as an option or as a place to look.
    case invalidBranch(String)
    /// Something other than a full commit id, which git could read as a ref, an option or a second refspec.
    case invalidCommit(String)

    public var errorDescription: String? {
        switch self {
        case .defaultBranch(let branch): return "AiTerm never pushes to the default branch, \(branch)."
        case .noOrigin: return "The project has no origin to push to."
        case .invalidBranch(let name): return "\(name) is not a branch name AiTerm can push to."
        case .invalidCommit(let sha): return "\(sha) is not a full commit id."
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
    /// folded, since macOS and some hosts are case-insensitive; `refs/heads/` in front; `HEAD`); a
    /// branch the host protects is refused before this is called (`TaskPublisher`, which asks the
    /// host). Pushing what origin already has is git's no-op, so a repeated `finish_task` pushes
    /// nothing new.
    public func push(_ sha: String, as branch: String, defaultBranch: String) throws {
        // A commit id only: a ref name, an option or `a:b` would change what the refspec says.
        guard Self.isCommitId(sha) else { throw PublishRefusal.invalidCommit(sha) }
        guard !branch.isEmpty, !branch.hasPrefix("-"), branch != "@" else { throw PublishRefusal.invalidBranch(branch) }
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
        guard try hasOrigin else { throw PublishRefusal.noOrigin }
        // `remote.origin.mirror=false`: a mirror remote would push every ref, forced, whatever is named.
        try git.run(GitRunner.stallGuard + ["-c", "remote.origin.mirror=false", "push", "--porcelain", "origin", "\(sha):refs/heads/\(branch)"],
                    in: path, timeout: Self.pushTimeout)
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
