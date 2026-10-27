import Foundation
import AiTermCore

/// Wakes an idle operator when `run_status` would show it news it acts on (spec §7.3, `News`): one short fixed
/// line typed into its own tab — `[AiTerm] updates waiting, call run_status` — through the daemon's
/// delivery with `wake: true`, which holds it while you type there and needs no pass from the delivery
/// check. A burst within `coalesce` is one line. A working operator is not typed at: the line waits for
/// its tab to be idle, and news undone before its line goes wakes nobody. Wake lines are hints: the
/// operator's next `run_status` shows everything, whether or not one landed. A line refused for anything
/// but your typing or a prompt waiting on you is reported (`refused`) for the sidebar's Notice, which
/// `cleared` takes down.
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
        /// The news a delivered line told since the Operator last looked, and what its own calls changed meanwhile
        /// (`ownChange`): not news again until it looks.
        var told: Set<News> = []
        /// The spells (`News.isSpell`) the Operator was told of or saw in `run_status`, kept until each is over: each is news once.
        var spells: Set<News> = []
        /// The news unsent at the last look (`unsent`): a look that adds to it is another update.
        var unsentNews: Set<News> = []
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
            unsentNews = []
            armed?.cancel(); armed = nil
            retrying?.cancel(); retrying = nil
        }
    }
    private struct Snapshot { let generation: UUID, count: Int, news: Set<News> }
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
    /// the `reconnected` line says the rest — and news the operator has not seen or been told since arms a
    /// wake. News undone before its line goes, so that none is left, drops the wake but for a reason said.
    func observe(_ status: RunStatus, of run: UUID) {
        let status = Self.content(status), wake = state(for: run)
        guard status != wake.lastSeen else { return }
        wake.lastSeen = status
        guard wake.acknowledgedStatus != nil else { wake.acknowledgedStatus = status; seeSpells(in: status, wake); return }
        // A spell over is forgotten: when it comes again, it is news again.
        wake.spells.formIntersection(Self.spells(in: status).open)
        let news = unsent(wake), before = wake.unsentNews
        wake.unsentNews = news
        guard !news.isEmpty else { undone(wake); return }
        guard !news.isSubset(of: before) else { return }
        wake.updates += 1
        arm(run, wake)
    }

    /// The operator has seen `status`: it called `run_status`, or its own call made the change.
    func acknowledged(_ status: RunStatus, of run: UUID) {
        let status = Self.content(status), wake = state(for: run)
        wake.clearPending()
        wake.acknowledgedStatus = status
        wake.lastSeen = status
        wake.told = []
        seeSpells(in: status, wake)
        cleared?(run)
    }

    /// One synchronous change the tool made: callers bracket the write, never an await. News that
    /// arrived while a tool was suspended is already in `before` and stays unread; what the call itself
    /// changed is the operator's own, never news to it.
    func ownChange(from before: RunStatus, to after: RunStatus, of run: UUID) {
        guard Self.content(before) == wakes[run]?.acknowledgedStatus, wakes[run]?.reason == nil else {
            wakes[run]?.told.formUnion(Self.news(from: Self.content(before), to: Self.content(after)))
            return
        }
        acknowledged(after, of: run)
    }

    /// A fixed reason to wake it — `reconnected`, `broadcast complete` — which is the line when it is the only news
    /// and plain (`isPlain`). `colon` joins it to the call with a colon, after news about one task:
    /// `[AiTerm] <reason>: call run_status`.
    func say(_ reason: String, to run: UUID, unlessAcknowledged status: RunStatus? = nil, colon: Bool = false) {
        let wake = state(for: run)
        if let status, Self.content(status) == wake.acknowledgedStatus { return }
        wake.reason = Reason(text: reason, colon: colon)
        // A reason stands for an update already counted, except news in an outstanding delivery:
        // that snapshot cannot have said this reason, so it must leave at least one update behind.
        wake.updates = max(wake.updates, sent(wake) + 1)
        arm(run, wake)
    }

    /// The updates in an outstanding delivery of the current generation.
    private func sent(_ wake: WakeState) -> Int {
        wake.sending.flatMap { $0.generation == wake.generation ? $0.count : nil } ?? 0
    }

    /// The news counted is undone, and none is left unsent: no line goes for it. A reason said still goes, as the only
    /// news; a line already out is left to land.
    private func undone(_ wake: WakeState) {
        if wake.reason != nil { wake.updates = min(wake.updates, sent(wake) + 1); return }
        wake.updates = 0
        wake.armed?.cancel(); wake.armed = nil
        wake.retrying?.cancel(); wake.retrying = nil
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
        wake.told = []
        wake.spells = []
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
    /// no reason the kind of news it is when it is one piece (`turnReason`), however many changes brought it; otherwise
    /// that updates wait. Never a count: no line carries a digit.
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

    /// The line for a review with nothing waiting (spec §K): the kind of news, never the task's key (as `turnReasons`).
    static let reviewQuietReason = "one task is in review with nothing waiting"

    /// The kind of news `news` is when it is one piece with a line of its own: a worker's ended turn (`turnReasons`; the
    /// worker's status moving with it, and its task leaving ready or background, are no news), or a review with nothing
    /// waiting. Nil for any other news, which is the generic line, several pieces at once among it.
    static func turnReason(for news: Set<News>) -> String? {
        guard news.count == 1, let only = news.first else { return nil }
        switch only {
        case .asks: return turnReasons[0]
        case .listed(.changedAfterAcceptance, _): return turnReasons[1]
        case .listed(.finishedWithoutCommit, _): return turnReasons[2]
        case .answered: return turnReasons[3]
        case .quietReview: return reviewQuietReason
        default: return nil
        }
    }

    /// A piece of news the Operator acts on, between what it last looked at and what `run_status` would answer now
    /// (`news(from:to:)`). Each carries what it says, so that news told is not told again, and a different value is new.
    /// What runs where (each worker's and tab's live state, the background lists) is never news on its own, nor is a task
    /// leaving a list: the Operator reads them when it looks, and what follows from them (a task ready, a prompt waiting)
    /// is news of its own.
    enum News: Hashable, Sendable {
        /// The broadcast changed: its state, its plan, its summary falling due. Never its snags and finds, which the
        /// Operator records itself.
        case run(RunNews)
        /// A task's state, why it is blocked or can't merge, whether you hold it, and its agent review, as they are now.
        case state(UUID, OperatedState), blocked(UUID, String?), mergeRefusal(UUID, String?), takenOver(UUID, Bool)
        case agentReview(UUID, AgentKind?, String?)
        /// A flag newly on a task, but `possiblyStalled` and `uncertain`, whose lists say them.
        case flagged(UUID, OperatedFlag)
        /// One of its workers stopped short of finishing its turn (`TaskLine.stoppedOn`).
        case stopped(UUID, String)
        /// A task newly on one of the obligation lists (`List`), by its key.
        case listed(List, String)
        /// A question new or reworded, by its key; what you typed in its worker's window onto it; a worker's question.
        case question(String, String), answered(String, String), asks(String, String)
        /// A spell, news once however often it comes and goes while it lasts: a task's review with nothing waiting, by
        /// the review's start, and a task uncertain while its worker works.
        case quietReview(UUID, Date), uncertain(UUID)

        var isSpell: Bool {
            switch self {
            case .quietReview, .uncertain: true
            default: false
            }
        }
    }

    /// The obligation lists of task keys whose new entries are news: all but `background`, and `uncertain` and
    /// `reviewQuiet`, which are spells.
    enum List: CaseIterable, Sendable {
        case promptsWaitingOnYou, readyForAcceptance, possiblyStalled, branchDrift, changedAfterAcceptance, finishedWithoutCommit

        func keys(_ obligations: RunStatus.Obligations) -> [String] {
            switch self {
            case .promptsWaitingOnYou: obligations.promptsWaitingOnYou
            case .readyForAcceptance: obligations.readyForAcceptance
            case .possiblyStalled: obligations.possiblyStalled
            case .branchDrift: obligations.branchDrift
            case .changedAfterAcceptance: obligations.changedAfterAcceptance
            case .finishedWithoutCommit: obligations.finishedWithoutCommit
            }
        }
    }

    /// The broadcast as `News.run` compares it.
    struct RunNews: Hashable, Sendable {
        let run: RunStatus.Run
        static func == (a: Self, b: Self) -> Bool { a.run == b.run }
        func hash(into hasher: inout Hasher) { hasher.combine(run.state) }
    }

    /// What `status` brings that `seen` did not, but its spells (`spells(in:)`).
    static func news(from seen: RunStatus, to status: RunStatus) -> Set<News> {
        var news = Set<News>()
        func recorded(_ run: RunStatus.Run) -> RunStatus.Run { var run = run; run.snags = []; run.finds = []; return run }
        if recorded(status.run) != recorded(seen.run) { news.insert(.run(RunNews(run: recorded(status.run)))) }
        let before = Dictionary(seen.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for task in status.tasks {
            let old = before[task.id], id = task.id
            if old?.state != task.state { news.insert(.state(id, task.state)) }
            if old?.blockedReason != task.blockedReason { news.insert(.blocked(id, task.blockedReason)) }
            if old?.mergeRefusal != task.mergeRefusal { news.insert(.mergeRefusal(id, task.mergeRefusal)) }
            if old?.takenOver ?? false != task.takenOver { news.insert(.takenOver(id, task.takenOver)) }
            if old?.agentReview != task.agentReview { news.insert(.agentReview(id, task.agentReview?.agent, task.agentReview?.state)) }
            for flag in Set(task.flags).subtracting(old?.flags ?? []).subtracting([.possiblyStalled, .uncertain]) {
                news.insert(.flagged(id, flag))
            }
            if let stopped = task.stoppedOn, stopped != old?.stoppedOn { news.insert(.stopped(id, stopped)) }
        }
        let now = status.obligations, was = seen.obligations
        for list in List.allCases {
            for key in list.keys(now) where !list.keys(was).contains(key) { news.insert(.listed(list, key)) }
        }
        for question in now.questionsWaiting {
            let old = was.questionsWaiting.first { $0.key == question.key }
            if old?.text != question.text { news.insert(.question(question.key, question.text)) }
            if let typed = question.answeredInWindow, typed != old?.answeredInWindow { news.insert(.answered(question.key, typed)) }
        }
        for ask in now.workerAsks where !was.workerAsks.contains(ask) { news.insert(.asks(ask.key, ask.question)) }
        return news
    }

    /// The spells `status` lists (`News.isSpell`), and those still going on, listed or not: a review until it is over, a
    /// task's uncertainty until it is neither uncertain nor its worker at work.
    static func spells(in status: RunStatus) -> (listed: Set<News>, open: Set<News>) {
        let quiet = Set(status.obligations.reviewQuiet), uncertain = Set(status.obligations.uncertain)
        var listed = Set<News>(), open = Set<News>()
        for task in status.tasks {
            if task.state == .inReview, let began = task.peopleReview?.startedAt {
                open.insert(.quietReview(task.id, began))
                if quiet.contains(task.key) { listed.insert(.quietReview(task.id, began)) }
            }
            if uncertain.contains(task.key) || task.live == .working || task.live == .workingQuiet {
                open.insert(.uncertain(task.id))
                if uncertain.contains(task.key) { listed.insert(.uncertain(task.id)) }
            }
        }
        return (listed, open)
    }

    /// The Operator looked at `status`: what spells it lists are seen, and those over are forgotten.
    private func seeSpells(in status: RunStatus, _ wake: WakeState) {
        let spells = Self.spells(in: status)
        wake.spells.formIntersection(spells.open)
        wake.spells.formUnion(spells.listed)
    }

    /// The news in what `run_status` would answer now that the Operator has neither seen nor been told.
    private func unsent(_ wake: WakeState) -> Set<News> {
        guard let seen = wake.acknowledgedStatus, let status = wake.lastSeen else { return [] }
        return Self.news(from: seen, to: status).subtracting(wake.told).union(Self.spells(in: status).listed.subtracting(wake.spells))
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
    /// the agents' model lists, or what each host says of a task's request (`TaskLine.mergeRequest`), which only
    /// `run_status` itself reads; nor what a worker runs now and what became of the slash commands sent to it, the
    /// operator's own message_task's "delivered" among them, which it reads when it looks at that task.
    private static func content(_ status: RunStatus) -> RunStatus {
        var status = status
        status.revision = 0
        status.run.usage = [:]
        status.run.agents.installed = [:]
        for index in status.tasks.indices {
            status.tasks[index].mergeRequest = nil
            status.tasks[index].mergeRequestNote = nil
            status.tasks[index].liveModel = nil
            status.tasks[index].liveReasoning = nil
            status.tasks[index].slashCommands = nil
            for tab in status.tasks[index].tabs?.indices ?? 0..<0 {
                status.tasks[index].tabs?[tab].liveModel = nil
                status.tasks[index].tabs?[tab].liveReasoning = nil
                status.tasks[index].tabs?[tab].slashCommands = nil
            }
        }
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
        // News counted and since undone wakes nobody: the run reads as the Operator saw it, or was told it.
        let news = unsent(wake)
        guard !news.isEmpty || wake.reason != nil else { undone(wake); return }
        let snapshot = Snapshot(generation: wake.generation, count: count, news: news)
        let text = Self.line(updates: count, reason: wake.reason, turn: Self.turnReason(for: news))
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
            let spells = snapshot.news.filter(\.isSpell)
            wake.told.formUnion(snapshot.news.subtracting(spells))
            wake.spells.formUnion(spells)
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
