import Foundation

/// Maps a project's directory to its default branch — ``Repository/defaultBranch()`` —
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
    /// Every ref ``Repository/defaultBranch()`` reads, relative to the common git directory.
    /// A reftable repository keeps none of them in a file: every update rewrites its stack's
    /// `tables.list` instead, as ``BranchResolver`` watches for HEAD. `config` is not read, but every
    /// repository has one: a repository whose default is none of the usual names, and has no origin,
    /// has none of the rest, and all of them missing is what says a checkout went away.
    private static let refs = ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master",
                               "refs/heads/main", "refs/heads/master", "packed-refs", "reftable/tables.list", "config"]

    private let git: any GitRunning
    private let probe: RepositoryProbe
    private let cache: WatchedFileCache<String>

    /// Resolvers given the same `probe` ask git where a directory's files are once between them.
    public init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, negativeTTL: TimeInterval = 30,
                probe: RepositoryProbe? = nil) {
        self.git = git
        self.probe = probe ?? RepositoryProbe(git: git, now: now, negativeTTL: negativeTTL)
        self.cache = WatchedFileCache(now: now, negativeTTL: negativeTTL)
    }

    /// Forgets every project directory not in `live`.
    public func retain(only live: Set<String>) { cache.retain(only: live) }

    /// The default branch of the repository `repo` is in — ``Repository/fallbackDefaultBranch`` when
    /// it does not say — or `nil` when it is not a git checkout, or git could not be asked and nothing
    /// was known before. A failure is never kept; one after an answer leaves that answer standing
    /// until the next lookup.
    public func defaultBranch(for repo: String) -> String? {
        guard !repo.isEmpty else { return nil }
        let git = self.git, probe = self.probe
        do {
            switch try cache.answer(for: repo, locate: { try probe.locations(of: $0).map(Self.watched) },
                                    read: { repo, _ in try Repository(repo, git: git).detectDefaultBranch() ?? Repository.fallbackDefaultBranch }) {
            case .notARepository: return nil
            case .found(let branch): return branch
            }
        } catch { return nil }
    }

    private static func watched(_ found: RepositoryProbe.Locations) -> [String] {
        refs.map { found.commonDirectory + "/" + $0 }
    }
}
