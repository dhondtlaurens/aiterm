import Foundation
@testable import AiTermCore

/// A `GitRunner` whose commands time out while `failing` is set, as they do under load — every
/// command, so the resolvers' directory lookups fail along with their reads — and run for real
/// otherwise.
///
/// Unchecked because its stored `var`s are mutable: every access holds `lock`.
final class FlakyGitRunner: GitRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _failing = false
    private var _calls = 0

    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    /// How many commands were asked of it, the failed ones included.
    var calls: Int { lock.withLock { _calls } }

    convenience init() { self.init(environment: GitRunner.hermeticEnvironment) }

    override func run(_ args: [String], in dir: String, timeout: TimeInterval = GitRunner.localTimeout) throws -> String {
        let fail = lock.withLock { _calls += 1; return _failing }
        if fail { throw GitError(args: args, code: 15, stderr: "git timed out after \(timeout) s") }
        return try super.run(args, in: dir, timeout: timeout)
    }
}
