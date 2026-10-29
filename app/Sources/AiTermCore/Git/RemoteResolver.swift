import Foundation

/// What a directory says about the remote a project pushes to.
public enum RepoRemote: Equatable, Sendable {
    /// Not a git checkout — or not readable at all, which looks the same from outside and is
    /// therefore never evidence that a project stopped being one.
    case notARepository
    /// A checkout, and the remote its rows are classified from; `nil` when it has none yet.
    case remote(String?)
    /// A checkout, but git could not be asked just now. Says nothing about the remote, and is never
    /// kept: the next lookup asks again.
    case unavailable
}

/// Maps a project's directory to the remote it points at, cheaply enough to be asked for every
/// project on every refresh pass: the answer is cached against the shared `config` and the
/// checkout's `HEAD` (or reftable list). Switching upstreams invalidates it even without a config edit.
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
public final class RemoteResolver: Sendable {
    private typealias CachedRemote = (url: String?, info: RemoteInfo)
    private let resolver: RepositoryResolver<CachedRemote>

    /// Resolvers given the same `probe` ask git where a directory's files are once between them.
    public init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, negativeTTL: TimeInterval = 30,
                probe: RepositoryProbe? = nil) {
        resolver = RepositoryResolver(git: git, now: now, negativeTTL: negativeTTL, probe: probe)
    }

    /// Forgets every project directory not in `live`.
    public func retain(only live: Set<String>) { resolver.cache.retain(only: live) }

    /// The remote configured in `repo`, `.notARepository` when that is not a git checkout, and
    /// `.unavailable` when git could not be asked and nothing was known before. A failure is never
    /// kept; one after an answer leaves that answer standing until the next lookup.
    public func remote(for repo: String) -> RepoRemote {
        do {
            switch try answer(for: repo) {
            case .notARepository: return .notARepository
            case .found(let remote): return .remote(remote.url)
            }
        } catch { return .unavailable }
    }

    /// The remote and its cached host/path, absent when the checkout could not be read. Provider
    /// classification stays current with the checkout's GitLab markers, which can change without
    /// a config edit; known hosts need no filesystem checks.
    public func resolvedRemote(for repo: String) -> (url: String?, info: RemoteInfo)? {
        do {
            guard case .found(var remote) = try answer(for: repo) else { return nil }
            remote.info.provider = ProviderDetector.classify(host: remote.info.host, path: remote.info.path, repoPath: repo)
            return remote
        } catch { return nil }
    }

    private func answer(for repo: String) throws -> WatchedFileCache<CachedRemote>.Answer {
        try resolver.answer(for: repo, locate: { [$0.config, $0.head, $0.reftableList] }, read: { repo, _, git in
            let url = try Repository(repo, git: git).remoteUrl()
            return (url, ProviderDetector.detect(remoteUrl: url))
        })
    }
}
