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
        var close: @MainActor (String) async throws -> Void
        var revoke: @MainActor (UUID) async throws -> Void
        var open: @MainActor (OperatorSession, OperatorDigest) async throws -> String
        var existingWindow: @MainActor (OperatorSession) async throws -> String? = { _ in nil }
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
    var finished: @MainActor () -> Void = {}
    var activity: OperatorActivityTracker?
    init(workspace: WorkspaceStore, now: @escaping () -> Date, oracleOn: @escaping () -> Bool, ports: Ports) {
        self.workspace = workspace; self.now = now; self.oracleOn = oracleOn; self.ports = ports
    }
    func stop() { pass = nil }
    /// Keeps the chat as its workload needs it: a new generation opens, and an established chat whose
    /// window was closed opens again only when `reopen` (the person chose its row, or the Operator has
    /// something to type into it).
    func ensure(allowPaused: Bool = false, reopen: Bool = false) async {
        guard workspace.state.operatorSession?.finishing != true else { return }
        await transition(finishing: false, allowPaused: allowPaused, reopen: reopen)
    }
    /// Keep source polling and its saved metadata, but release the chat when its workload ends.
    /// Once closing was saved, finish that generation even if a new match arrived during the close.
    func finishIfIdle(idle: Bool, wakePending: Bool) async {
        guard let session = workspace.state.operatorSession else { return }
        if session.finishing != true {
            guard !workspace.state.operatorHasWork, idle, !wakePending,
                  session.window != nil || session.conversation != nil || session.startingFresh else { return }
        }
        await transition(finishing: true, allowPaused: true, reopen: false)
    }
    private func transition(finishing: Bool, allowPaused: Bool, reopen: Bool) async {
        guard pass == nil, workspace.canChangeWorkspace, ports.canOpen(), (allowPaused || workspace.state.operatorSession?.paused != true) else { return }
        let key = UUID(); pass = key
        defer { if pass == key { pass = nil } }
        do {
            if workspace.state.operatorSession == nil {
                guard !finishing else { return }
                var session = OperatorSession(createdAt: now())
                session.startingFresh = true; session.handover = .opening
                workspace.mutate { $0.operatorSession = session }
                guard workspace.flush() else { return }
            }
            guard var session = workspace.state.operatorSession else { return }
            if session.paused && session.startingFresh && !finishing { return }
            // A retired record stays for source metadata and pause. Every later workload needs
            // the same durable opening intent as the first chat, including a lost open reply.
            if !finishing, session.handover == nil, session.window == nil, session.conversation == nil {
                workspace.mutate { state in
                    state.operatorSession?.startingFresh = true
                    state.operatorSession?.handover = .opening
                    state.operatorSession?.createdAt = now()
                }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
            }
            if finishing {
                // An opening may have completed before its reply or state save. Adopt without
                // launching an empty chat, then use the same safe close path as a known window.
                if session.window == nil, session.handover != .revoking {
                    let window = try await ports.existingWindow(session)
                    guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                    workspace.mutate { $0.operatorSession?.window = window }
                    session.window = window
                }
                workspace.mutate { state in
                    state.operatorSession?.finishing = true
                    state.operatorSession?.startingFresh = true
                    if session.handover == nil || session.handover == .opening { state.operatorSession?.handover = .closing }
                }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
            }
            if session.startingFresh, session.handover == nil {
                workspace.mutate { $0.operatorSession?.handover = .closing }; session.handover = .closing
                guard workspace.flush() else { return }
            }
            if session.handover == .closing {
                do {
                    if let window = session.window {
                        if let activity { try await activity.during(finishing ? "finishing its session" : "closing its previous session") { try await ports.close(window) } }
                        else { try await ports.close(window) }
                    }
                }
                catch is SignalOperatorCloseDeferred {
                    guard holds(session, pass: key, allowPaused: allowPaused),
                          workspace.state.operatorSession?.handover == .closing,
                          workspace.state.operatorSession?.window == session.window else { return }
                    workspace.mutate { $0.operatorSession?.startingFresh = false; $0.operatorSession?.handover = nil; $0.operatorSession?.finishing = nil }
                    workspace.flush(); succeeded()
                    return
                }
                guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                workspace.mutate { $0.operatorSession?.window = nil; $0.operatorSession?.handover = .revoking }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
            }
            if session.handover == .revoking {
                if let activity { try await activity.during("releasing its previous session") { try await ports.revoke(session.id) } }
                else { try await ports.revoke(session.id) }
                guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                workspace.mutate { state in
                    state.operatorSession?.generation += 1
                    state.operatorSession?.createdAt = now()
                    state.operatorSession?.conversation = nil; state.operatorSession?.session = nil
                    state.operatorSession?.handover = finishing ? nil : .opening
                    if finishing {
                        state.operatorSession?.startingFresh = false
                        state.operatorSession?.finishing = nil
                        state.operatorSession?.wakeAwaitingRead = nil
                    }
                    state.operatorSession?.prune(at: now())
                }
                guard workspace.flush(), let current = workspace.state.operatorSession else { return }; session = current
                if finishing { succeeded(); finished(); return }
            }
            if case .unknown = session.handover { return }
            if session.handover == nil {
                if session.window != nil { succeeded(); return }
                guard reopen else { return }
            }
            let digest = OperatorDigest(state: workspace.state, at: now(), oracleOn: oracleOn(), sessions: ports.sessions(), instructions: ports.instructions(), usage: ports.usage(), installed: ports.installedAgents())
            let window: String
            if let activity { window = try await activity.during("starting its session") { try await ports.open(session, digest) } }
            else { window = try await ports.open(session, digest) }
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
