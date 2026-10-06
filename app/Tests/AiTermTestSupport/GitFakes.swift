import Foundation
import Synchronization
import AiTermCore

// The `GitRunning`s a test hands to what it tests, to see what git was asked or to make it fail.
// Each wraps a runner that does the work (hermetic git unless told otherwise) and sees every
// command, `runRemote` and the calls with an environment of their own included, because all of
// them end in `run(_:in:timeout:environment:)`. `FlakyGitRunner` is another; it has a file of its own.

/// Counts how often git is actually asked to run something, and runs it.
final class CountingGitRunner: GitRunning {
    private let inner: any GitRunning
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }

    init(_ inner: any GitRunning = GitRunner.hermetic()) { self.inner = inner }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        count.withLock { $0 += 1 }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}

/// Records what it was asked to run, and with what deadline, and runs nothing — unless it was
/// given a runner to `forward` to.
final class RecordingGitRunner: GitRunning {
    struct Call: Equatable { var args: [String]; var timeout: TimeInterval }
    private let log = Mutex<[Call]>([])
    private let forward: (any GitRunning)?
    var calls: [Call] { log.withLock { $0 } }

    init(forwardingTo forward: (any GitRunning)? = nil) { self.forward = forward }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        log.withLock { $0.append(Call(args: args, timeout: timeout)) }
        return try forward?.run(args, in: dir, timeout: timeout, environment: environment) ?? ""
    }
}

/// Times out every command that starts with one of `commands` — `["merge-base"]`, `["remote",
/// "get-url"]` — as git killed at its deadline does, and runs the rest. `code` is the status the
/// timed-out command reports: SIGTERM's, unless a test needs one that is also an answer.
final class TimingOutGitRunner: GitRunning {
    private let inner: any GitRunning
    private let commands: [[String]]
    private let code: Int32

    init(_ commands: [String]..., code: Int32 = 15, inner: any GitRunning = GitRunner.hermetic()) {
        self.commands = commands
        self.code = code
        self.inner = inner
    }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if commands.contains(where: { args.starts(with: $0) }) {
            throw GitError(args: args, code: code, stderr: "git \(args.first ?? "") timed out after \(timeout) s", timedOut: true)
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
