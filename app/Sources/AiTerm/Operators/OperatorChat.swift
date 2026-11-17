import Foundation
import AiTermCore

/// The one Operator chat: its window and Claude Code session, opened, adopted, remembered, closed
/// and renewed through `OperatorSessionKeeper`, and what the row says when the session itself is wrong.
@MainActor final class OperatorChat {
    struct Ports {
        /// Whether the Operator runs.
        var running: @MainActor () -> Bool
        /// Whether the daemon's snapshot of the tabs is current.
        var tabsKnown: @MainActor () -> Bool
        var profile: @MainActor () -> OperatorProfile
        var instructions: @MainActor () -> String?
        var oracleOn: @MainActor () -> Bool
        /// Whether the Operator has something to type into its chat, which reopens a chat you closed.
        var wakeToType: @MainActor () -> Bool
    }
    private let workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let frame: @MainActor () -> Frame
    private let activity: OperatorActivityTracker, log: ActivityWriter
    private let context: Ports
    private var opened: (window: String, generation: Int, at: Date)?
    /// Called when the keeper retired the chat, after its window record was dropped.
    var finished: @MainActor () -> Void = {}
    lazy var keeper: OperatorSessionKeeper = makeKeeper()

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         frame: @escaping @MainActor () -> Frame, activity: OperatorActivityTracker, log: ActivityWriter, context: Ports) {
        self.workspace = workspace; self.live = live; self.ports = ports; self.daemon = daemon; self.frame = frame
        self.activity = activity; self.log = log; self.context = context
    }
    private func makeKeeper() -> OperatorSessionKeeper {
        let keeper = OperatorSessionKeeper(workspace: workspace, now: ports.now,
        oracleOn: context.oracleOn, ports: .init(
            canOpen: { [weak self] in self.map { $0.context.running() && $0.context.tabsKnown() && $0.daemon() != nil && !$0.context.profile().model.isEmpty && $0.ports.installedAgents().contains(.claude) } ?? false },
            close: { [weak self] window in try await self?.closeOperator(window) },
            revoke: { [weak self] id in
                guard let self, let daemon = self.daemon(), let session = self.workspace.state.operatorSession else { throw ActionUnavailable("The helper is unavailable.") }
                try await daemon.revokeOperator(operatorId: id.uuidString, generation: session.generation)
            }, open: { [weak self] session, digest in
                guard let self else { throw ActionUnavailable("The Operator stopped.") }
                return try await self.open(session, digest: digest)
            }, existingWindow: { [weak self] session in
                guard let self, let daemon = self.daemon() else { throw ActionUnavailable("The helper is unavailable.") }
                let snapshot = try await daemon.snapshot()
                guard self.context.running(), self.workspace.state.operatorSession?.id == session.id,
                      self.workspace.state.operatorSession?.generation == session.generation else { throw ActionUnavailable("The Operator session changed.") }
                return snapshot.sessions.first { $0.taskUUID == session.id && $0.agent == .claude }?.windowId
            }, sessions: { [weak self] in self?.live.sessions ?? [] }, instructions: { [weak self] in self?.context.instructions() }, usage: { [weak self] in self?.live.usage ?? .empty },
            installedAgents: { [weak self] in self?.ports.installedAgents() ?? [] }))
        keeper.activity = activity
        keeper.failed = { [weak self] reason in self?.log.fail(.session, reason) }
        keeper.succeeded = { [weak self] in self?.log.succeed(.session) }
        keeper.finished = { [weak self] in
            guard let self else { return }
            self.opened = nil
            self.finished()
        }
        return keeper
    }
    func stop() { keeper.stop() }

    /// The Operator's chat tab in its saved window, as the daemon last listed it.
    func operatorTab() -> SessionInfo? {
        guard let session = workspace.state.operatorSession, let window = session.window else { return nil }
        return live.sessions.first { $0.taskUUID == session.id && $0.agent == .claude && $0.windowId == window }
    }
    /// Saves the chat tab's window, session and conversation.
    func remember() {
        guard let tab = operatorTab() else { return }
        workspace.mutate { state in
            state.operatorSession?.window = tab.windowId; state.operatorSession?.session = tab.sessionId
            if let conversation = tab.conversationId { state.operatorSession?.conversation = conversation }
        }
    }
    /// Keeps the chat as its workload needs it, reopening a closed one when there is a wake to type.
    func ensure() async { await keeper.ensure(reopen: context.wakeToType()) }
    func finishIfIdle(idle: Bool, wakeWaiting: Bool) async { await keeper.finishIfIdle(idle: idle, wakePending: wakeWaiting) }
    /// With no work left, retires the chat once its tab ended its turn and is not stopped and the rest
    /// of the Operator is `idle`; then opens a new generation for a match that arrived while it closed.
    func finishWhenNoWork(idle: Bool, wakeWaiting: Bool) async {
        guard !workspace.state.operatorHasWork else { return }
        await keeper.finishIfIdle(idle: (operatorTab().map { $0.state.turnEnded && $0.stoppedOn == nil } ?? true) && idle,
            wakePending: wakeWaiting)
        // A signal may have matched while the old window was closing. Its task was saved first;
        // it now gets the new generation, with no discarded wake or old conversation.
        if workspace.state.operatorHasWork { await ensure() }
    }
    /// Starts a fresh conversation when the chat's context is due for it, its tab ended its turn and is
    /// not stopped, the rest of the Operator is `idle`, and nothing is waiting to be typed into it.
    func freshIfDue(idle: Bool, wakeWaiting: Bool) async {
        guard let session = workspace.state.operatorSession, let tab = operatorTab() else { return }
        await keeper.freshIfDue(contextTokens: tab.contextTokens, idle: tab.state.turnEnded && tab.stoppedOn == nil && idle,
            wakePending: wakeWaiting || live.sessions.filter { $0.windowId == session.window }.count != 1)
    }
    func windowClosed(_ window: String) { if opened?.window == window { opened = nil } }
    /// What the row says about the session itself: the tab's stop reason, then a window that never started the chat.
    var sessionIssue: String? {
        if let stopped = operatorTab()?.stoppedOn { return "The Operator " + stopped.reason(now: ports.now()) + "." }
        if let opened, ports.now().timeIntervalSince(opened.at) >= OperatorTiming.openingGrace,
           live.sessions.contains(where: { $0.windowId == opened.window && $0.taskUUID == workspace.state.operatorSession?.id && $0.agent == .shell }) {
            return "The Operator did not start in its window. Open the chat to inspect it."
        }
        return nil
    }
    /// The Operator's chat opened, even while paused, when its row is chosen without a window; with no
    /// work there is nothing to open. Throws when it is still without one, with the session's issue as
    /// the reason when there is one.
    func open() async throws {
        guard workspace.state.operatorHasWork else { return }
        await keeper.ensure(allowPaused: true, reopen: true)
        guard workspace.state.operatorSession?.window == nil else { return }
        throw ActionUnavailable(log.issues.current.first { $0.source == .session }?.text ?? "The Operator’s chat couldn’t open.")
    }

    private func open(_ session: OperatorSession, digest: OperatorDigest) async throws -> String {
        guard context.running(), let daemon = daemon() else { throw ActionUnavailable("The helper is unavailable.") }
        let home = ports.home, config = ports.claudeConfig, profile = OperatorProfileStore.saved(ports.preferences) ?? context.profile(), projects = workspace.state.projects
        let prepared = try await BackgroundWork.run {
            try OperatorLaunch.prepare(session: session, profile: profile, projects: projects, digest: digest,
                home: home, claudeConfig: config, resuming: session.conversation)
        }
        guard context.running(), workspace.state.operatorSession?.id == session.id, workspace.state.operatorSession?.generation == session.generation else { throw ActionUnavailable("The Operator session changed.") }
        try await daemon.registerOperator(operatorId: session.id.uuidString, token: prepared.token, generation: session.generation)
        let actual = try await daemon.snapshot()
        guard context.running(), workspace.state.operatorSession?.generation == session.generation else { throw ActionUnavailable("The Operator session changed.") }
        if let existing = actual.sessions.first(where: { $0.taskUUID == session.id && $0.agent == .claude }) { return existing.windowId }
        let opening = try await daemon.openWorkerWindow(taskId: session.id.uuidString, cwd: prepared.folder.path, title: "Operator", agentCommand: prepared.command, frame: frame())
        guard opening.commandError == nil else { throw ActionUnavailable(opening.commandError!) }
        opened = (opening.id, session.generation, ports.now()); return opening.id
    }
    private func closeOperator(_ window: String) async throws {
        guard let session = workspace.state.operatorSession, let daemon = daemon(), context.running() else { throw ActionUnavailable("The helper is unavailable.") }
        guard let tab = operatorTab(), tab.windowId == window else {
            // The close may have completed before a lost reply or a restart. Confirm absence;
            // never close another window that happens to have the old number.
            let snapshot = try await daemon.snapshot()
            guard context.running(), workspace.state.operatorSession?.id == session.id,
                  workspace.state.operatorSession?.generation == session.generation,
                  workspace.state.operatorSession?.window == window, workspace.state.operatorSession?.handover == .closing,
                  !snapshot.sessions.contains(where: { $0.windowId == window }) else { throw ActionUnavailable("The Operator's window is not safely idle.") }
            return
        }
        guard live.sessions.filter({ $0.windowId == window }).count == 1, let conversation = tab.conversationId,
              tab.state.turnEnded else { throw SignalOperatorCloseDeferred("The Operator's window is not safely idle.") }
        try await daemon.setOwnership(sessionId: tab.sessionId, ownership: session.generation)
        let result = try await daemon.closeIdle(sessionId: tab.sessionId, ownership: session.generation, conversation: conversation)
        // These codes prove no close was attempted. iTerm refusal/timeouts, a missing session,
        // unknown codes and old helpers without a code remain ambiguous and keep the handover.
        let beforeClose: [DeliveryCode] = [.typing, .unsentInput, .keysUnwatched, .screenUnread, .prompt, .unrecognisedScreen, .unsupported, .notChecked]
        if result.result == .refused, let code = result.code, beforeClose.contains(code) {
            throw SignalOperatorCloseDeferred(result.reason ?? "The Operator could not close safely.")
        }
        guard result.result == .delivered else { throw ActionUnavailable(result.reason ?? "The Operator could not close safely.") }
    }
}
