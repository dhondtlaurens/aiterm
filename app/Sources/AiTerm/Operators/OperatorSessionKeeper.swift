import Foundation
import AiTermCore

/// A definite refusal means the old chat is still open. A transport failure remains uncertain.
struct SignalOperatorCloseDeferred: Error, LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// The chat could not open yet: you went back to typing or clicking while it was prepared. Not a failure; the
/// keeper opens it after your next pause.
struct OperatorOpenDeferred: Error {}

/// One Operator chat, its life saved as `OperatorSession.Lifecycle`: a generation opens, and an old chat
/// is closed, its token revoked, and then a fresh one opens (renew) or none does (retire). Retrying an
/// opening uses the same session generation; its I/O port adopts the window and token already prepared for it.
@MainActor @Observable final class OperatorSessionKeeper {
    struct Ports {
        var canOpen: @MainActor () -> Bool
        var close: @MainActor (String) async throws -> Void
        var revoke: @MainActor (UUID) async throws -> Void
        var open: @MainActor (OperatorSession) async throws -> String
        var existingWindow: @MainActor (OperatorSession) async throws -> String? = { _ in nil }
        /// Holds a chat the Operator opens on its own until you pause (`PauseGate`).
        var pause: PauseGate = .never
        /// Whether the chat is still wanted, by the workload its owner keeps it for: a held chat whose workload
        /// ended meanwhile stops waiting and does not open.
        var wanted: @MainActor () -> Bool = { true }
        /// Runs the retry that opens a held chat after your pause, owned apart from any pass.
        var start: @MainActor (@escaping @MainActor () async -> Void) -> Task<Void, Never> = { body in Task { await body() } }
    }
    private let workspace: WorkspaceStore
    private let now: () -> Date
    private let ports: Ports
    private var pass: UUID? {
        didSet { if pass == nil { let ended = passEnded; passEnded = []; ended.forEach { $0.resume() } } }
    }
    /// Those waiting for the running pass to end: you, having chosen the chat while a pass opens it.
    private var passEnded: [CheckedContinuation<Void, Never>] = []
    /// Whether you chose the chat while a pass was opening it, as that pass waited for the Operator's window turn:
    /// its open no longer waits for your pause (`OperatorChat`).
    private(set) var chosenMeanwhile = false
    /// Each pass reports how it ended, as the Operator's `session` source.
    var failed: @MainActor (String) -> Void = { _ in }
    var succeeded: @MainActor () -> Void = {}
    var finished: @MainActor () -> Void = {}
    var activity: OperatorActivityTracker?
    init(workspace: WorkspaceStore, now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.now = now; self.ports = ports
    }
    /// The retry that opens a chat held for your pause, while one waits.
    private(set) var pausedRetry: Task<Void, Never>?
    func stop() { pass = nil; pausedRetry?.cancel(); pausedRetry = nil }
    /// Keeps the chat as its workload needs it: a new generation opens, a renewal continues, and an open
    /// chat whose window was closed opens again only when `reopen` (the person chose its row, or the
    /// Operator has something to type into it). Nothing while a retirement runs. A chat the Operator opens on its own
    /// waits for your pause (`PauseGate`) without holding the pass, so whoever awaits `ensure` is never held up;
    /// one you `chose` opens at once.
    func ensure(allowPaused: Bool = false, reopen: Bool = false, chose: Bool = false) async {
        guard workspace.state.operatorSession?.lifecycle.isRetiring != true else { return }
        if chose, pass != nil {
            // A pass under way may be opening the chat, held for the window turn: it opens it for you, and this one
            // follows it, for a chat it did not open.
            chosenMeanwhile = true
            await withCheckedContinuation { passEnded.append($0) }
            chosenMeanwhile = false
        }
        await transition(retire: false, allowPaused: allowPaused, reopen: reopen, chose: chose)
    }
    /// Keep source polling and its saved metadata, but retire the chat when its workload ended and the chat
    /// is `idle` (`OperatorSession.chatIsIdle`). A retirement already saved continues whatever the rule
    /// says, even if a new match arrived during the close.
    func finishIfIdle(idle: Bool) async {
        guard let session = workspace.state.operatorSession else { return }
        if !session.lifecycle.isRetiring {
            guard !workspace.state.operatorHasWork, idle, session.lifecycle != .idle else { return }
        }
        await transition(retire: true, allowPaused: true, reopen: false, chose: false)
    }
    /// One pass through the lifecycle, each step saved before the next effect: close before revoke, revoke
    /// before the generation increments. `retire` turns a renewal under way into a retirement.
    private func transition(retire: Bool, allowPaused: Bool, reopen: Bool, chose: Bool) async {
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
            // A chat you chose while it waited for your pause, still opening, opens though you paused the Operator.
            if !retire, session.paused, session.lifecycle.isChanging, !(chose && session.lifecycle == .opening) { return }
            while true {
                switch session.lifecycle {
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
                    guard chose || ports.pause.isQuiet else { return openAfterPause(allowPaused: allowPaused, reopen: reopen) }
                    let window = try await open(session)
                    guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                    workspace.mutate { state in
                        state.operatorSession?.window = window; state.operatorSession?.lifecycle = .open(since: now(), wake: nil)
                    }
                    workspace.flush(); endPausedRetry(); succeeded()
                    return
                case .open(_, let wake):
                    if retire {
                        guard let next = save({ $0.lifecycle = .closing(then: .retire) }) else { return }
                        session = next
                        continue
                    }
                    if session.window != nil { succeeded(); return }
                    guard reopen else { return }
                    guard chose || ports.pause.isQuiet else { return openAfterPause(allowPaused: allowPaused, reopen: reopen) }
                    let window = try await open(session)
                    guard holds(session, pass: key, allowPaused: allowPaused) else { return }
                    workspace.mutate { state in
                        state.operatorSession?.window = window; state.operatorSession?.lifecycle = .open(since: now(), wake: wake)
                    }
                    workspace.flush(); endPausedRetry(); succeeded()
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
                        record.withdrawGateQuestions(at: now(), reason: "The chat that tried this command ended.")
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
        } catch is OperatorOpenDeferred {
            if pass == key { openAfterPause(allowPaused: allowPaused, reopen: reopen) }
        } catch { if pass == key { failed(OperationIssue.reason(of: error)) } }
    }
    /// The chat opened (you chose it, or a pass found you paused): a retry still waiting has nothing left to open, and
    /// its line on the row ends with it.
    private func endPausedRetry() { pausedRetry?.cancel(); pausedRetry = nil }
    /// What the Operator's row says while a chat waits for your pause, also while it is still opening.
    nonisolated static let pauseWords = "waiting for your pause to open its chat"
    /// Opens the held chat once you have paused, as the Operator's row says meanwhile; one retry at a time. A chat no
    /// longer wanted stops waiting, so the row's wait ends and the chat can retire.
    private func openAfterPause(allowPaused: Bool, reopen: Bool) {
        guard pausedRetry == nil else { return }
        let pause = ports.pause, wanted = ports.wanted
        pausedRetry = ports.start { [weak self] in
            await self?.tracked(Self.pauseWords) { await pause.quiet(while: wanted) }
            guard let self, !Task.isCancelled else { return }
            self.pausedRetry = nil
            guard wanted() else { return }
            await self.ensure(allowPaused: allowPaused, reopen: reopen)
        }
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
        try await tracked("starting its session") { try await ports.open(session) }
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
