import Foundation
import AiTermCore

/// Whether AiTerm may type into each agent CLI, as the delivery check last wrote it
/// (`DeliveryCheck`): each Claude Code and Codex card's Messaging check in Settings › Agents, and part
/// of what New Broadcast waits for. It reads the policy file and the installed versions while someone
/// looks (`watch`, for as long as Settings or New Broadcast is open): a check run by hand reaches the
/// card within `interval`, and one Run check opened again as its window closes.
///
/// Run check opens an iTerm2 window in front, in the helper's own folder, running the check for that
/// agent alone, written into the file (`DeliveryCheck.command`). The agent's scenarios run by
/// themselves; iTerm2's own checks, until they pass, ask the person there to type once and click
/// another app. The card says the check runs until it writes the file or its window closes.
@MainActor
@Observable
final class MessagingChecks {
    /// What Run check needs from the rest of the app; the composition root sets them, a test its own.
    struct Opener {
        var daemon: @MainActor () -> (any DaemonCommands)?
        /// The Python and the package folder the helper runs with (`HelperLink.runtime`).
        var runtime: @MainActor () -> HelperLink.Runtime?
        var frame: @MainActor () -> Frame
        /// Brings iTerm2 forward: the window waits for the person.
        var activateIterm: @MainActor () -> Void
    }

    /// The file as last read; nil until it is.
    private(set) var file: DeliveryCheckFile?
    /// Each covered agent's version, as last read; an agent whose version couldn't be read is missing.
    private(set) var versions: [AgentKind: String] = [:]
    /// Why the last Run check could not open its window, by agent: the card's status until the next.
    private(set) var failures: [AgentKind: String] = [:]
    /// The agents whose Run check is opening its window.
    private(set) var opening: Set<AgentKind> = []
    /// The file as it was read when each agent's Run check opened its window, while that window is open.
    private(set) var started: [AgentKind: DeliveryCheckFile] = [:]
    @ObservationIgnored var opener: Opener?
    /// The windows Run check opened that are still open, and whose check each runs.
    @ObservationIgnored private(set) var windows: [String: AgentKind] = [:]
    @ObservationIgnored private let watcher: DeliveryCheckWatch
    @ObservationIgnored private let readVersions: @Sendable ([AgentKind]) -> [AgentKind: String]
    @ObservationIgnored private let interval: Duration
    /// The latest read, which waits for the one before it.
    @ObservationIgnored private var reading: Task<Void, Never>?

    /// `versions` reads the installed CLIs' (`AgentVersions`); `interval` is the pause between looks.
    init(policyURL: URL, versions: @escaping @Sendable ([AgentKind]) -> [AgentKind: String], interval: Duration = .seconds(2)) {
        watcher = DeliveryCheckWatch(url: policyURL)
        readVersions = versions
        self.interval = interval
    }

    /// Reads nothing of this Mac's: for previews, the snapshots and the tests that build Settings alone.
    static func inert() -> MessagingChecks {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AiTerm.inert-\(UUID().uuidString)")
        return MessagingChecks(policyURL: scratch.appendingPathComponent("delivery-policy.json"), versions: { _ in [:] })
    }

    /// `agent`'s Messaging, once the file and the versions are read: nil until then, and for an agent
    /// the check does not cover.
    func readiness(of agent: AgentKind) -> DeliveryReadiness? {
        file.flatMap { DeliveryCheck.messaging(agent, file: $0, installed: versions[agent]) }
    }

    /// Whether `agent`'s Run check is still at work: its window open, and the file as it was when it opened.
    func isRunning(_ agent: AgentKind) -> Bool {
        opening.contains(agent) || started[agent].map { $0 == (file ?? .missing) } ?? false
    }

    /// Why `agent`'s last run failed, while its verdict is the card's (`DeliveryCheck.failure`).
    func failure(of agent: AgentKind) -> String? {
        file.flatMap { DeliveryCheck.failure(agent, file: $0, installed: versions[agent]) }
    }

    /// iTerm2's own checks; nil until the file is read.
    var iterm: DeliveryReadiness? { file.map(DeliveryCheck.iterm) }

    /// Reads the file when it changed since the last read, and the versions with it; `force` reads both
    /// whatever the file's stamp says. One read at a time, each after the one before it, so an older
    /// answer never lands over a newer one.
    func refresh(force: Bool = false) async {
        let previous = reading
        let read = Task {
            await previous?.value
            await self.read(force: force)
        }
        reading = read
        await read.value
    }

    private func read(force: Bool) async {
        let watcher = self.watcher, versions = readVersions
        let fresh = await BackgroundWork.run { () -> (DeliveryCheckFile, [AgentKind: String])? in
            if force { watcher.forget() }
            return watcher.changed().map { ($0, versions(DeliveryCheck.agents)) }
        }
        guard let (file, found) = fresh else { return }
        self.file = file
        self.versions = found
    }

    /// Reads at once, then again every `interval` until the task is cancelled: Settings and New Broadcast
    /// run it for as long as they are open.
    func watch() async {
        await refresh(force: true)
        await PollLoop.run(interval: interval, sleepFirst: true) {
            await refresh()
            return interval
        }
    }

    /// Run check: the delivery check for `agent` in a new iTerm2 window, in front. A window this opened
    /// for that agent before, still open, closes first: its check ended, or is being replaced.
    func run(_ agent: AgentKind) async {
        guard !opening.contains(agent) else { return }
        failures[agent] = nil
        guard let opener, let daemon = opener.daemon(), let runtime = opener.runtime() else {
            failures[agent] = "AiTerm’s helper isn’t running, so the check can’t open its window"
            return
        }
        opening.insert(agent)
        defer { opening.remove(agent) }
        started[agent] = nil
        for (window, checked) in windows where checked == agent {
            windows[window] = nil
            await Log.daemon.attempt("Closing the last delivery check window of \(agent.rawValue)") {
                try await daemon.close(windowId: window)
            }
        }
        let command = DeliveryCheck.command(agent: agent, file: file ?? .missing, python: runtime.python, daemonDir: runtime.daemonDir)
        do {
            // A tag of its own, which no row takes: the window is the check's alone.
            let window = try await daemon.createTaskWindow(taskId: "delivery-check-\(agent.rawValue)-\(UUID().uuidString)",
                                                           cwd: runtime.daemonDir.path, title: "Delivery check · \(agent.displayName)",
                                                           agentCommand: command, frame: opener.frame(), background: false)
            windows[window] = agent
            started[agent] = file ?? .missing
            opener.activateIterm()
            await Log.daemon.attempt("Bringing the delivery check window forward") { try await daemon.activate(windowId: window) }
        } catch {
            failures[agent] = OperationIssue.reason(of: error)
        }
    }

    /// The helper's word that an iTerm2 window closed: one Run check opened reads the file again.
    func windowClosed(_ window: String) {
        guard let agent = windows.removeValue(forKey: window) else { return }
        started[agent] = nil
        Task { await refresh(force: true) }
    }
}

#if DEBUG
extension MessagingChecks {
    /// Already read, as `file` and `versions` say, for the snapshots: the renderer runs no task to read them.
    static func preview(file: DeliveryCheckFile, versions: [AgentKind: String]) -> MessagingChecks {
        let checks = inert()
        checks.file = file
        checks.versions = versions
        return checks
    }
}
#endif
