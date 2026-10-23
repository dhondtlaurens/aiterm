import Foundation
import Synchronization

/// The cache behind ``BranchResolver``, ``RemoteResolver`` and ``DefaultBranchResolver``, cheap
/// enough to be asked for every tab and every project on every refresh pass.
///
/// A directory is resolved once and then re-validated by `stat`ing the files git itself rewrites —
/// `HEAD` for the branch, `HEAD` and `config` for the remote, the default branch refs — which is
/// exactly what a `git checkout` or a `git remote add` in a terminal touches, so either shows up with
/// no polling and no watcher. When none of the watched files can be read any more, the checkout
/// moved or went away, so it is probed again rather than answered from the cache. Directories that
/// are not repositories are remembered too, for `negativeTTL` seconds, so a stray tab in `$HOME`
/// does not shell out forever.
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git. Each directory has a
/// lock of its own (``KeyedStates``), so a directory whose git is slow holds up nobody else's lookup.
final class WatchedFileCache<Value: Sendable>: Sendable {
    enum Answer { case notARepository, found(Value) }

    /// `stamps` is `nil` for a directory that is not a repository.
    private struct Entry { var stamps: FileStamps?; var value: Value?; var probedAt: Date }
    private struct State { var entry: Entry?; var timeout: TimedOut? }

    private let now: @Sendable () -> Date
    private let negativeTTL: TimeInterval
    private let failureBackoff: TimeInterval
    private let states = KeyedStates<State>(State())

    /// `failureBackoff` is how long a directory whose git ran out of time is left alone (see
    /// ``answer(for:locate:read:)``).
    init(now: @escaping @Sendable () -> Date, negativeTTL: TimeInterval, failureBackoff: TimeInterval = TimedOut.backoff) {
        self.now = now; self.negativeTTL = negativeTTL; self.failureBackoff = failureBackoff
    }

    /// `locate` names the files to watch in `directory`, or `nil` when it is not a repository; `read`
    /// produces the value from the directory and those files, on a miss and whenever one of them has
    /// changed. The files are stamped before `read` runs, so one that changes while it does is read
    /// again next time. The directory's lock is held throughout, so neither runs twice for one
    /// directory at once, while other directories carry on.
    ///
    /// Either throws when git could not be asked — a timeout, say — which is not an answer and is
    /// never stored: the entry is left as it was, so the next call asks again. Meanwhile the value
    /// already known, if there is one, stands; with none, the error is thrown on to the caller.
    ///
    /// A git that *ran out of time* is not asked again at once: a hung mount costs its whole
    /// deadline on every ask, which every pass would pay. For `failureBackoff` seconds the directory
    /// is answered as it was after the failure — the known value, or the same error — without
    /// running git. That is a pause in asking, not a stored answer: the first call after it asks.
    func answer(for directory: String, locate: (String) throws -> [String]?,
                read: (_ directory: String, _ files: [String]) throws -> Value) throws -> Answer {
        try states.withState(for: directory) { state in
            if let timeout = state.timeout, timeout.isPending(now: now(), backoff: failureBackoff) {
                if let known = state.entry?.value { return .found(known) }
                throw timeout.error
            }
            do {
                let answer = try lookup(directory, in: &state.entry, locate: locate, read: read)
                state.timeout = nil
                return answer
            } catch {
                state.timeout = TimedOut(error, at: now())
                if let known = state.entry?.value { return .found(known) }
                throw error
            }
        }
    }

    /// Forgets every directory not in `live`: the cwds a tab has ever been in, negative entries
    /// included, would otherwise stay for as long as the app runs.
    func retain(only live: Set<String>) { states.retain(only: live) }

    private func lookup(_ directory: String, in entry: inout Entry?, locate: (String) throws -> [String]?,
                        read: (String, [String]) throws -> Value) throws -> Answer {
        guard let held = entry else { return try resolve(directory, in: &entry, locate: locate, read: read) }
        guard let stamps = held.stamps, let cached = held.value else {
            // Known not to be a repository; re-probe once in a while in case it became one.
            return now().timeIntervalSince(held.probedAt) < negativeTTL
                ? .notARepository : try resolve(directory, in: &entry, locate: locate, read: read)
        }
        let current = FileStamps(stamps.files)
        guard !current.noneExist else { return try resolve(directory, in: &entry, locate: locate, read: read) }
        guard current != stamps else { return .found(cached) }
        // A watched file moved: the checkout changed, but the repository it belongs to did not.
        let value = try read(directory, stamps.files)
        entry = Entry(stamps: current, value: value, probedAt: now())
        return .found(value)
    }

    private func resolve(_ directory: String, in entry: inout Entry?, locate: (String) throws -> [String]?,
                         read: (String, [String]) throws -> Value) throws -> Answer {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              let files = try locate(directory) else {
            entry = Entry(stamps: nil, value: nil, probedAt: now())
            return .notARepository
        }
        let stamps = FileStamps(files)
        let value = try read(directory, files)
        entry = Entry(stamps: stamps, value: value, probedAt: now())
        return .found(value)
    }
}

/// The three resolvers share probing, cache lifetime and empty-directory handling. Each keeps
/// its own watched files, value reader and mapping of missing or failed answers.
struct RepositoryResolver<Value: Sendable>: Sendable {
    let git: any GitRunning
    let probe: RepositoryProbe
    let cache: WatchedFileCache<Value>

    init(git: any GitRunning, now: @escaping @Sendable () -> Date, negativeTTL: TimeInterval, probe: RepositoryProbe?) {
        self.git = git
        self.probe = probe ?? RepositoryProbe(git: git, now: now, negativeTTL: negativeTTL)
        cache = WatchedFileCache(now: now, negativeTTL: negativeTTL)
    }

    func answer(for directory: String, locate: (RepositoryProbe.Locations) -> [String],
                read: (String, [String], any GitRunning) throws -> Value) throws -> WatchedFileCache<Value>.Answer {
        guard !directory.isEmpty else { return .notARepository }
        return try cache.answer(for: directory, locate: { try probe.locations(of: $0).map(locate) },
                                read: { try read($0, $1, git) })
    }
}

/// A `State` for each key, every one behind a lock of its own. What a cache does for one key — run
/// git, which can take a deadline's worth of seconds — holds up nobody asking about another, and
/// two callers asking about the same key do the work once, the second waiting for the first.
final class KeyedStates<State: Sendable>: Sendable {
    private final class Slot: Sendable {
        let state: Mutex<State>
        init(_ state: State) { self.state = Mutex(state) }
    }

    private let initial: State
    private let slots = Mutex<[String: Slot]>([:])

    init(_ initial: State) { self.initial = initial }

    /// `body` on `key`'s state, under that key's lock alone.
    func withState<Result>(for key: String, _ body: (inout State) throws -> Result) rethrows -> Result {
        let slot = slots.withLock { slots in
            if let slot = slots[key] { return slot }
            let slot = Slot(initial)
            slots[key] = slot
            return slot
        }
        return try slot.state.withLock { try body(&$0) }
    }

    /// Drops the state of every key not in `live`. A call still working on one finishes with it and
    /// nobody sees what it wrote.
    func retain(only live: Set<String>) {
        slots.withLock { slots in slots = slots.filter { live.contains($0.key) } }
    }
}
