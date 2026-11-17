import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// Its work runs on `queue` (`start`/`stop` hop onto it, and the termination handler and timed
/// actions run on it), which keeps launches, exits and probes in order; what that work changes is
/// in `state`, so the compiler, not that convention, keeps every access under its lock.
public final class DaemonSupervisor: Sendable {
    /// `.running` is a spawned child; `.listening` is that child once its socket accepts
    /// connections, which is when the app connects. The app only ever talks to a helper it started.
    public enum State: Equatable, Sendable {
        case stopped, starting, running(pid: Int32), listening(pid: Int32), failed(attempt: Int, message: String)
    }

    /// Mirrors `EXIT_ALREADY_RUNNING` in `daemon/aitermd/__main__.py`: the daemon's way of saying
    /// "another instance already owns this socket". That instance is a stale helper (one an app
    /// that crashed or was force-quit left behind), so it is ended and the child started again
    /// (`replaceStaleHelpers`). Any other non-zero status is a genuine crash.
    public static let alreadyRunningExitStatus: Int32 = 3

    /// How long a child has to open its socket before it counts as a failed launch. A daemon binds
    /// about a tenth of a second after the spawn, and under half a second on the first launch after
    /// a build; it compiles every module from source each time (`PYTHONDONTWRITEBYTECODE`), so a
    /// cold disk or a loaded machine can stretch that several times over. Fifteen seconds is far
    /// past any of those, and is as long as the app waits for any answer from the helper.
    public static let bindDeadline: TimeInterval = 15

    private let python: URL, daemonDir: URL, socketPath: String, hookPort: Int, arguments: [String]?
    private let logURL: URL
    private let bindDeadline: TimeInterval
    private let backoff: @Sendable (_ attempt: Int) -> TimeInterval
    private let onStateChange: @Sendable (State) -> Void
    private struct Supervision {
        var process: Process?
        /// Children given up on for never listening that have not exited yet; `stop()` ends them.
        var abandoned: [Process] = []
        var attempt = 0
        var stopping = false
        var startedAt = Date.distantPast
        /// Names the one timed action still to run — a probe for a new child's socket or a backoff
        /// restart. Scheduling another, an exit and `stop()` each bump it, which cancels the one
        /// outstanding.
        var scheduled = 0
    }
    private let state = Mutex(Supervision())
    private let queue = DispatchQueue(label: "aiterm.supervisor")

    public init(python: URL, daemonDir: URL, socketPath: String, hookPort: Int = AiTermPaths.hookPort, arguments: [String]? = nil, logURL: URL = AiTermPaths.daemonLogURL, bindDeadline: TimeInterval = DaemonSupervisor.bindDeadline, backoff: @escaping @Sendable (_ attempt: Int) -> TimeInterval = { Backoff.delay(attempt: $0) }, onStateChange: @escaping @Sendable (State) -> Void) {
        self.python = python; self.daemonDir = daemonDir; self.socketPath = socketPath; self.hookPort = hookPort; self.arguments = arguments; self.logURL = logURL; self.bindDeadline = bindDeadline; self.backoff = backoff; self.onStateChange = onStateChange
    }

    public func start() {
        queue.async {
            self.state.withLock { $0.stopping = false }
            self.truncateLog()
            self.launch()
        }
    }

    /// One launch's worth of log, not a forever-growing file: the log exists so the banner's
    /// "see …/aitermd.log" can be acted on, and a crash loop's last output is what matters.
    ///
    /// Emptied in place, never replaced: a daemon that already has the file open (a stale helper
    /// about to be ended, or one still exiting) would otherwise keep writing into an unlinked inode.
    private func truncateLog() {
        makeLogFolder()
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 { close(fd) }
    }

