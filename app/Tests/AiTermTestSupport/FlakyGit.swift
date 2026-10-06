import Foundation
import Synchronization
import AiTermCore

/// A git whose commands time out while `failing` is set, as they do under load — every command,
/// so the resolvers' directory lookups fail along with their reads — and run for real otherwise.
final class FlakyGitRunner: GitRunning {
    private let inner: any GitRunning
    private let state = Mutex((failing: false, calls: 0))

    init(_ inner: any GitRunning = GitRunner.hermetic()) { self.inner = inner }

    var failing: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }
    /// How many commands were asked of it, the failed ones included.
    var calls: Int { state.withLock { $0.calls } }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        let fail = state.withLock { $0.calls += 1; return $0.failing }
        if fail { throw GitError(args: args, code: 15, stderr: "git timed out after \(timeout) s", timedOut: true) }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
