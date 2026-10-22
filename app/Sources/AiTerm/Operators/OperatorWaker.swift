import Foundation
import AiTermCore

/// Wakes an idle operator when `run_status` would show it something new (spec §7.3): one short fixed
/// line typed into its own tab — `[AiTerm] updates waiting, call run_status` — through the daemon's
/// delivery with `wake: true`, which holds it while you type there and needs no pass from the delivery
/// check. A burst within `coalesce` is one line. A working operator is not typed at: the line waits for
/// its tab to be idle. Wake lines are hints: the operator's next `run_status` shows everything, whether
/// or not one landed. A line refused for anything but your typing or a prompt waiting on you is reported
/// (`refused`) for the sidebar's Notice, which `cleared` takes down.
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
        /// What a worker's ended turn brought, when that is all the news since the Operator last looked (`turnReason`).
        var turn: String?
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
            turn = nil
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
    /// A wake line the daemon refused for anything but a prompt that waits on you (`OperatorWakeNotice`).
    var refused: (@MainActor (UUID, Delivery) -> Void)?
    /// The operator is awake, or its run is gone: it called `run_status`, a wake line was delivered, or the run was forgotten.
    var cleared: (@MainActor (UUID) -> Void)?
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
        // A worker's ended turn says which kind of news it brought (spec §J), while it is the only news since.
        wake.turn = Self.turnReason(from: seen, to: status)
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
        cleared?(run)
    }

    /// One synchronous change the tool made: callers bracket the write, never an await. News that
    /// arrived while a tool was suspended is already in `before` and stays unread.
    func ownChange(from before: RunStatus, to after: RunStatus, of run: UUID) {
        guard Self.content(before) == wakes[run]?.acknowledgedStatus, wakes[run]?.reason == nil else { return }
        acknowledged(after, of: run)
    }

    /// A fixed reason to wake it — `reconnected`, `operation complete` — which is the line when it is the only news
    /// and plain (`isPlain`). `colon` joins it to the call with a colon, after news about one task:
    /// `[AiTerm] <reason>: call run_status`.
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
        cleared?(run)
    }

    private func state(for run: UUID) -> WakeState {
        if let wake = wakes[run] { wake.isForgotten = false; return wake }
        let wake = WakeState()
        wakes[run] = wake
        return wake
    }

    /// The line for `count` updates: the reason when it is the only news and plain enough to type (`isPlain`), or with
    /// no reason a worker's `turn` news (`turnReason`), however many changes brought it; otherwise that updates wait. Never
    /// a count: no line carries a digit.
    static func line(updates count: Int, reason: Reason?, turn: String? = nil) -> String {
        if let reason, count <= 1, isPlain(reason.text) { return "[AiTerm] \(reason.text)\(reason.colon ? ":" : ",") call run_status" }
        if reason == nil, let turn, isPlain(turn) { return "[AiTerm] \(turn), call run_status" }
        return "[AiTerm] updates waiting, call run_status"
    }

    /// What a worker's ended turn brings, one line per kind (spec §J): a worker that asks something (`workerAsks`), a task
    /// changed after its acceptance (`changedAfterAcceptance`), a task that finished with no commit
    /// (`finishedWithoutCommit`); and, last, a prompt you typed in a worker's window onto an open question (spec §I,
    /// `Question.answeredInWindow`). Each names the kind and never the task or question: a key's digits are what a menu
    /// opening as the line lands could take for its answer, and `run_status` names which.
    static let turnReasons = ["one worker asks something", "one task changed after acceptance", "one task finished with no commit",
                              "you may have answered one question in its worker's window"]

    /// The turn line for the news between `seen`, what the Operator last looked at, and `status`: exactly one new entry in
    /// the three lists of `turnReasons`, or one question newly showing what you typed in its worker's window, and nothing
    /// else it acts on changed but that task leaving ready or background. The worker's status moving with its turn's end
    /// is part of that news. Nil for any other news, which is the generic line, several turns at once among it.
    static func turnReason(from seen: RunStatus, to status: RunStatus) -> String? {
        let now = status.obligations, was = seen.obligations
        let answered = now.questionsWaiting.filter { question in
            question.answeredInWindow != nil && was.questionsWaiting.first { $0.key == question.key }?.answeredInWindow != question.answeredInWindow
        }
        let news = [now.workerAsks.map(\.key).filter { key in !was.workerAsks.contains { $0.key == key } },
                    now.changedAfterAcceptance.filter { !was.changedAfterAcceptance.contains($0) },
                    now.finishedWithoutCommit.filter { !was.finishedWithoutCommit.contains($0) },
                    answered.map(\.key)]
        guard news.joined().count == 1, let kind = news.firstIndex(where: { !$0.isEmpty }), let key = news[kind].first else { return nil }
        func rest(_ obligations: RunStatus.Obligations) -> RunStatus.Obligations {
            var rest = obligations
            rest.workerAsks = []; rest.changedAfterAcceptance = []; rest.finishedWithoutCommit = []
            // What you typed on a question is that news and no other change to it.
            for i in rest.questionsWaiting.indices { rest.questionsWaiting[i].answeredInWindow = nil }
            if kind < 3 { rest.readyForAcceptance.removeAll { $0 == key }; rest.background.removeAll { $0 == key } }
            return rest
        }
        return rest(now) == rest(was) && seen.run == status.run ? turnReasons[kind] : nil
    }

    /// Whether `text` may go into a wake line: no digit and no one-letter word, which a menu opening as the
    /// line arrives could take for its answer (`1`, `y`, `a`); the daemon refuses such a line too
    /// (`delivery.wake_text_problem`). A reason that names a task by its key (`PAY-2`) is not plain: the line
    /// then says only that updates wait, and `run_status` says which.
    static func isPlain(_ text: String) -> Bool {
        guard !text.contains(where: \.isNumber) else { return false }
        let edges = CharacterSet.punctuationCharacters.union(.symbols)
        return !text.split(whereSeparator: \.isWhitespace).contains { word in
            let bare = String(word).trimmingCharacters(in: edges)
            return bare.count == 1 && bare.first?.isLetter == true
        }
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
        let text = Self.line(updates: count, reason: wake.reason, turn: wake.turn)
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
            // typing there, a prompt open — it waits for the next idle moment, or `retryAfter`. Any refusal
            // but those, which already wait on the person, is theirs to see (`refused`).
            guard let delivery, delivery.result != .refused else {
                if let delivery, OperatorWakeNotice.shows(delivery.code) { refused?(run, delivery) }
                retryLater(run, wake)
                return
            }
            if delivery.result == .delivered { cleared?(run) }
            wake.retrying?.cancel(); wake.retrying = nil
            wake.updates = max(0, wake.updates - snapshot.count)
            if wake.updates == 0 { wake.reason = nil; wake.turn = nil }
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
