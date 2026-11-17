import Foundation
import AiTermCore

/// Wakes the Operator's chat: one pending wake line at a time, typed only into an idle chat tab,
/// saved as unread until a global `run_status` reads it.
@MainActor final class OperatorWaker {
    private let workspace: WorkspaceStore
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let activity: OperatorActivityTracker, log: ActivityWriter
    /// The chat's tab, as `OperatorChat.operatorTab()` finds it.
    private let tab: @MainActor () -> SessionInfo?
    /// Whether the Operator runs.
    private let running: @MainActor () -> Bool
    private(set) var pending: (OperatorWakeEvent, UUID)?
    private(set) var waking = false
    /// After a partial wake, the Operator's unsent input is that wake line, not the person typing.
    private var leftUnsent = false

    init(workspace: WorkspaceStore, daemon: @escaping @MainActor () -> (any DaemonCommands)?, activity: OperatorActivityTracker,
         log: ActivityWriter, tab: @escaping @MainActor () -> SessionInfo?, running: @escaping @MainActor () -> Bool) {
        self.workspace = workspace; self.daemon = daemon; self.activity = activity; self.log = log; self.tab = tab; self.running = running
    }

    /// A wake is pending in the slot, or one was typed and not yet read.
    var unread: Bool { pending != nil || workspace.state.operatorSession?.wakeAwaitingRead == true }

    func wake(_ event: OperatorWakeEvent, id: UUID) {
        guard workspace.state.operatorHasWork else { return }
        activity.pulse()
        if pending == nil { pending = (event, id) }
    }
    /// A blocked stage or one waiting for its agent choice is the Operator's to act on.
    func wakeIfWaiting(_ id: UUID) {
        switch workspace.state.signalItem(id: id)?.signalTask?.phase {
        case .blocked: wake(.taskBlocked, id: id)
        case .choosing: wake(.agentChoice, id: id)
        default: break
        }
    }
    /// At start: a wake saved as unread is pending again.
    func restore() {
        if workspace.state.operatorSession?.wakeAwaitingRead == true, let id = workspace.state.operatorSession?.id {
            // The unread wake may sit pasted in the Operator's chat from before the relaunch.
            pending = (.sessionRecovered, id); leftUnsent = true
        }
    }
    /// With no work, nothing being typed and nothing unread, the pending wake is dropped.
    func dropWhenNoWork() {
        if !workspace.state.operatorHasWork && !waking && workspace.state.operatorSession?.wakeAwaitingRead != true { pending = nil }
    }
    /// A global `run_status` read every wake, including one the person sent by pressing Enter.
    func acknowledge() {
        pending = nil; workspace.mutate { $0.operatorSession?.wakeAwaitingRead = nil }; workspace.flush()
        leftUnsent = false; log.succeed(.wake)
    }
    /// The chat was retired: no wake line is left in it.
    func reset() { leftUnsent = false }

    func deliver() async {
        guard !waking, let (event, id) = pending, let session = workspace.state.operatorSession,
              !session.startingFresh, !session.paused, let tab = tab(), tab.state.turnEnded, let daemon = daemon() else { return }
        waking = true
        await activity.during("waking its session") { await send(event, id: id, session: session, tab: tab, daemon: daemon) }
        waking = false
    }
    private func send(_ event: OperatorWakeEvent, id: UUID, session: OperatorSession, tab: SessionInfo, daemon: any DaemonCommands) async {
        do {
            try await daemon.setOwnership(sessionId: tab.sessionId, ownership: session.generation)
            guard running(), workspace.state.operatorSession?.generation == session.generation else { return }
            workspace.mutate { $0.operatorSession?.wakeAwaitingRead = true }
            guard workspace.flush() else { return }
            let result = try await daemon.deliver(sessionId: tab.sessionId, text: event.line(id),
                ownership: session.generation, wake: true, worktree: nil)
            switch result.result {
            case .delivered:
                if pending?.0 == event, pending?.1 == id { pending = nil }
                leftUnsent = false; log.succeed(.wake)
            case .partial:
                leftUnsent = true
                log.fail(.wake, "A wake line was pasted into the Operator's chat but not sent. Press Enter there.")
            case .refused:
                // This attempt typed nothing. Without a previous uncertain paste there is no
                // unread wake to keep a finished workload's chat alive.
                if !leftUnsent { workspace.mutate { $0.operatorSession?.wakeAwaitingRead = nil }; workspace.flush() }
                switch result.code {
                case .typing?, .prompt?: break // Not now: the person is typing, or a prompt the session already shows is open.
                case .unsentInput? where !leftUnsent: break
                case .unsentInput?: log.fail(.wake, "Text waits unsent in the Operator's chat, so it cannot be woken. Send or clear it there.")
                default: log.fail(.wake, "The helper refused the wake: " + (result.reason ?? result.code?.rawValue ?? "no reason given"))
                }
            }
        } catch {
            // The reply may be what was lost (a timeout after the paste): the line may sit unsent in the chat.
            leftUnsent = true
            log.fail(.wake, "The wake could not be sent: " + OperationIssue.reason(of: error))
        }
    }
}
