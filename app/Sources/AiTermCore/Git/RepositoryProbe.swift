import Foundation

/// Where git keeps the files a checkout's answers are read from, asked once for a directory and
/// shared by ``BranchResolver``, ``RemoteResolver`` and ``DefaultBranchResolver``.
///
/// Each of them watches a different file — `HEAD`, `config`, the refs — and used to find it with a
/// `git rev-parse` of its own, so a project's directory cost three spawns on a cold pass, and again
/// every `negativeTTL` seconds for a folder that is not a repository. One `rev-parse` names them all.
///
/// The paths do not change while the repository exists, so an answer is kept for as long as its
/// `HEAD` and `config` do, and a directory that is not a repository for `negativeTTL` seconds. A
/// failure is never kept, and git running out of time is not asked again for a while, as in
/// ``WatchedFileCache``.
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
public final class RepositoryProbe: Sendable {
    /// The files, absolute. `head` is the `HEAD` of the checkout asked about, and `reftableList` the
    /// list of the stack holding it, which is the file a reftable repository rewrites on a checkout.
    struct Locations: Equatable, Sendable {
        let head: String, reftableList: String, config: String, commonDirectory: String

        /// Whether the repository is still where it was: its `HEAD` and `config` exist.
        var exist: Bool {
            [head, config].allSatisfy { FileManager.default.fileExists(atPath: $0) }
        }
    }

    /// `locations` is `nil` for a directory that is not a repository.
    private struct State { var locations: Locations?; var probedAt: Date?; var timeout: TimedOut? }

    private let git: any GitRunning
    private let now: @Sendable () -> Date
    private let negativeTTL: TimeInterval
    private let failureBackoff: TimeInterval
    private let states = KeyedStates<State>(State())

    public init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, negativeTTL: TimeInterval = 30) {
        self.git = git; self.now = now; self.negativeTTL = negativeTTL; self.failureBackoff = TimedOut.backoff
    }

    /// The files of the repository `directory` is in, or `nil` when it is not in one. Throws when
    /// git could not be asked, which says nothing either way.
    func locations(of directory: String) throws -> Locations? {
        try states.withState(for: directory) { state in
            if let timeout = state.timeout, timeout.isPending(now: now(), backoff: failureBackoff) { throw timeout.error }
            if let locations = state.locations, locations.exist { return locations }
            if state.locations == nil, let probedAt = state.probedAt, now().timeIntervalSince(probedAt) < negativeTTL { return nil }
            do {
                let locations = try probe(directory)
                state = State(locations: locations, probedAt: now())
                return locations
            } catch {
                state.timeout = TimedOut(error, at: now())
                throw error
            }
        }
    }

    /// Forgets every directory not in `live`.
    func retain(only live: Set<String>) { states.retain(only: live) }

    private func probe(_ directory: String) throws -> Locations? {
        let names = ["HEAD", "config", "reftable/tables.list"]
        let args = ["rev-parse", "--path-format=absolute", "--git-common-dir"] + names.flatMap { ["--git-path", $0] }
        // 128 is git's `fatal: not a git repository`.
        guard let answer = try git.ask(args, in: directory, none: [128]), !answer.isEmpty else { return nil }
        let lines = answer.split(separator: "\n").map(String.init)
        guard lines.count == names.count + 1 else {
            throw GitError(args: args, code: 0, stderr: "git answered \(lines.count) lines to \(names.count + 1) questions")
        }
        return Locations(head: lines[1], reftableList: lines[3], config: lines[2], commonDirectory: lines[0])
    }
}
