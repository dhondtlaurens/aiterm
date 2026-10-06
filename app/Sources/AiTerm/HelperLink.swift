import Foundation
import AiTermCore

/// The app's link to its helper: the daemon process, the socket connection to it and how far the
/// chain to iTerm2 reaches. Process health, socket health and iTerm2's own availability are kept
/// apart — a running helper is not a connected one. Every event the connection delivers goes on to
/// `onEvent` once the link has taken what is its own.
@MainActor
@Observable
final class HelperLink {
    /// How far the chain to iTerm2 reaches. The sidebar banner and the iTerm settings card read it.
    var itermConnection: ItermConnection = .starting
    /// The connected daemon, if there is one; every request the app makes goes to it.
    @ObservationIgnored private(set) var daemon: (any DaemonCommands)?
    @ObservationIgnored private var supervisor: DaemonSupervisor?
    @ObservationIgnored private var connection: DaemonConnection?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var running = false
    /// Set when a client attaches, cleared by the first snapshot it delivers — the bootstrap one.
    @ObservationIgnored private var awaitingAttachSnapshot = false

    private let socketPath: String
    /// The bundle's resources, where the daemon's package is.
    private let bundledResourcesURL: URL?
    private let preferences: InterfacePreferences
    /// Who hears the events, of a daemon attaching (with checkout cleanup that may have waited for
    /// one) and of a request that failed where no caller is waiting to say so.
    private let onEvent: @MainActor (DaemonEvent) -> Void
    private let onAttach: @MainActor () -> Void
    private let notices: Notices
    private let findPython: @Sendable () -> URL?

    init(socketPath: String = AiTermPaths.socketPath, bundledResourcesURL: URL?, preferences: InterfacePreferences,
         findPython: @escaping @Sendable () -> URL? = { PythonLocator.find() },
         onEvent: @escaping @MainActor (DaemonEvent) -> Void, onAttach: @escaping @MainActor () -> Void,
         notices: Notices) {
        self.socketPath = socketPath
        self.findPython = findPython
        self.bundledResourcesURL = bundledResourcesURL
        self.preferences = preferences
        self.onEvent = onEvent
        self.onAttach = onAttach
        self.notices = notices
    }

    /// Finds Python — a login shell costing the better part of a second — and starts the helper
    /// with it; the connection follows once the helper listens. A bundle without the helper is
    /// known at once, and is not worth that lookup.
    func start() {
        guard !running else { return }
        running = true
        guard let resources = bundledResourcesURL else {
            itermConnection = .helperMissing
            return
        }
        let findPython = self.findPython
        startup = Task {
            let found = try? await BackgroundWork.run { findPython() }
            guard !Task.isCancelled, running else { return }
            guard let python = found ?? nil else {
                itermConnection = .pythonMissing
                return
            }
            let daemonDir = resources.appendingPathComponent("daemon"), link = self
            supervisor = DaemonSupervisor(python: python, daemonDir: daemonDir, socketPath: socketPath) { [weak link] status in
                Task { @MainActor in link?.supervisorChanged(status) }
            }
            supervisor?.start()
        }
    }

    /// Stops the daemon the app started and closes the socket. The daemon refuses to start while a
    /// live socket exists, so an orphan left behind at quit would break the next launch.
    func shutdown() {
        running = false
        startup?.cancel()
        // Close our end first — the connection disconnects its client and clears `daemon` — so the
        // daemon sees the client go away before it is asked to quit, rather than writing into a
        // socket whose reader is already gone.
        connection?.stop()
        connection = nil
        supervisor?.stop(); supervisor = nil
    }

    func setDaemonClient(_ client: (any DaemonCommands)?) {
        daemon = client
        // The iTerm2 background waits for the attach snapshot: the daemon can apply it only with
        // iTerm2 connected, and says so there — or later, with `.itermConnected`.
        awaitingAttachSnapshot = client != nil
        if client != nil { onAttach() }
    }

    private func supervisorChanged(_ st: DaemonSupervisor.State) {
        guard running else { return }
        switch st {
        // `.adopted` is a daemon a previous (non-gracefully ended) app left behind, still serving
        // the socket. Nothing distinguishes it from one we started: iTerm2 window ids are iTerm2's
        // own, so the `windowId`s in `state.json` keep resolving, and the session list is rebuilt
        // from iTerm2 on the next poll. A child of ours is connected to once it listens, not when it
        // is spawned: until then there is no socket to reach.
        case .listening, .adopted:
            if connection == nil {
                connection = DaemonConnection(socketPath: socketPath,
                    onClient: { [weak self] in self?.setDaemonClient($0) },
                    onStatus: { [weak self] in self?.itermConnection = $0 },
                    onEvent: { [weak self] in self?.handle($0) })
            }
            connection?.start()
        // A single failure is a restart in progress and the backoff is about to retry: leave the
        // banner as it was rather than blanking a message that still applies. From the second
        // failure on the daemon is genuinely stuck, and the log is the only way to find out why.
        case .failed(let attempt, let msg): if attempt >= 2 { itermConnection = .helperFailing(msg) }
        case .starting, .running, .stopped: break
        }
    }

    /// Every event the connection delivers: what reaches iTerm2 is the link's, and everything goes
    /// on to `onEvent`.
    func handle(_ event: DaemonEvent) {
        switch event {
        // A daemon that already has iTerm2 — adopted, or reached again after the socket dropped —
        // broadcasts no `iterm.connected`; its attach snapshot is the only time to say it.
        case .snapshot(let snapshot) where awaitingAttachSnapshot:
            awaitingAttachSnapshot = false
            if snapshot.connected { sendItermBackground() }
        case .itermConnected:
            sendItermBackground()
        default: break
        }
        onEvent(event)
    }

    /// Settings' test of the iTerm2 connection. A fresh snapshot comes back through the event
    /// stream like any other, so `itermConnection` is updated there; a helper that cannot answer
    /// is noticed by its connection's own loop. The rest is what the helper cannot see.
    func checkIterm() async -> ItermEnvironment {
        if let daemon { _ = try? await daemon.snapshot() }
        return ItermEnvironment.current()
    }

    /// Settings' switch. Only a change is applied: each send makes the daemon restyle every iTerm2
    /// window, and Save hands over the switch whether or not it moved. The send, if one was made;
    /// nil means nothing was sent — the switch did not move, or no daemon is attached, in which
    /// case the stored switch goes with the next attach.
    @discardableResult
    func setMatchItermBackground(_ enabled: Bool) -> Task<Void, Never>? {
        guard enabled != preferences.matchItermBackground else { return nil }
        preferences.matchItermBackground = enabled
        return sendItermBackground()
    }

    /// The daemon owns iTerm2's API connection, so the preference is applied whenever iTerm2 is
    /// reachable: on a change, and on each connection to it.
    @discardableResult
    private func sendItermBackground() -> Task<Void, Never>? {
        guard let daemon else { return nil }
        let enabled = preferences.matchItermBackground
        return Task {
            do { try await daemon.setMatchItermBackground(enabled) }
            catch { notices.report(OperationIssue(title: "Couldn’t update the iTerm2 background.", error: error)) }
        }
    }

    /// Each tab's title, sent after every checkout pass. The daemon alone remembers which it has
    /// applied: it applies only what differs from what it last set, and forgets a tab's title when
    /// the tab moves and all of them when iTerm2 reconnects — events this side would only have to
    /// infer, and could miss. An unchanged list costs one local request.
    func sendTitles(_ titles: [SessionTitle]) async {
        guard let daemon, !titles.isEmpty else { return }
        _ = try? await daemon.setSessionTitles(titles)
    }
}
