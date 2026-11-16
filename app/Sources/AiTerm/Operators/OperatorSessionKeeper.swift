import Foundation
import AiTermCore

/// A definite refusal means the old chat is still open. A transport failure remains uncertain.
struct SignalOperatorCloseDeferred: Error, LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// One Operator, with a persisted close → revoke → open handover. Retrying an opening uses the
/// same session generation; its I/O port adopts the window and token already prepared for it.
@MainActor @Observable final class OperatorSessionKeeper {
    struct Ports {
        var canOpen: @MainActor () -> Bool
        var windowIsOpen: @MainActor (OperatorSession) -> Bool
        var close: @MainActor (String) async throws -> Void
        var revoke: @MainActor (UUID) async throws -> Void
        var open: @MainActor (OperatorSession, OperatorDigest) async throws -> String
        var sessions: @MainActor () -> [SessionInfo] = { [] }
        var instructions: @MainActor () -> String? = { nil }
        var usage: @MainActor () -> UsageSnapshot = { .empty }
        var installedAgents: @MainActor () -> Set<AgentKind> = { [] }
    }
    private let workspace: WorkspaceStore
    private let now: () -> Date
    private let oracleOn: () -> Bool
    private let ports: Ports
    private var pass: UUID?
    /// Each pass reports how it ended, as the Operator's `session` source.
    var failed: @MainActor (String) -> Void = { _ in }
    var succeeded: @MainActor () -> Void = {}
    init(workspace: WorkspaceStore, now: @escaping () -> Date, oracleOn: @escaping () -> Bool, ports: Ports) {
        self.workspace = workspace; self.now = now; self.oracleOn = oracleOn; self.ports = ports
    }
    func stop() { pass = nil }
    func ensure(allowPaused: Bool = false) async {
        guard pass == nil, workspace.canChangeWorkspace, ports.canOpen(), (allowPaused || workspace.state.operatorSession?.paused != true) else { return }
        let key = UUID(); pass = key
        defer { if pass == key { pass = nil } }
        do {
            if workspace.state.operatorSession == nil {
                var session = OperatorSession(createdAt: now())
                session.startingFresh = true; session.handover = .opening
                workspace.mutate { $0.operatorSession = session }
                guard workspace.flush() else { return }
            }
            guard var session = workspace.state.operatorSession else { return }
            if session.paused && session.startingFresh { return }
            if session.startingFresh, session.handover == nil {
                workspace.mutate { $0.operatorSession?.handover = .closing }; session.handover = .closing
                guard workspace.flush() else { return }
            }
            if session.handover == .closing {
                do { if let window = session.window { try await ports.close(window) } }
                catch is SignalOperatorCloseDeferred {
                    guard holds(session, pass: key, allowPaused: allowPaused),
                          workspace.state.operatorSession?.handover == .closing,
                          workspace.state.operatorSession?.window == session.window else { return }
                    workspace.mutate { $0.operatorSession?.startingFresh = false; $0.operatorSession?.handover = nil }
                    workspace.flush(); succeeded()
                    return
                }
                guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                workspace.mutate { $0.operatorSession?.window = nil; $0.operatorSession?.handover = .revoking }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
            }
            if session.handover == .revoking {
                try await ports.revoke(session.id)
                guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                workspace.mutate { state in
                    state.operatorSession?.generation += 1
                    state.operatorSession?.createdAt = now()
                    state.operatorSession?.conversation = nil; state.operatorSession?.session = nil
                    state.operatorSession?.handover = .opening
                    state.operatorSession?.prune(at: now())
                }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
            }
            if case .unknown = session.handover { return }
            if session.handover == nil, ports.windowIsOpen(session) { succeeded(); return }
            let digest = OperatorDigest(state: workspace.state, at: now(), oracleOn: oracleOn(), sessions: ports.sessions(), instructions: ports.instructions(), usage: ports.usage(), installed: ports.installedAgents())
            let window = try await ports.open(session, digest)
            guard holds(session, pass: key, allowPaused: allowPaused) else { return }
            workspace.mutate { state in
                state.operatorSession?.window = window; state.operatorSession?.startingFresh = false
                state.operatorSession?.handover = nil
            }
            workspace.flush(); succeeded()
        } catch { if pass == key { failed(OperationIssue.reason(of: error)) } }
    }
    func freshIfDue(contextTokens: Int?, idle: Bool, wakePending: Bool) async {
        guard pass == nil, workspace.canChangeWorkspace, ports.canOpen(), let session = workspace.state.operatorSession,
              FreshStartPolicy.shouldStart(session: session, now: now(), contextTokens: contextTokens, idle: idle, wakePending: wakePending) else { return }
        workspace.mutate { $0.operatorSession?.startingFresh = true; $0.operatorSession?.handover = .closing }
        guard workspace.flush() else { return }
        await ensure()
    }
    private func holds(_ session: OperatorSession, pass key: UUID, allowPaused: Bool = false) -> Bool {
        pass == key && !Task.isCancelled && workspace.canChangeWorkspace && ports.canOpen()
            && workspace.state.operatorSession?.id == session.id
            && workspace.state.operatorSession?.generation == session.generation
            && (allowPaused || workspace.state.operatorSession?.paused != true)
    }
}
