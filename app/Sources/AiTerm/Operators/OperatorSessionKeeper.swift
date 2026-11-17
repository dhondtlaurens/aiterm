import Foundation
import AiTermCore

/// A definite refusal means the old chat is still open. A transport failure remains uncertain.
struct SignalOperatorCloseDeferred: Error, LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// One Operator chat, its life saved as `OperatorSession.Lifecycle`: a generation opens, and an old chat
/// is closed, its token revoked, and then a fresh one opens (renew) or none does (retire). Retrying an
/// opening uses the same session generation; its I/O port adopts the window and token already prepared for it.
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
    /// Keeps the chat as its workload needs it: a new generation opens, a renewal continues, and an open
    /// chat whose window was closed opens again only when `reopen` (the person chose its row, or the
    /// Operator has something to type into it). Nothing while a retirement runs.
    func ensure(allowPaused: Bool = false, reopen: Bool = false) async {
        guard workspace.state.operatorSession?.lifecycle.isRetiring != true else { return }
        await transition(retire: false, allowPaused: allowPaused, reopen: reopen)
    }
    /// Keep source polling and its saved metadata, but retire the chat when its workload ended and the chat
    /// is `idle` (`OperatorSession.chatIsIdle`). A retirement already saved continues whatever the rule
    /// says, even if a new match arrived during the close.
    func finishIfIdle(idle: Bool) async {
        guard let session = workspace.state.operatorSession else { return }
        if !session.lifecycle.isRetiring {
            guard !workspace.state.operatorHasWork, idle, session.lifecycle != .idle else { return }
        }
        await transition(retire: true, allowPaused: true, reopen: false)
    }
    /// One pass through the lifecycle, each step saved before the next effect: close before revoke, revoke
    /// before the generation increments. `retire` turns a renewal under way into a retirement.
    private func transition(retire: Bool, allowPaused: Bool, reopen: Bool) async {
        guard pass == nil, workspace.canChangeWorkspace, ports.canOpen(), (allowPaused || workspace.state.operatorSession?.paused != true) else { return }
        let key = UUID(); pass = key
        defer { if pass == key { pass = nil } }
        do {
            if workspace.state.operatorSession == nil {
                guard !retire else { return }
                var session = OperatorSession(createdAt: now()); session.lifecycle = .opening
                workspace.mutate { $0.operatorSession = session }
                guard workspace.flush() else { return }
            }
            guard var session = workspace.state.operatorSession else { return }
            if !retire, session.paused, session.lifecycle.isChanging { return }
            while true {
                switch session.lifecycle {
                case .unknown: return
                case .idle:
                    guard !retire else { return }
                    // A retired record stays for source metadata and pause. Every later workload needs
                    // the same durable opening intent as the first chat, including a lost open reply.
                    guard let next = save({ $0.lifecycle = .opening; $0.createdAt = now() }) else { return }
                    session = next
                case .opening where retire:
                    // An opening may have completed before its reply or state save. Adopt without
                    // launching an empty chat, then use the same safe close path as a known window.
                    var window = session.window
                    if window == nil {
                        window = try await ports.existingWindow(session)
                        guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                    }
                    guard let next = save({ $0.window = window; $0.lifecycle = .closing(then: .retire) }) else { return }
                    session = next
                case .opening:
                    let window = try await open(session)
                    guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                    workspace.mutate { state in
                        state.operatorSession?.window = window; state.operatorSession?.lifecycle = .open(since: now(), wake: nil)
                    }
                    workspace.flush(); succeeded()
                    return
                case .open(_, let wake):
                    if retire {
                        guard let next = save({ $0.lifecycle = .closing(then: .retire) }) else { return }
                        session = next
                        continue
                    }
                    if session.window != nil { succeeded(); return }
                    guard reopen else { return }
                    let window = try await open(session)
                    guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                    workspace.mutate { state in
                        state.operatorSession?.window = window; state.operatorSession?.lifecycle = .open(since: now(), wake: wake)
                    }
                    workspace.flush(); succeeded()
                    return
                case .closing(let then):
                    if retire, then == .renew {
                        guard let next = save({ $0.lifecycle = .closing(then: .retire) }) else { return }
                        session = next
                        continue
                    }
                    do {
                        if let window = session.window {
                            try await tracked(then == .retire ? "finishing its session" : "closing its previous session") { try await ports.close(window) }
                        }
                    } catch is SignalOperatorCloseDeferred {
                        guard holds(session, pass: key, allowPaused: allowPaused),
                              workspace.state.operatorSession?.lifecycle == session.lifecycle,
                              workspace.state.operatorSession?.window == session.window else { return }
                        workspace.mutate { $0.operatorSession?.lifecycle = .open(since: now(), wake: nil) }
                        workspace.flush(); succeeded()
                        return
                    }
                    guard holds(session, pass: key, allowPaused: allowPaused),
                          let next = save({ $0.window = nil; $0.lifecycle = .revoking(then: then) }) else { return }
                    session = next
                case .revoking(let then):
                    if retire, then == .renew {
                        guard let next = save({ $0.lifecycle = .revoking(then: .retire) }) else { return }
                        session = next
                        continue
                    }
                    try await tracked("releasing its previous session") { try await ports.revoke(session.id) }
                    guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                    // The daemon refuses the revoked generation's token for good: the next chat, renewed
                    // or for a later workload, opens as the next generation.
                    guard let next = save({ record in
                        record.generation += 1
                        record.createdAt = now()
                        record.conversation = nil; record.session = nil
                        record.lifecycle = then == .retire ? .idle : .opening
                        record.prune(at: now())
                    }) else { return }
                    session = next
                    if then == .retire { succeeded(); finished(); return }
                }
            }
        } catch { if pass == key { failed(OperationIssue.reason(of: error)) } }
    }
    /// Starts a fresh conversation for an open, idle chat whose context is due for it.
    func freshIfDue(contextTokens: Int?, idle: Bool) async {
        guard pass == nil, workspace.canChangeWorkspace, ports.canOpen(), let session = workspace.state.operatorSession,
              FreshStartPolicy.shouldStart(session: session, now: now(), contextTokens: contextTokens, idle: idle) else { return }
        workspace.mutate { $0.operatorSession?.lifecycle = .closing(then: .renew) }
        guard workspace.flush() else { return }
        await ensure()
    }
    /// Saves `change` to the session; the session as saved, or nil when the save failed.
    private func save(_ change: (inout OperatorSession) -> Void) -> OperatorSession? {
        workspace.mutate { state in
            guard var session = state.operatorSession else { return }
            change(&session); state.operatorSession = session
        }
        guard workspace.flush() else { return nil }
        return workspace.state.operatorSession
    }
    private func open(_ session: OperatorSession) async throws -> String {
        let digest = OperatorDigest(state: workspace.state, at: now(), oracleOn: oracleOn(), sessions: ports.sessions(), instructions: ports.instructions(), usage: ports.usage(), installed: ports.installedAgents())
        return try await tracked("starting its session") { try await ports.open(session, digest) }
    }
    private func tracked<Result>(_ words: String, _ body: @MainActor () async throws -> Result) async rethrows -> Result {
        if let activity { return try await activity.during(words, body) }
        return try await body()
    }
    private func holds(_ session: OperatorSession, pass key: UUID, allowPaused: Bool = false) -> Bool {
        pass == key && !Task.isCancelled && workspace.canChangeWorkspace && ports.canOpen()
            && workspace.state.operatorSession?.id == session.id
            && workspace.state.operatorSession?.generation == session.generation
            && (allowPaused || workspace.state.operatorSession?.paused != true)
    }
}
