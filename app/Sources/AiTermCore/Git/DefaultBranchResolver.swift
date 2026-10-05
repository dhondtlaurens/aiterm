import Foundation

/// Maps a project's directory to its default branch — ``Worktrees/defaultBranch(repo:git:)`` —
/// cheaply enough to be asked for every project on every refresh pass, for the project menu's
/// "Pull main".
///
/// Unlike ``RemoteResolver`` there is no one file git rewrites: the answer comes from `origin/HEAD`,
/// else whichever of the usual names exists, and any of those refs can be a file of its own, a
/// line in `packed-refs` or, in a reftable repository, an entry in a table. So it is kept against
/// the stamps of all of them (``FileStamps``), a missing one included, which costs a `stat` per
/// ref (see ``WatchedFileCache``).
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
public final class DefaultBranchResolver: Sendable {
    /// Every ref ``Worktrees/defaultBranch(repo:git:)`` reads, relative to the common git directory.
    /// A reftable repository keeps none of them in a file: every update rewrites its stack's
    /// `tables.list` instead, as ``BranchResolver`` watches for HEAD. `config` is not read, but every
    /// repository has one: a repository whose default is none of the usual names, and has no origin,
    /// has none of the rest, and all of them missing is what says a checkout went away.
    private static let refs = ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master",
                               "refs/heads/main", "refs/heads/master", "packed-refs", "reftable/tables.list", "config"]

    private let git: any GitRunning
    private let cache: WatchedFileCache<String>

    public init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, negativeTTL: TimeInterval = 30) {
        self.git = git
        self.cache = WatchedFileCache(now: now, negativeTTL: negativeTTL)
    }

    /// The default branch of the repository `repo` is in — ``Worktrees/fallbackDefaultBranch`` when
    /// it does not say — or `nil` when it is not a git checkout, or git could not be asked and nothing
    /// was known before. A failure is never kept; one after an answer leaves that answer standing
    /// until the next lookup.
    public func defaultBranch(for repo: String) -> String? {
        guard !repo.isEmpty else { return nil }
        let git = self.git
        do {
            switch try cache.answer(for: repo, locate: { try Self.locate($0, git: git) },
                                    read: { repo, _ in try Worktrees.detectDefaultBranch(repo: repo, git: git) ?? Worktrees.fallbackDefaultBranch }) {
            case .notARepository: return nil
            case .found(let branch): return branch
            }
        } catch { return nil }
    }

    private static func locate(_ repo: String, git: any GitRunning) throws -> [String]? {
        guard let common = try git.ask(["rev-parse", "--git-common-dir"], in: repo, none: [128]), !common.isEmpty else { return nil }
        let directory = FileStamps.absolute(common, in: repo)
        return refs.map { directory + "/" + $0 }
    }
}
