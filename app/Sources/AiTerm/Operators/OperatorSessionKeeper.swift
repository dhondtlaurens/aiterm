import Foundation
import AiTermCore

/// One Operator, with a persisted close → revoke → open handover. Retrying an opening uses the
/// same session generation; its I/O port adopts the window and token already prepared for it.
@MainActor @Observable final class OperatorSessionKeeper {
    struct Ports {
        var canOpen: () -> Bool
        var windowIsOpen: (OperatorSession) -> Bool
        var close: (String) async throws -> Void
        var revoke: (UUID) async throws -> Void
        var open: (OperatorSession, OperatorDigest) async throws -> String
    }
    private let workspace: WorkspaceStore
    private let now: () -> Date
    private let oracleOn: () -> Bool
    private let ports: Ports
    private var pass: UUID?
    private(set) var lastError: String?
    init(workspace: WorkspaceStore, now: @escaping () -> Date, oracleOn: @escaping () -> Bool, ports: Ports) {
        self.workspace = workspace; self.now = now; self.oracleOn = oracleOn; self.ports = ports
    }
    func stop() { pass = nil }
    func ensure() async {
        guard pass == nil, workspace.canChangeWorkspace, ports.canOpen(), workspace.state.operatorSession?.paused != true else { return }
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
            if session.startingFresh, session.handover == nil {
                workspace.mutate { $0.operatorSession?.handover = .closing }; session.handover = .closing
                guard workspace.flush() else { return }
            }
            if session.handover == .closing {
                if let window = session.window { try await ports.close(window) }
                guard holds(session, pass: key) else { return }
                workspace.mutate { $0.operatorSession?.window = nil; $0.operatorSession?.handover = .revoking }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
            }
            if session.handover == .revoking {
                try await ports.revoke(session.id)
                guard holds(session, pass: key) else { return }
                workspace.mutate { state in
                    state.operatorSession?.generation += 1
                    state.operatorSession?.createdAt = now()
                    state.operatorSession?.conversation = nil; state.operatorSession?.session = nil
                    state.operatorSession?.handover = .opening
                    state.operatorSession?.prune()
                }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
            }
            if case .unknown = session.handover { return }
            if session.handover == nil, ports.windowIsOpen(session) { return }
            let digest = OperatorDigest(state: workspace.state, at: now(), oracleOn: oracleOn())
            let window = try await ports.open(session, digest)
            guard holds(session, pass: key) else { return }
            workspace.mutate { state in
                state.operatorSession?.window = window; state.operatorSession?.startingFresh = false
                state.operatorSession?.handover = nil
            }
            workspace.flush(); lastError = nil
        } catch { if pass == key { lastError = OperationIssue.reason(of: error) } }
    }
    func freshIfDue(contextTokens: Int?, idle: Bool, wakePending: Bool) async {
        guard pass == nil, workspace.canChangeWorkspace, ports.canOpen(), let session = workspace.state.operatorSession,
              FreshStartPolicy.shouldStart(session: session, now: now(), contextTokens: contextTokens, idle: idle, wakePending: wakePending) else { return }
        workspace.mutate { $0.operatorSession?.startingFresh = true; $0.operatorSession?.handover = .closing }
        guard workspace.flush() else { return }
        await ensure()
    }
    private func holds(_ session: OperatorSession, pass key: UUID) -> Bool {
        pass == key && !Task.isCancelled && workspace.canChangeWorkspace && ports.canOpen()
            && workspace.state.operatorSession?.id == session.id
            && workspace.state.operatorSession?.generation == session.generation
            && workspace.state.operatorSession?.paused != true
    }
}
