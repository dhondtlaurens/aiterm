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
/// project on every refresh pass: the answer is cached against the `config` file git rewrites on
/// `git remote add` (see ``WatchedFileCache``). From inside a linked worktree, `config` resolves to
/// the *shared* one, which is the one holding the remotes.
///
/// The answer is ``Worktrees/remoteUrl(repo:git:)``, so it matches what adding the project would
/// have stored. That prefers the checked-out branch's upstream, which `config` also holds — but a
/// checkout alone does not rewrite `config`, so switching to a branch tracking a *different* remote
/// is only picked up once something else touches it.
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
public final class RemoteResolver: Sendable {
    private let git: any GitRunning
    private let cache: WatchedFileCache<String?>

    public init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, negativeTTL: TimeInterval = 30) {
        self.git = git
        self.cache = WatchedFileCache(now: now, negativeTTL: negativeTTL)
    }

    /// The remote configured in `repo`, `.notARepository` when that is not a git checkout, and
    /// `.unavailable` when git could not be asked and nothing was known before. A failure is never
    /// kept; one after an answer leaves that answer standing until the next lookup.
    public func remote(for repo: String) -> RepoRemote {
        guard !repo.isEmpty else { return .notARepository }
        let git = self.git
        do {
            switch try cache.answer(for: repo, locate: { try WatchedFileCache<String?>.gitPath("config", in: $0, git: git).map { [$0] } },
                                    read: { repo, _ in try Worktrees.remoteUrl(repo: repo, git: git) }) {
            case .notARepository: return .notARepository
            case .found(let remote): return .remote(remote)
            }
        } catch { return .unavailable }
    }
}
