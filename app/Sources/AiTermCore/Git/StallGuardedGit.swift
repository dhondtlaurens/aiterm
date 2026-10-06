import Foundation
import Synchronization

/// The git a checkout monitor's pass runs, which gives up on a project once git has run out of time
/// in it. A project on a dead mount makes every git there wait its whole deadline, and a pass asks
/// about the project, each of its tabs and each of its tasks one by one: ten seconds each, so one
/// hung project held up every other project's branch and diff by a minute or more.
///
/// The first command of a project that times out marks the project as stalled. For `backoff`
/// seconds every other command in it — the tabs inside it, its tasks' worktrees, the other
/// resolvers — fails at once with a timeout of its own, without starting git, so the resolvers
/// treat it as they treat any timeout: the last known value stands and nothing is stored as an
/// answer. Other projects are untouched. After the backoff the next command runs for real.
///
/// The caches that back off per directory (``WatchedFileCache``, ``RepositoryProbe``) or per
/// worktree (``DiffStatResolver``) record those synthetic timeouts as their own, and hold their key
/// back from when they got one. So a directory first asked about late in a project's stall is held
/// back up to a backoff past the stall's end — about 30 s longer than the project. Harmless: the project was just unreachable, and the last known
/// value stands meanwhile, as it would for a timeout of the directory's own.
///
/// A directory belongs to the project whose folder, or whose task's worktree, it is in or under
/// (``scope(projects:tasks:)``); any other directory is a project of its own.
///
/// Thread-safe.
public final class StallGuardedGit: GitRunning {
    private struct State {
        /// Folder and the project it belongs to, longest folder first so the nearest owner wins.
        var owners: [(folder: String, project: String)] = []
        /// The timeout that stalled each project.
        var stalls: [String: TimedOut] = [:]
    }

    private let inner: any GitRunning
    private let now: @Sendable () -> Date
    private let backoff: TimeInterval
    private let state = Mutex(State())

    public convenience init(_ inner: any GitRunning) { self.init(inner, now: Date.init) }

    init(_ inner: any GitRunning, now: @escaping @Sendable () -> Date, backoff: TimeInterval = TimedOut.backoff) {
        self.inner = inner; self.now = now; self.backoff = backoff
    }

    /// Which project each folder belongs to: the projects' own, and their tasks' worktrees, which
    /// are not always under the project's folder (an imported worktree can be anywhere). Folders
    /// are compared without trailing slashes, and an empty one — a task with no worktree path —
    /// owns nothing: as a prefix it would own every folder there is.
    public func scope(projects: [Project], tasks: [TaskItem]) {
        let paths = Dictionary(projects.map { ($0.id, Self.folder($0.path)) }, uniquingKeysWith: { first, _ in first })
        var owners = paths.values.map { (folder: $0, project: $0) }
        for task in tasks { if let project = paths[task.projectId] { owners.append((Self.folder(task.worktreePath), project)) } }
        owners.removeAll { $0.folder.isEmpty || $0.project.isEmpty }
        owners.sort { $0.folder.count > $1.folder.count }
        state.withLock { $0.owners = owners }
    }

    /// `path` less its trailing slashes, so `/a/b/` and `/a/b` are one folder. The root stays `/`:
    /// stripped to nothing it would be the empty folder, which owns nothing.
    private static func folder(_ path: String) -> String {
        var folder = path
        while folder.hasSuffix("/") { folder.removeLast() }
        return folder.isEmpty && !path.isEmpty ? "/" : folder
    }

    public func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        let project = state.withLock { state -> String in
            state.owners.first { dir == $0.folder || dir.hasPrefix($0.folder + "/") }?.project ?? Self.folder(dir)
        }
        if let stall = stall(of: project) {
            // The timeout that stalled the project, not this command's deadline, which it never met.
            let ago = Int(now().timeIntervalSince(stall.at))
            throw GitError(args: args, code: 15, stderr: "git was not run: \(stall.error.stderr) in \(project) \(ago) s ago", timedOut: true)
        }
        do { return try inner.run(args, in: dir, timeout: timeout, environment: environment) }
        catch {
            guard let stall = TimedOut(error, at: now()) else { throw error }
            state.withLock { state in
                state.stalls = state.stalls.filter { $0.value.isPending(now: stall.at, backoff: backoff) }
                state.stalls[project] = stall
            }
            throw error
        }
    }

    private func stall(of project: String) -> TimedOut? {
        state.withLock { state in
            guard let stall = state.stalls[project], stall.isPending(now: now(), backoff: backoff) else { return nil }
            return stall
        }
    }
}
