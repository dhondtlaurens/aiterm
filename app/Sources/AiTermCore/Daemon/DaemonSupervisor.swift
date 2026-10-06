import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Unchecked because every mutable property is read and written only on `queue` (`start`/`stop`
/// hop onto it, and the termination handler and timed work items run on it), which is what makes
/// sharing it safe.
public final class DaemonSupervisor: @unchecked Sendable {
    /// `.running` is a spawned child; `.listening` is that child once its socket accepts
    /// connections, which is when the app connects. `.adopted` means a daemon we did not start is
    /// serving the socket, so there is no child process of ours to supervise — the app connects to
    /// it exactly as it would to `.listening`.
    public enum State: Equatable, Sendable {
        case stopped, starting, running(pid: Int32), listening(pid: Int32), adopted, failed(attempt: Int, message: String)
    }

    /// Mirrors `EXIT_ALREADY_RUNNING` in `daemon/aitermd/__main__.py`: the daemon's way of saying
    /// "another instance already owns this socket", which is a reason to adopt that instance, not
    /// to restart. Any other non-zero status is a genuine crash.
    public static let alreadyRunningExitStatus: Int32 = 3

    /// How long a child has to open its socket before it counts as a failed launch. A daemon binds
    /// about a tenth of a second after the spawn, and under half a second on the first launch after
    /// a build; it compiles every module from source each time (`PYTHONDONTWRITEBYTECODE`), so a
    /// cold disk or a loaded machine can stretch that several times over. Fifteen seconds is far
    /// past any of those, and is as long as the app waits for any answer from the helper.
    public static let bindDeadline: TimeInterval = 15

    private let python: URL, daemonDir: URL, socketPath: String, hookPort: Int, arguments: [String]?
    private let logURL: URL
    private let adoptedProbeInterval: TimeInterval
    private let bindDeadline: TimeInterval
    private let backoff: @Sendable (_ attempt: Int) -> TimeInterval
    private let onStateChange: @Sendable (State) -> Void
    private var process: Process?
    /// Children given up on for never listening that may not have exited yet; `stop()` ends them.
    private var abandoned: [Process] = []
    private var attempt = 0
    private var stopping = false
    private var startedAt = Date.distantPast
    /// Whichever timed action is outstanding — a probe for a new child's socket, a backoff restart
    /// or an adopted-daemon liveness probe. Only ever one, and `stop()` cancels it.
    private var pendingWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "aiterm.supervisor")

    public init(python: URL, daemonDir: URL, socketPath: String, hookPort: Int = AiTermPaths.hookPort, arguments: [String]? = nil, logURL: URL = AiTermPaths.daemonLogURL, adoptedProbeInterval: TimeInterval = 5, bindDeadline: TimeInterval = DaemonSupervisor.bindDeadline, backoff: @escaping @Sendable (_ attempt: Int) -> TimeInterval = { Backoff.delay(attempt: $0) }, onStateChange: @escaping @Sendable (State) -> Void) {
        self.python = python; self.daemonDir = daemonDir; self.socketPath = socketPath; self.hookPort = hookPort; self.arguments = arguments; self.logURL = logURL; self.adoptedProbeInterval = adoptedProbeInterval; self.bindDeadline = bindDeadline; self.backoff = backoff; self.onStateChange = onStateChange
    }

    public func start() {
        queue.async { self.stopping = false; self.truncateLog(); self.launch() }
    }

    /// One launch's worth of log, not a forever-growing file: the log exists so the banner's
    /// "see …/aitermd.log" can be acted on, and a crash loop's last output is what matters.
    ///
    /// Emptied in place, never replaced: a daemon that already has the file open (an orphan about
    /// to be adopted, or one still exiting) would otherwise keep writing into an unlinked inode.
    private func truncateLog() {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 { close(fd) }
    }

    /// Append-mode handle for the child's stdout+stderr. `O_APPEND` makes every write land at the
    /// end of the file, so a second writer (an adopted daemon's) cannot overwrite the child's lines.
    /// `nil` (unwritable support directory, a read-only volume) means the child inherits our own
    /// descriptors, exactly as before — a daemon that runs without a log is far better than one
    /// that cannot be started at all.
    private func openLog() -> FileHandle? {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        var victims: [Process] = []
        queue.sync {
            self.stopping = true
            self.pendingWork?.cancel()
            self.pendingWork = nil
            victims = (self.process.map { [$0] } ?? []) + self.abandoned
            self.process = nil
            self.abandoned = []
            self.onStateChange(.stopped)
        }
        let running = victims.filter(\.isRunning)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        // Poll rather than block in `waitUntilExit()`: a daemon that ignored SIGTERM would
        // otherwise hang the quit forever. After the grace period it gets SIGKILL, which the
        // kernel always delivers.
        let deadline = Date().addingTimeInterval(Self.stopGracePeriod)
        while running.contains(where: \.isRunning), Date() < deadline { usleep(20_000) }
        let stuck = running.filter(\.isRunning)
        guard !stuck.isEmpty else { return }
        stuck.forEach { kill($0.processIdentifier, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(0.5)
        while stuck.contains(where: \.isRunning), Date() < killDeadline { usleep(20_000) }
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
        // Ruling T14-1: PYTHONPATH points inside the signed app bundle. Without this, the daemon
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
        process = p; startedAt = Date()
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
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping, child === self.process else { return }
            self.pendingWork = nil
            if SocketProbe.isLive(path: self.socketPath) { self.onStateChange(.listening(pid: child.processIdentifier)) }
            else if Date().timeIntervalSince(spawn) >= self.bindDeadline { self.abandon(child) }
            else { self.awaitListening(child, since: spawn) }
        }
        pendingWork = workItem
        queue.asyncAfter(deadline: .now() + (elapsed < 5 ? 0.02 : 0.5), execute: workItem)
    }

    /// Ends a child that never opened its socket and fails the launch, so it is restarted through
    /// the same backoff, and named in the same banner, as a child that exits. It is no longer
    /// `process` before it is ended, so its own exit is not counted a second time; it is kept in
    /// `abandoned` until it is gone, so a `stop()` meanwhile still waits for it.
    private func abandon(_ child: Process) {
        process = nil
        abandoned.removeAll { !$0.isRunning }
        abandoned.append(child)
        child.terminate()
        // One stuck where SIGTERM is not acted on gets SIGKILL after the grace `stop()` gives.
        let pid = child.processIdentifier
        queue.asyncAfter(deadline: .now() + Self.stopGracePeriod) { [weak self] in
            if child.isRunning { kill(pid, SIGKILL) }
            self?.abandoned.removeAll { !$0.isRunning }
        }
        recordFailure(message: "did not open its socket within \(Int(bindDeadline.rounded())) s")
    }

    /// Not `private`, so a test can hand it a foreign `Process` to prove the guard below. The app
    /// calls it only from `launch()`'s `terminationHandler`, always on `queue`. That test calls it
    /// from its own thread, while the supervised child runs on and nothing on `queue` writes the
    /// state the guard reads.
    func exited(_ proc: Process) {
        // `proc` is whichever child's `terminationHandler` fired; a `launch()` since it started
        // (a restart, an adoption handoff) can have moved `process` on before its callback runs.
        // Without this guard, that stale callback would restart or adopt on top of the process
        // that already replaced it.
        guard !stopping, proc === process else { return }
        // A child that exits before it listens leaves its socket probe behind.
        pendingWork?.cancel(); pendingWork = nil
        // A daemon that refused to start because one is already running is not a crash: the app
        // wants *that* daemon. Restarting instead is what produced the "Daemon keeps exiting"
        // loop, since every retry hit the same live socket.
        if proc.terminationStatus == Self.alreadyRunningExitStatus { adopt(); return }
        if Date().timeIntervalSince(startedAt) > 60 { attempt = 0 }
        recordFailure(message: "exited with status \(proc.terminationStatus)")
    }

    private func adopt() {
        attempt = 0
        process = nil
        onStateChange(.adopted)
        scheduleAdoptedProbe()
    }

    /// Adoption gives up the termination callback that tells us an owned daemon died, so the only
    /// way to notice an adopted one going away is to ask the socket. When it stops answering we
    /// take over and start our own.
    private func scheduleAdoptedProbe() {
        guard !stopping else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping else { return }
            self.pendingWork = nil
            if SocketProbe.isLive(path: self.socketPath) { self.scheduleAdoptedProbe() } else { self.launch() }
        }
        pendingWork = workItem
        queue.asyncAfter(deadline: .now() + adoptedProbeInterval, execute: workItem)
    }

    /// Shared bookkeeping for the "process never started" (`launch()`'s `catch`), "process started
    /// then exited" (`exited()`) and "process never listened" (`abandon(_:)`) failure paths, so all
    /// escalate the same attempt counter and backoff delay instead of the launch-failure path
    /// retrying forever at `Backoff.delay(0)`.
    private func recordFailure(message: String) {
        attempt += 1
        onStateChange(.failed(attempt: attempt, message: message))
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopping else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping else { return }
            self.pendingWork = nil
            self.launch()
        }
        pendingWork = workItem
        queue.asyncAfter(deadline: .now() + backoff(attempt - 1), execute: workItem)
    }
}
