import Foundation
@testable import AiTermCore

// The `GitRunner`s a test hands to what it tests, to see what git was asked or to make it fail.
// Each is a subclass that overrides `run` — every command, `runRemote` included, goes through it.
// `FlakyGitRunner` is the third; it has a file of its own. Unchecked because each one's stored
// `var`s are mutable: every access holds `lock`.

/// A `GitRunner` that counts how often it is actually asked to run something, and runs it for real
/// (without the developer's git configuration, as `GitRunner.hermetic()` does).
final class CountingGitRunner: GitRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    convenience init() { self.init(environment: GitRunner.hermeticEnvironment) }

    override func run(_ args: [String], in dir: String, timeout: TimeInterval = GitRunner.localTimeout) throws -> String {
        lock.withLock { _calls += 1 }
        return try super.run(args, in: dir, timeout: timeout)
    }
}

/// A `GitRunner` that records what it was asked to run, and with what deadline, and runs nothing —
/// unless `forwards` is set. `forwards` is set before any run.
final class RecordingGitRunner: GitRunner, @unchecked Sendable {
    struct Call: Equatable { var args: [String]; var timeout: TimeInterval }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    /// Runs every call for real, after recording it, when set.
    var forwards = false

    override func run(_ args: [String], in dir: String, timeout: TimeInterval = GitRunner.localTimeout) throws -> String {
        lock.withLock { _calls.append(Call(args: args, timeout: timeout)) }
        return forwards ? try super.run(args, in: dir, timeout: timeout) : ""
    }
}
