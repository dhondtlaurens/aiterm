import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// A child that may run for minutes — an agent's headless run, a fix's `verify`. Unlike
/// `ProcessRunner`, nothing waits on a thread for it: its exit arrives through a dispatch process
/// source. It leads a process group of its own, so a timeout or a cancellation ends everything it
/// started — the git it ran, a test runner's workers — and the call returns (or throws
/// `CancellationError`) only once the group is gone, after a normal exit as well: a job the child
/// left in the background does not outlive the run. Output past `outputLimit` per stream is dropped.
public enum AgentProcess {
    /// How long a group gets to leave on SIGTERM before SIGKILL.
    static let termGrace: DispatchTimeInterval = .seconds(2)
    /// How long past the kill the group's last members may take to be reaped.
    static let goneGrace: Duration = .seconds(10)
    /// Dropped from every child's environment: the terminal's identity, which a hook would report.
    static let strippedEnvironment = ["ITERM_SESSION_ID", "TERM_SESSION_ID", "ITERM_PROFILE"]

    public static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                           in directory: String, timeout: Duration, outputLimit: Int = 4 << 20) async throws -> ProcessOutput {
        var env = ProcessRunner.inheritedEnvironment
        // A hook that still fires must not name the tab AiTerm itself was started from (spikes).
        for key in strippedEnvironment { env.removeValue(forKey: key) }
        for (k, v) in environment { env[k] = v }
        let child = try Spawned(executable, arguments, environment: env, directory: directory, outputLimit: outputLimit)
        // Not a child of the call: nothing awaits it, so a child that exits at once leaves nothing
        // to wait for; it is cancelled as soon as the run is over.
        let deadline = Task {
            try await Task.sleep(for: timeout)
            child.terminate(timedOut: true)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            await child.exited()
            deadline.cancel()
            await child.groupGone()
            try Task.checkCancellation()
            await child.drained()
            return child.output()
        } onCancel: {
            child.terminate(timedOut: false)
        }
    }
}

/// One spawned child: `posix_spawn` as the leader of a new process group, its two pipes drained on
/// threads of their own (see `ProcessRunner` for why not the shared queue), its exit observed by a
/// `DispatchSource`.
private final class Spawned: Sendable {
    /// What the exit handler and `terminate` share, always under one lock: the group may be
    /// signalled only while its leader is not yet reaped, because after that its id can be reused.
    private struct State {
        var reaped = false
        var terminating = false
        var timedOut = false
        var status: Int32 = 0
    }

    let pid: pid_t
    private let exit = AsyncLatch()
    private let drains = Countdown(2)
    private let stdout: CappedDrain, stderr: CappedDrain
    private let state = Mutex(State())

    init(_ executable: String, _ arguments: [String], environment: [String: String], directory: String,
         outputLimit: Int) throws {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE) }
        guard pipe(&errPipe) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EMFILE
            close(outPipe[0]); close(outPipe[1])
            throw POSIXError(code)
        }
        // No other child spawned meanwhile may inherit these ends and keep a pipe open.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, directory)
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The child starts with default signal handling: an app that ignores or blocks a signal
        // (SIGTERM among them) would otherwise hand that on, and the group would not leave on TERM.
        var everySignal = sigset_t(), noSignal = sigset_t()
        sigfillset(&everySignal)
        sigemptyset(&noSignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        // CLOEXEC_DEFAULT: nothing but 0, 1 and 2 reaches the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var spawned: pid_t = 0
        let result = posix_spawn(&spawned, executable, &actions, &attributes, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .ENOENT)
        }
        pid = spawned
        let onEnd: @Sendable () -> Void = { [drains] in drains.countOne() }
        stdout = CappedDrain(fd: outPipe[0], limit: outputLimit, onEnd: onEnd)
        stderr = CappedDrain(fd: errPipe[0], limit: outputLimit, onEnd: onEnd)

        let source = DispatchSource.makeProcessSource(identifier: spawned, eventMask: .exit, queue: .global(qos: .utility))
        let held = Mutex<(any DispatchSourceProcess)?>(source)
        source.setEventHandler { [self] in
            state.withLock { s in
                // Whatever the leader left behind goes, however it ended — a background job must not
                // outlive the run in the clone — while its zombie still holds the group's id.
                killpg(pid, SIGKILL)
                var raw: Int32 = 0
                while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
                s.status = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                s.reaped = true
            }
            held.withLock { $0?.cancel(); $0 = nil }
            exit.open()
        }
        source.resume()
    }

    func exited() async { await exit.wait() }

    /// SIGTERM to the group now, SIGKILL after a grace. Returns at once; `exited` and `groupGone`
    /// wait for the end. Does nothing once the leader has been reaped (its id may be someone else's)
    /// or when already under way.
    func terminate(timedOut: Bool) {
        let started = state.withLock { s -> Bool in
            guard !s.reaped, !s.terminating else { return false }
            s.terminating = true
            s.timedOut = timedOut
            killpg(pid, SIGTERM)
            return true
        }
        guard started else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + AgentProcess.termGrace) { [self] in
            state.withLock { s in if !s.reaped { killpg(pid, SIGKILL) } }
        }
    }

    /// After the exit, whatever ended it: waits until no member of the group is left to signal. A grandchild that left
    /// the group itself (`setsid`) is beyond reach; agents' tools do not do that.
    func groupGone() async {
        // Cleanup must outlive the caller's cancellation. In a cancelled task every sleep throws
        // immediately, so a group still leaving would be polled continuously until the deadline.
        await Task { [pid] in
            let deadline = ContinuousClock.now + AgentProcess.goneGrace
            // Signal 0 only checks; a SIGKILLed member may linger until its parent reaps it.
            while killpg(pid, 0) == 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }.value
    }

    /// Gives the pipes a moment past the exit to deliver what was written (see `ProcessRunner`).
    func drained() async {
        let timer = DispatchWorkItem { [drains] in drains.giveUp() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ProcessRunner.drainGrace, execute: timer)
        await drains.wait()
        timer.cancel()
    }

    func output() -> ProcessOutput {
        let (status, timedOut) = state.withLock { ($0.status, $0.timedOut) }
        return ProcessOutput(status: status, stdout: stdout.text(), stderr: stderr.text(), timedOut: timedOut)
    }
}

/// Opens once; every waiter, before or after, resumes.
private final class AsyncLatch: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { c in
            let resumeNow = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

/// Opens its latch when `count` pipes have reached EOF, or when told to stop waiting for them.
private final class Countdown: Sendable {
    private let left: Mutex<Int>
    private let latch = AsyncLatch()
    init(_ count: Int) { left = Mutex(count) }
    func countOne() { if left.withLock({ $0 -= 1; return $0 }) == 0 { latch.open() } }
    func giveUp() { latch.open() }
    func wait() async { await latch.wait() }
}

/// Reads a pipe to EOF on a thread of its own, keeping the first `limit` bytes and dropping the
/// rest (still reading, so the child never blocks on a full pipe).
private final class CappedDrain: Sendable {
    private let data = Mutex(Data())

    init(fd: Int32, limit: Int, onEnd: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                data.withLock { d in
                    let room = limit - d.count
                    if room > 0 { d.append(contentsOf: buffer[..<min(n, room)]) }
                }
            }
            close(fd)
            onEnd()
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func text() -> String { data.withLock { String(decoding: $0, as: UTF8.self) } }
}
