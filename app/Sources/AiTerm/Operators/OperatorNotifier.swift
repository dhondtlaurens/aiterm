import Foundation
import AiTermCore

/// One notification: what it says, and what a click on it opens — a broadcast's board, or a task's
/// window for a prompt only you can answer (spec §10.3). Its `id` replaces an earlier one with the same id.
struct OperatorNote: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case board(UUID), task(UUID)

        /// The target as a notification carries it.
        var userInfo: [String: String] {
            switch self {
            case .board(let id): ["aiterm.overview": id.uuidString]
            case .task(let id): ["aiterm.task": id.uuidString]
            }
        }

        init?(userInfo: [AnyHashable: Any]) {
            if let id = (userInfo["aiterm.overview"] as? String).flatMap(UUID.init(uuidString:)) { self = .board(id) }
            else if let id = (userInfo["aiterm.task"] as? String).flatMap(UUID.init(uuidString:)) { self = .task(id) }
            else { return nil }
        }
    }
    var id: String, title: String, body: String, target: Target
}

/// Where notes go: macOS's notification centre in the app, a recording in a test.
@MainActor
protocol OperatorNotifications: AnyObject {
    /// Asks macOS, once, whether AiTerm may post. Denied, the attention counts and the board still show everything.
    func requestAuthorization()
    func post(_ note: OperatorNote)
    /// Takes the notes with these ids away: out of the notification centre if shown, and unsent if not yet.
    func withdraw(ids: [String])
    /// The ids of the notes macOS shows now: read once at launch, for what an earlier run left behind.
    func readDelivered() async -> [String]
    /// Where a click on a note goes.
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)? { get set }
}

/// Tells you the moment something needs you, and takes it back once it does not (spec §4.1): each open
/// request of a broadcast (`OperatorRequests`) is posted when it appears and withdrawn when it is answered,
/// unblocked or the broadcast ends, and a finished broadcast posts once its summary is settled: written, or given
/// up on (`RunSummary.isSettled`), never when its last task ends. Called with the run
/// whenever it or its tasks change: what it posts follows the state, never the events that led to it.
@MainActor
final class OperatorNotifier {
    private let notifications: any OperatorNotifications
    private let state: @MainActor () -> AppState
    /// What is showing now, by run: each id this run of AiTerm has sent and not withdrawn, with the body it
    /// carries, and from the launch's listing on each id an earlier run left that was still asked then.
    private var posted: [UUID: [String: String]] = [:]
    /// The launch's reading of the centre, for a test to await.
    private(set) var lastListing: Task<Void, Never>?

    /// `state` is the workspace as it stands.
    init(notifications: any OperatorNotifications, state: @escaping @MainActor () -> AppState) {
        self.notifications = notifications
        self.state = state
        lastListing = Task { [weak self] in
            guard let self else { return }
            takeDelivered(await notifications.readDelivered())
        }
    }

    /// The centre's listing has come, at launch: what an earlier run left that no run asks now is taken back,
    /// and what is still asked counts as showing for its run, so it is not posted again and the change that
    /// resolves it, or ends the run, withdraws it. Calls before the listing posted as they went, so they are
    /// not undone.
    private func takeDelivered(_ ids: [String]) {
        let delivered = Set(ids.filter { $0.hasPrefix("request-") || $0.hasPrefix("debrief-") })
        let state = state()
        var open: Set<String> = []
        for run in state.runs {
            let still = wanted(for: run, in: state).filter { delivered.contains($0.id) }
            open.formUnion(still.map(\.id))
            for note in still where posted[run.id]?[note.id] == nil { posted[run.id, default: [:]][note.id] = note.body }
        }
        let stale = delivered.subtracting(open)
        if !stale.isEmpty { notifications.withdraw(ids: stale.sorted()) }
    }

    /// The finished broadcast's note. Its `debrief-` prefix is what earlier builds posted it under: a note they
    /// delivered is not posted again.
    static func debriefId(_ run: UUID) -> String { "debrief-\(run.uuidString)" }

    /// What the run asks of you now, as notes: each request on its own, and once every task is done and its
    /// summary settled, that it is ready — or, given up on, that the tasks are done.
    private func wanted(for run: OperatorRun, in state: AppState) -> [OperatorNote] {
        var notes: [OperatorNote] = OperatorRequests.open(run: run, state: state).map { request in
            // A prompt only you can answer opens its task's window; anything else, the broadcast's board.
            var target = OperatorNote.Target.board(run.id)
            if request.kind == .permission, let task = request.taskId { target = .task(task) }
            return OperatorNote(id: request.id, title: run.name, body: request.text, target: target)
        }
        if let summary = OperatorLine.summary(of: run), summary.isSettled {
            let count = state.tasks(inRun: run.id).count
            let body = if case .written = summary { "The summary is ready." }
                else { count == 1 ? "The task is done." : "All \(count) tasks are done." }
            notes.append(OperatorNote(id: Self.debriefId(run.id), title: run.name, body: body, target: .board(run.id)))
        }
        return notes
    }

    /// Posts what the run now asks of you that it has not posted, and withdraws what it posted that no
    /// longer stands. An ended run asks nothing, so everything of it is withdrawn. A note says again, in
    /// place, when what it says has changed. What an earlier run of AiTerm left in the notification centre is
    /// dealt with when the launch's listing arrives (`takeDelivered`).
    func requestsChanged(run: OperatorRun) {
        let state = state()
        let run = state.run(id: run.id) ?? run
        let wanted = wanted(for: run, in: state)
        // What the launch's listing found still asked is in `posted` already (`takeDelivered`).
        var before = posted[run.id] ?? [:]
        for note in wanted where before[note.id] != note.body { notifications.post(note) }
        let gone = Set(before.keys).subtracting(wanted.map(\.id))
        if !gone.isEmpty { notifications.withdraw(ids: gone.sorted()) }
        before = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0.body) })
        posted[run.id] = before
    }
}
