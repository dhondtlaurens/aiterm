import Foundation
import AiTermCore

/// Wakes an idle operator when `run_status` would show it something new (spec §7.3): one short fixed
/// line typed into its own tab — `[AiTerm] 2 updates — call run_status` — through the daemon's delivery
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
    /// What the operator last saw of each run, and what was last looked at, both without their revision.
    private var acknowledgedStatus: [UUID: RunStatus] = [:], lastSeen: [UUID: RunStatus] = [:]
    private var updates: [UUID: Int] = [:], reasons: [UUID: String] = [:]
    private var armed: [UUID: Task<Void, Never>] = [:], retrying: [UUID: Task<Void, Never>] = [:]
    private var sending: Set<UUID> = []
    /// The latest delivery, for a test to await.
    private(set) var lastSend: Task<Void, Never>?

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
        let status = Self.content(status)
        guard status != lastSeen[run] else { return }
        lastSeen[run] = status
        guard let seen = acknowledgedStatus[run] else { acknowledgedStatus[run] = status; return }
        guard status != seen else { return }
        updates[run, default: 0] += 1
        arm(run)
    }

    /// The operator has seen `status`: it called `run_status`, or its own call made the change.
    func acknowledged(_ status: RunStatus, of run: UUID) {
        let status = Self.content(status)
        acknowledgedStatus[run] = status
        lastSeen[run] = status
        updates[run] = nil
        reasons[run] = nil
        armed.removeValue(forKey: run)?.cancel()
        retrying.removeValue(forKey: run)?.cancel()
    }

    /// A fixed reason to wake it — `reconnected`, `plan approved` — which is the line when it is the only news.
    func say(_ reason: String, to run: UUID) {
        reasons[run] = reason
        // The change that prompted it is often already counted: the reason stands for it.
        updates[run] = max(updates[run, default: 0], 1)
        arm(run)
    }

    /// The operator's tab changed: a wake held while it worked, or refused, goes now if it is idle.
    func operatorSessionChanged(_ run: UUID) {
        guard updates[run, default: 0] > 0, armed[run] == nil else { return }
        send(run)
    }

    /// A run gone or stopped: nothing about it is kept.
    func forget(_ run: UUID) {
        acknowledgedStatus[run] = nil
        lastSeen[run] = nil
        updates[run] = nil
        reasons[run] = nil
        armed.removeValue(forKey: run)?.cancel()
        retrying.removeValue(forKey: run)?.cancel()
    }

    static func line(updates count: Int, reason: String?) -> String {
        if let reason, count <= 1 { return "[AiTerm] \(reason) — call run_status" }
        return "[AiTerm] \(count) update\(count == 1 ? "" : "s") — call run_status"
    }

    /// A status as the operator reads its news: the revision counts calls, not changes.
    private static func content(_ status: RunStatus) -> RunStatus {
        var status = status
        status.revision = 0
        return status
    }

    private func arm(_ run: UUID) {
        guard armed[run] == nil else { return }
        let coalesce = self.coalesce, sleep = self.sleep
        armed[run] = Task { [weak self] in
            try? await sleep(coalesce)
            guard !Task.isCancelled, let self else { return }
            armed[run] = nil
            send(run)
        }
    }

    private func send(_ run: UUID) {
        let count = updates[run, default: 0]
        guard count > 0, !sending.contains(run), awake(run), let daemon = daemon(), let tab = session(run), tab.state != .working
        else { return }
        let text = Self.line(updates: count, reason: reasons[run])
        sending.insert(run)
        lastSend = Task { [weak self] in
            let delivery = try? await daemon.deliver(sessionId: tab.sessionId, text: text, ownership: 0, wake: true, worktree: nil)
            guard let self else { return }
            sending.remove(run)
            // Typed, or left in the input for the person to send: the news is out. Refused — the person
            // typing there, a prompt open — it waits for the next idle moment, or `retryAfter`.
            guard let delivery, delivery.result != .refused else { retryLater(run); return }
            retrying.removeValue(forKey: run)?.cancel()
            let left = updates[run, default: 0] - count
            updates[run] = left > 0 ? left : nil
            if left <= 0 { reasons[run] = nil }
        }
    }

    /// A wake refused while you type, or with unsent text in the input, is kept and tried again after
    /// `retryAfter` — once per wait, never in a loop — in case the tab shows no change to try it on. Its
    /// next `run_status` shows the news whether or not it ever lands.
    private func retryLater(_ run: UUID) {
        guard retrying[run] == nil, updates[run, default: 0] > 0 else { return }
        let wait = retryAfter, sleep = self.sleep
        retrying[run] = Task { [weak self] in
            try? await sleep(wait)
            guard !Task.isCancelled, let self else { return }
            retrying[run] = nil
            send(run)
        }
    }
}
