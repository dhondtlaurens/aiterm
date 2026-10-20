import Foundation
import AiTermCore

/// Wakes an idle operator when `run_status` would show it something new (spec §7.3): one short fixed
/// line typed into its own tab — `[AiTerm] 2 updates, call run_status` — through the daemon's delivery
/// with `wake: true`, which holds it while you type there. A burst within `coalesce` is one line. A
/// working operator is not typed at: the line waits for its tab to be idle. Wake lines are hints: the
/// operator's next `run_status` shows everything, whether or not one landed.
@MainActor
final class OperatorWaker {
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// The operator's tab, while one is known.
    private let session: @MainActor (UUID) -> SessionInfo?
    /// Whether the run's operator may be woken: a planning, active or complete run's.
    private let awake: @MainActor (UUID) -> Bool
    private let coalesce: Duration
    /// How long a refused wake waits before it is tried again when the tab gives no sign meanwhile.
    private let retryAfter: Duration
    /// Waits out `coalesce` and `retryAfter`; a test hands in one it releases by hand.
    private let sleep: @MainActor (Duration) async throws -> Void
    /// Each run owns its news, timers and delivery together. Acknowledgment changes the generation;
    /// a delivery may consume only the snapshot it sent in that same generation.
    @MainActor private final class WakeState {
        var acknowledgedStatus: RunStatus?, lastSeen: RunStatus?
        var updates = 0
        var reason: Reason?
        var generation = UUID()
        var armed: Task<Void, Never>?, retrying: Task<Void, Never>?
        var sending: Snapshot?
        // A forgotten run retains only its outstanding delivery until the reply; a replacement
        // uses the same sentinel so two deliveries to its tab cannot overlap.
        var isForgotten = false

        func clearPending() {
            generation = UUID()
            updates = 0
            reason = nil
            armed?.cancel(); armed = nil
            retrying?.cancel(); retrying = nil
        }
    }
    private struct Snapshot { let generation: UUID, count: Int }
    private var wakes: [UUID: WakeState] = [:]
    /// A fixed reason, and what joins it to "call run_status": a comma, or a colon after news about one task.
    struct Reason: Equatable { var text: String, colon: Bool }
    /// The latest delivery, for a test to await.
    private(set) var lastSend: Task<Void, Never>?
    /// The latest coalescing pass, for a test to release and await.
    private(set) var lastCoalesce: Task<Void, Never>?

    init(daemon: @escaping @MainActor () -> (any DaemonCommands)?, session: @escaping @MainActor (UUID) -> SessionInfo?,
         awake: @escaping @MainActor (UUID) -> Bool, coalesce: Duration, retryAfter: Duration = .seconds(15),
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.daemon = daemon
        self.session = session
        self.awake = awake
        self.coalesce = coalesce
        self.retryAfter = retryAfter
        self.sleep = sleep
    }

    /// What `run_status` would answer now. The first look at a run is taken as seen — after a restart
    /// the `reconnected` line says the rest — and anything the operator has not seen since arms a wake.
    func observe(_ status: RunStatus, of run: UUID) {
        let status = Self.content(status), wake = state(for: run)
        guard status != wake.lastSeen else { return }
        wake.lastSeen = status
        guard let seen = wake.acknowledgedStatus else { wake.acknowledgedStatus = status; return }
        guard status != seen else { return }
        wake.updates += 1
        arm(run, wake)
    }

    /// The operator has seen `status`: it called `run_status`, or its own call made the change.
    func acknowledged(_ status: RunStatus, of run: UUID) {
        let status = Self.content(status), wake = state(for: run)
        wake.clearPending()
        wake.acknowledgedStatus = status
        wake.lastSeen = status
    }

    /// One synchronous change the tool made: callers bracket the write, never an await. News that
    /// arrived while a tool was suspended is already in `before` and stays unread.
    func ownChange(from before: RunStatus, to after: RunStatus, of run: UUID) {
        guard Self.content(before) == wakes[run]?.acknowledgedStatus, wakes[run]?.reason == nil else { return }
        acknowledged(after, of: run)
    }

    /// A fixed reason to wake it — `reconnected`, `operation complete` — which is the line when it is the only news.
    /// `colon` joins it to the call with a colon: `[AiTerm] Codex reviewed PAY-2: call run_status`.
    func say(_ reason: String, to run: UUID, unlessAcknowledged status: RunStatus? = nil, colon: Bool = false) {
        let wake = state(for: run)
        if let status, Self.content(status) == wake.acknowledgedStatus { return }
        wake.reason = Reason(text: reason, colon: colon)
        // A reason stands for an update already counted, except news in an outstanding delivery:
        // that snapshot cannot have said this reason, so it must leave at least one update behind.
        let sent = wake.sending.flatMap { $0.generation == wake.generation ? $0.count : nil } ?? 0
        wake.updates = max(wake.updates, sent + 1)
        arm(run, wake)
    }

