import Foundation
import AiTermCore

/// Wakes the Operator's chat: one wake line at a time, typed only into an idle tab of the open chat,
/// saved on the open chat (`OperatorSession.Lifecycle.Wake`) until a global `run_status` reads it.
@MainActor final class OperatorWaker {
    /// The wake under way. The first event wins while one is pending or being typed.
    enum State: Equatable { case none, pending(OperatorWakeEvent, UUID), delivering(OperatorWakeEvent, UUID) }
    private let workspace: WorkspaceStore
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let activity: OperatorActivityTracker, log: ActivityWriter
    /// The chat's tab, as `OperatorChat.operatorTab()` finds it.
    private let tab: @MainActor () -> SessionInfo?
    /// Whether the Operator runs.
    private let running: @MainActor () -> Bool
    private(set) var state = State.none

    init(workspace: WorkspaceStore, daemon: @escaping @MainActor () -> (any DaemonCommands)?, activity: OperatorActivityTracker,
         log: ActivityWriter, tab: @escaping @MainActor () -> SessionInfo?, running: @escaping @MainActor () -> Bool) {
        self.workspace = workspace; self.daemon = daemon; self.activity = activity; self.log = log; self.tab = tab; self.running = running
    }

    /// A wake is pending or being typed, or the open chat holds one not yet read.
    var unread: Bool { state != .none || saved != nil }
    private var saved: OperatorSession.Lifecycle.Wake? { workspace.state.operatorSession?.lifecycle.wake }

    func wake(_ event: OperatorWakeEvent, id: UUID) {
        guard workspace.state.operatorHasWork else { return }
        activity.pulse()
        if state == .none { state = .pending(event, id) }
    }
    /// A blocked stage or one waiting for its agent choice is the Operator's to act on.
    func wakeIfWaiting(_ id: UUID) {
        switch workspace.state.signalItem(id: id)?.signalTask?.phase {
        case .blocked: wake(.taskBlocked, id: id)
        case .choosing: wake(.agentChoice, id: id)
        default: break
        }
    }
    /// At start: an unread wake of the open chat may sit pasted in it from before the relaunch, and a
    /// recovery wake is pending.
    func restore() {
        guard let session = workspace.state.operatorSession, saved != nil else { return }
        save(.maybeUnsent); workspace.flush()
        state = .pending(.sessionRecovered, session.id)
    }
    /// With no work and nothing unread, the pending wake is dropped.
    func dropWhenNoWork() {
        if !workspace.state.operatorHasWork, case .pending = state, saved == nil { state = .none }
    }
    /// A global `run_status` read every wake, including one the person sent by pressing Enter.
    func acknowledge() {
        state = .none; save(nil); workspace.flush()
        log.succeed(.wake)
    }

    func deliver() async {
        guard case .pending(let event, let id) = state, let session = workspace.state.operatorSession,
              session.lifecycle.isOpen, !session.paused, let tab = tab(), tab.state.turnEnded, let daemon = daemon() else { return }
        state = .delivering(event, id)
        let delivered = await activity.during("waking its session") { await send(event, id: id, session: session, tab: tab, daemon: daemon) }
        if state == .delivering(event, id) { state = delivered ? .none : .pending(event, id) }
    }
    /// Whether the line was sent. Anything else keeps the wake pending.
    private func send(_ event: OperatorWakeEvent, id: UUID, session: OperatorSession, tab: SessionInfo, daemon: any DaemonCommands) async -> Bool {
        var typing = false
        do {
            try await daemon.setOwnership(sessionId: tab.sessionId, ownership: session.generation)
            guard running(), workspace.state.operatorSession?.generation == session.generation else { return false }
            if saved != .maybeUnsent { save(.sent) }
            guard workspace.flush() else { return false }
            typing = true
            let result = try await daemon.deliver(sessionId: tab.sessionId, text: event.line(id),
                ownership: session.generation, wake: true, worktree: nil)
            switch result.result {
            case .delivered:
                if saved != nil { save(.sent); workspace.flush() }
                log.succeed(.wake)
                return true
            case .partial:
                save(.maybeUnsent); workspace.flush()
                log.fail(.wake, "A wake line was pasted into the Operator's chat but not sent. Press Enter there.")
            case .refused:
                // This attempt typed nothing. Without a previous uncertain paste there is no
                // unread wake to keep a finished workload's chat alive.
                let unsent = saved == .maybeUnsent
                if !unsent { save(nil); workspace.flush() }
                switch result.code {
                case .typing?, .prompt?: break // Not now: the person is typing, or a prompt the session already shows is open.
                case .unsentInput? where !unsent: break
                case .unsentInput?: log.fail(.wake, "Text waits unsent in the Operator's chat, so it cannot be woken. Send or clear it there.")
                default: log.fail(.wake, "The helper refused the wake: " + (result.reason ?? result.code?.rawValue ?? "no reason given"))
                }
            }
        } catch {
            // The reply may be what was lost (a timeout after the paste): the line may sit unsent in the chat.
            if typing { save(.maybeUnsent); workspace.flush() }
            log.fail(.wake, "The wake could not be sent: " + OperationIssue.reason(of: error))
        }
        return false
    }
    /// Saves the open chat's unread wake; nothing while the chat is not open.
    private func save(_ wake: OperatorSession.Lifecycle.Wake?) {
        workspace.mutate { state in
            guard case .open(let since, _)? = state.operatorSession?.lifecycle else { return }
            state.operatorSession?.lifecycle = .open(since: since, wake: wake)
        }
    }
}
