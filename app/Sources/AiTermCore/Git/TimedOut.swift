import Foundation

/// That git ran out of time on a key, and when: the one failure worth not asking again about at
/// once. Any other — a status git answered with, git not starting — is as cheap to ask again as it
/// was to ask, and is.
///
/// The one record of a timeout for everything that backs off after one: ``WatchedFileCache`` and
/// ``RepositoryProbe`` per directory, ``DiffStatResolver`` per worktree, ``StallGuardedGit`` per
/// project.
struct TimedOut: Sendable {
    /// How long a key whose git ran out of time is left alone: long enough that a dead mount costs
    /// its deadline once in a while rather than on every pass, short enough that a git that merely
    /// ran under load is asked again within the minute.
    static let backoff: TimeInterval = 30

    let error: GitError, at: Date

    /// `nil` for a failure that is not a timeout, which is never held back.
    init?(_ error: any Error, at: Date) {
        guard let error = error as? GitError, error.timedOut else { return nil }
        self.error = error; self.at = at
    }

    func isPending(now: Date, backoff: TimeInterval) -> Bool { now.timeIntervalSince(at) < backoff }
}