    /// Without it the helper still starts, with no log of its own (`openLog`).
    private func makeLogFolder() {
        Log.daemon.attempt("Making the helper's log folder") {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    /// Append-mode handle for the child's stdout+stderr. `O_APPEND` makes every write land at the
    /// end of the file, so a second writer (a stale helper's) cannot overwrite the child's lines.
    /// `nil` (unwritable support directory, a read-only volume) means the child inherits our own
    /// descriptors, exactly as before — a daemon that runs without a log is far better than one
    /// that cannot be started at all.
    private func openLog() -> FileHandle? {
        makeLogFolder()
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    /// How long `stop()` waits for the daemon to act on SIGTERM before resorting to SIGKILL.
    public static let stopGracePeriod: TimeInterval = 2

    /// Synchronous with respect to termination: when this returns, the daemon process is gone.
    /// `AppController.shutdown()` calls it from `applicationWillTerminate(_:)`, where merely
    /// *enqueueing* a `terminate()` loses the race with AppKit tearing the app down — and an
    /// orphaned daemon still holding the socket makes the next launch refuse to start.
    /// Must not be called from `queue` itself (`queue.sync` would deadlock); nothing in this type
    /// does, `stop()` is only ever called from outside.
    public func stop() {
        let victims = queue.sync {
            let victims = state.withLock { state in
                state.stopping = true
                state.scheduled += 1
                let victims = (state.process.map { [$0] } ?? []) + state.abandoned
                state.process = nil; state.abandoned = []
                return victims
            }
            onStateChange(.stopped)
            return victims
        }
        let running = victims.filter(\.isRunning)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        Self.awaitEnd(running.map { child in (child.processIdentifier, { child.isRunning }) })
    }

    /// Waits for processes already sent SIGTERM to exit, and sends SIGKILL to those still running
    /// after `stopGracePeriod`, waiting up to half a second more. Polls rather than blocks in
    /// `waitUntilExit()`: a daemon that ignored SIGTERM would otherwise hang the caller forever;
    /// SIGKILL the kernel always delivers.
    private static func awaitEnd(_ processes: [(pid: Int32, isRunning: () -> Bool)]) {
        let deadline = Date().addingTimeInterval(stopGracePeriod)
        while processes.contains(where: { $0.isRunning() }), Date() < deadline { usleep(20_000) }
        let stuck = processes.filter { $0.isRunning() }
        guard !stuck.isEmpty else { return }
        stuck.forEach { kill($0.pid, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(0.5)
        while stuck.contains(where: { $0.isRunning() }), Date() < killDeadline { usleep(20_000) }
    }

    /// The pids in a process listing (one process per line: its pid, then its full command line,
    /// as `ps -o pid=,command=` prints it) whose command line runs `aitermd run --socket` on exactly
    /// `socketPath`. `ps` joins the arguments with spaces and the path itself can hold one
    /// (`Application Support`), so the match is on that text, followed by a space or the end of
    /// the line: another socket, or one whose path merely starts with this one, does not match.
    /// Whatever runs the module in front of it does not matter.
    static func helperPids(holding socketPath: String, in listing: String) -> [Int32] {
        let needle = "aitermd run --socket " + socketPath
        return listing.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.drop { $0 == " " }
            guard let space = fields.firstIndex(of: " "), let pid = Int32(fields[..<space]) else { return nil }
            let command = fields[space...]
            let runsHelper = command.ranges(of: needle).contains { match in
                match.upperBound == command.endIndex || command[match.upperBound] == " "
            }
            return runsHelper ? pid : nil
        }
    }

    /// `--cookies-from-app`: the daemon asks this app for each iTerm2 API cookie instead of running
    /// osascript. macOS attributes every process AiTerm starts to AiTerm, whatever its environment,
    /// so each osascript checked in as a second foreground AiTerm and bounced a Dock icon of its own.
    static func arguments(socketPath: String, hookPort: Int) -> [String] {
        ["-m", "aitermd", "run", "--socket", socketPath, "--hook-port", String(hookPort), "--cookies-from-app"]
    }

    /// The app's environment minus its launch identity. LaunchServices hands AiTerm
    /// `__CFBundleIdentifier` and `XPC_SERVICE_NAME`; a child that inherits them claims to be
    /// AiTerm. Stripping them was not enough to keep osascript out of the Dock (see `arguments`).
    static func daemonEnvironment(inheriting inherited: [String: String], daemonDir: URL) -> [String: String] {
        var env = ProcessRunner.withoutLaunchIdentity(inherited)
        env["PYTHONPATH"] = daemonDir.path; env["PYTHONUNBUFFERED"] = "1"
        // PYTHONPATH points inside the signed app bundle. Without this, the daemon
        // writes `__pycache__/*.pyc` next to its own modules on every launch, which breaks the
        // bundle's code signature (`codesign --verify --deep --strict` fails after the first run).
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env
    }

    private func launch() {
        let p = Process()
        p.executableURL = python
        p.arguments = arguments ?? Self.arguments(socketPath: socketPath, hookPort: hookPort)
        p.currentDirectoryURL = daemonDir
        p.environment = Self.daemonEnvironment(inheriting: ProcessInfo.processInfo.environment, daemonDir: daemonDir)
        if let log = openLog() { p.standardOutput = log; p.standardError = log }
        p.terminationHandler = { [weak self] proc in self?.queue.async { [weak self] in self?.exited(proc) } }
        onStateChange(.starting)
        do { try p.run() } catch { recordFailure(message: error.localizedDescription); return }
        state.withLock { $0.process = p; $0.startedAt = Date() }
        onStateChange(.running(pid: p.processIdentifier))
        awaitListening(p)
    }

    /// Probes the socket until the child accepts on it, then reports `.listening`. A daemon binds
    /// its socket only once Python has imported `iterm2` and started asyncio, a tenth of a second
    /// or more after the spawn: an app that connected on `.running` met a missing socket, said
    /// "Reconnecting to AiTerm’s helper…" on every launch and waited out a one-second backoff for
    /// its first snapshot. A probe is a bare `connect()`, so asking often costs nothing; after the
    /// first few seconds a child that is still not listening is asked less often, and one that is
    /// not listening by `bindDeadline` is a failed launch. A child that exits first is
    /// `exited(_:)`'s, which cancels the probe.
    private func awaitListening(_ child: Process, since spawn: Date = Date()) {
        let elapsed = Date().timeIntervalSince(spawn)
        schedule(after: elapsed < 5 ? 0.02 : 0.5) { supervisor in
            guard supervisor.state.withLock({ child === $0.process }) else { return }
            if SocketProbe.isLive(path: supervisor.socketPath) { supervisor.onStateChange(.listening(pid: child.processIdentifier)) }
            else if Date().timeIntervalSince(spawn) >= supervisor.bindDeadline { supervisor.abandon(child) }
            else { supervisor.awaitListening(child, since: spawn) }
        }
    }

    /// Ends a child that never opened its socket and fails the launch, so it is restarted through
    /// the same backoff, and named in the same banner, as a child that exits. It is no longer
    /// `process` before it is ended, so its own exit is not counted a second time; it is kept in
    /// `abandoned` until `exited(_:)` hears it is gone, so a `stop()` meanwhile still waits for it.
    private func abandon(_ child: Process) {
        state.withLock { $0.process = nil; $0.abandoned.append(child) }
        child.terminate()
        // One stuck where SIGTERM is not acted on gets SIGKILL after the grace `stop()` gives.
        let pid = child.processIdentifier
        queue.asyncAfter(deadline: .now() + Self.stopGracePeriod) {
            if child.isRunning { kill(pid, SIGKILL) }
        }
        recordFailure(message: "did not open its socket within \(Int(bindDeadline.rounded())) s")
    }

    /// Not `private`, so a test can hand it a foreign `Process` to prove the guard below. The app
    /// calls it only from `launch()`'s `terminationHandler`, always on `queue`; that test calls it
    /// from its own thread, which `state`'s lock makes safe.
    func exited(_ proc: Process) {
        let supervised = state.withLock { state in
            // Reaped: an abandoned child leaves nothing for `stop()` to wait for.
            state.abandoned.removeAll { $0 === proc }
            // `proc` is whichever child's `terminationHandler` fired; a `launch()` since it started
            // (a restart) can have moved `process` on before its callback runs. Without this
            // guard, that stale callback would restart on top of the process that already
            // replaced it.
            guard !state.stopping, proc === state.process else { return false }
            // A child that exits before it listens leaves its socket probe behind.
            state.scheduled += 1
            return true
        }
        guard supervised else { return }
        if proc.terminationStatus == Self.alreadyRunningExitStatus { replaceStaleHelpers(); return }
        state.withLock { if Date().timeIntervalSince($0.startedAt) > 60 { $0.attempt = 0 } }
        recordFailure(message: "exited with status \(proc.terminationStatus)")
    }

    /// A child that refused to start because the socket is held: a helper an app that crashed or
    /// was force-quit left behind still serves it, maybe from another build. It is found by its command
    /// line, ended as `stop()` ends a child, and the child started again at once. With none found,
    /// or none that could be signalled, the launch has failed and is retried through the backoff,
    /// so a socket held by something else cannot spin this loop.
    private func replaceStaleHelpers() {
        let listing = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-axww", "-o", "pid=,command="], timeout: 2)
        let found = listing.map { $0.status == 0 && !$0.timedOut ? Self.helperPids(holding: socketPath, in: $0.stdout) : [] } ?? []
        let signalled = found.filter { kill($0, SIGTERM) == 0 }
        guard !signalled.isEmpty else {
            recordFailure(message: "its socket is held by another process")
            return
        }
        Log.daemon.notice("Ending the stale helper that holds the socket, pid \(signalled.map(String.init).joined(separator: ", "), privacy: .public)")
        Self.awaitEnd(signalled.map { pid in (pid, { kill(pid, 0) == 0 }) })
        launch()
    }

    /// Shared bookkeeping for the "process never started" (`launch()`'s `catch`), "process started
    /// then exited" (`exited()`) and "process never listened" (`abandon(_:)`) failure paths, so all
    /// escalate the same attempt counter and backoff delay instead of the launch-failure path
    /// retrying forever at `Backoff.delay(0)`.
    private func recordFailure(message: String) {
        let attempt = state.withLock { $0.attempt += 1; return $0.attempt }
        onStateChange(.failed(attempt: attempt, message: message))
        schedule(after: backoff(attempt - 1)) { $0.launch() }
    }

    /// Runs `action` on `queue` after `delay`, unless the supervisor is stopping by then or the
    /// action has been cancelled (see `Supervision.scheduled`) — and replaces any still waiting.
    private func schedule(after delay: TimeInterval, _ action: @escaping @Sendable (DaemonSupervisor) -> Void) {
        guard let token = state.withLock({ state -> Int? in
            guard !state.stopping else { return nil }
            state.scheduled += 1
            return state.scheduled
        }) else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state.withLock({ !$0.stopping && $0.scheduled == token }) else { return }
            action(self)
        }
    }
}