    /// The operator's tab changed: a wake held while it worked, or refused, goes now if it is idle.
    func operatorSessionChanged(_ run: UUID) {
        guard let wake = wakes[run], !wake.isForgotten, wake.updates > 0, wake.armed == nil else { return }
        send(run, wake)
    }

    /// A run gone or stopped: drops its news and timers. Only an in-flight delivery's sentinel
    /// remains until its reply, so it cannot consume or overlap a replacement's news.
    func forget(_ run: UUID) {
        guard let wake = wakes[run] else { return }
        wake.clearPending()
        wake.acknowledgedStatus = nil
        wake.lastSeen = nil
        wake.isForgotten = true
        if wake.sending == nil { wakes[run] = nil }
    }

    private func state(for run: UUID) -> WakeState {
        if let wake = wakes[run] { wake.isForgotten = false; return wake }
        let wake = WakeState()
        wakes[run] = wake
        return wake
    }

    static func line(updates count: Int, reason: Reason?) -> String {
        if let reason, count <= 1 { return "[AiTerm] \(reason.text)\(reason.colon ? ":" : ",") call run_status" }
        return "[AiTerm] \(count) update\(count == 1 ? "" : "s"), call run_status"
    }

    /// A status as the operator reads its news: the revision counts calls, not changes, and the usage
    /// readings drift with every report: the operator reads them when it asks, they wake it never. Nor do
    /// the agents' model lists, which only `run_status` itself reads.
    private static func content(_ status: RunStatus) -> RunStatus {
        var status = status
        status.revision = 0
        status.run.usage = [:]
        status.run.agents = [:]
        return status
    }

    private func arm(_ run: UUID, _ wake: WakeState) {
        guard wake.armed == nil else { return }
        let coalesce = self.coalesce, sleep = self.sleep
        wake.armed = Task { [weak self] in
            try? await sleep(coalesce)
            guard !Task.isCancelled, let self else { return }
            wake.armed = nil
            send(run, wake)
        }
        lastCoalesce = wake.armed
    }

    private func send(_ run: UUID, _ wake: WakeState) {
        let count = wake.updates
        guard count > 0, wake.sending == nil, awake(run), let daemon = daemon(), let tab = session(run), tab.state != .working
        else { return }
        let snapshot = Snapshot(generation: wake.generation, count: count)
        let text = Self.line(updates: count, reason: wake.reason)
        wake.sending = snapshot
        lastSend = Task { [weak self] in
            let delivery = try? await daemon.deliver(sessionId: tab.sessionId, text: text, ownership: 0, wake: true, worktree: nil)
            guard let self else { return }
            wake.sending = nil
            if wake.isForgotten { wakes[run] = nil; return }
            guard wake.generation == snapshot.generation else {
                // Acknowledged news belongs to the old snapshot; replacement news may already
                // have waited out its coalescing period while the delivery was out.
                if wake.armed == nil { send(run, wake) }
                return
            }
            // Typed, or left in the input for the person to send: the news is out. Refused — the person
            // typing there, a prompt open — it waits for the next idle moment, or `retryAfter`.
            guard let delivery, delivery.result != .refused else { retryLater(run, wake); return }
            wake.retrying?.cancel(); wake.retrying = nil
            wake.updates = max(0, wake.updates - snapshot.count)
            if wake.updates == 0 { wake.reason = nil }
            // A timer that fired during delivery could not send then. Already-coalesced news
            // that arrived meanwhile gets its own wake now.
            if wake.updates > 0, wake.armed == nil { send(run, wake) }
        }
    }

    /// A wake refused while you type, or with unsent text in the input, is kept and tried again after
    /// `retryAfter` — once per wait, never in a loop — in case the tab shows no change to try it on. Its
    /// next `run_status` shows the news whether or not it ever lands.
    private func retryLater(_ run: UUID, _ wake: WakeState) {
        guard wake.retrying == nil, wake.updates > 0 else { return }
        let wait = retryAfter, sleep = self.sleep
        wake.retrying = Task { [weak self] in
            try? await sleep(wait)
            guard !Task.isCancelled, let self else { return }
            wake.retrying = nil
            send(run, wake)
        }
    }
}
