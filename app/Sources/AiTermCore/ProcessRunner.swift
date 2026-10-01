import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// What a finished child process said. `timedOut` means it was stopped at its deadline.
public struct ProcessOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// The one way AiTerm runs a child process — git, the login shell, a Python probe, an agent CLI.
/// Blocking: call it off the main actor.
///
/// Standard input is closed, so a child that reads it sees EOF instead of waiting on the app.
/// Both pipes are drained at once: a pipe's kernel buffer is ~64 KB, and a child that fills one
/// while its parent is blocked reading the other waits forever. The readers are `Thread`s, not
/// `DispatchQueue.global()` work: that queue is non-overcommit and shares its kernel work queue
/// with Swift concurrency's cooperative pool, so once as many callers are parked here as there
/// are cores — which is exactly what the parallel test runner does — no worker is left to start a
/// drain and every caller waits forever. A real thread is always available.
///
/// With a `timeout`, a child still running at the deadline is sent SIGTERM and, if it ignores
/// that, SIGKILL — which the kernel always delivers.
///
/// The child's exit, not its pipes' EOF, ends the run: a grandchild can hold them open long after
/// the child is gone — an rc file's `eval "$(tool init)"`, `ssh` under git, a `curl | sh` — and a
/// run waiting for it would outlast any deadline. The pipes get a moment's grace to deliver what
/// the child wrote, and what was read by then is the output; their readers carry on alone until
/// the grandchild lets go.
public enum ProcessRunner {
    /// How long past the child's exit its pipes may take to reach EOF.
    static let drainGrace: TimeInterval = 1

    /// `environment` minus what makes a child check in with LaunchServices as AiTerm itself:
    /// `__CFBundleIdentifier` and the `XPC_*` launch keys. A child carrying them once gave the app a
    /// second Dock icon (`osascript` under the daemon); the update helper's `open` would otherwise
    /// run as the app that just quit.
    public static func withoutLaunchIdentity(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in key != "__CFBundleIdentifier" && !key.hasPrefix("XPC_") && !key.hasPrefix("__XPC_") }
    }

    /// The environment a child gets unless told otherwise: the app's own, minus its launch identity.
    public static var inheritedEnvironment: [String: String] { withoutLaunchIdentity(ProcessInfo.processInfo.environment) }

    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           in directory: URL? = nil, timeout: TimeInterval? = nil) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? inheritedEnvironment
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let drained = DispatchGroup()
        let stdout = Drain(out, group: drained), stderr = Drain(err, group: drained)
        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
                timedOut = true
                process.terminate()
                if exited.wait(timeout: .now() + 0.2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                }
            }
        } else {
            exited.wait()
        }
        _ = drained.wait(timeout: .now() + drainGrace)
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus, stdout: stdout.text, stderr: stderr.text, timedOut: timedOut)
    }

    /// Reads one pipe to EOF on its own thread, a chunk at a time, so `text` has what arrived so
    /// far when the run stops waiting before EOF. The thread keeps itself alive until then.
    private final class Drain: Sendable {
        private let data = Mutex(Data())

        init(_ pipe: Pipe, group: DispatchGroup) {
            group.enter()
            let thread = Thread { [self] in
                // `read(2)` itself: `FileHandle.read(upToCount:)` waits to fill the whole count.
                let fd = pipe.fileHandleForReading.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { break }
                    data.withLock { $0.append(contentsOf: buffer[..<n]) }
                }
                group.leave()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }

        var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
    }
}
