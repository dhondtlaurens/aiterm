import Foundation
import AiTermCore

/// One notification: what it says, and what a click on it opens — a broadcast's overview, or a task's
/// window for a prompt only you can answer (spec §10.3). Its `id` replaces an earlier one with the same id.
struct OperatorNote: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case overview(UUID), task(UUID)

        /// The target as a notification carries it.
        var userInfo: [String: String] {
            switch self {
            case .overview(let id): ["aiterm.overview": id.uuidString]
            case .task(let id): ["aiterm.task": id.uuidString]
            }
        }

        init?(userInfo: [AnyHashable: Any]) {
            if let id = (userInfo["aiterm.overview"] as? String).flatMap(UUID.init(uuidString:)) { self = .overview(id) }
            else if let id = (userInfo["aiterm.task"] as? String).flatMap(UUID.init(uuidString:)) { self = .task(id) }
            else { return nil }
        }
    }
    var id: String, title: String, body: String, target: Target
}

/// Where notes go: macOS's notification centre in the app, a recording in a test.
@MainActor
protocol OperatorNotifications: AnyObject {
    /// Asks macOS, once, whether AiTerm may post. Denied, the attention counts and the overview still show everything.
    func requestAuthorization()
    func post(_ note: OperatorNote)
    /// Takes the notes with these ids away: out of the notification centre if shown, and unsent if not yet.
    func withdraw(ids: [String])
    /// The ids of the notes macOS still showed when AiTerm started: what an earlier run left behind.
    var deliveredAtLaunch: [String] { get }
    /// Where a click on a note goes.
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)? { get set }
}

/// Tells you the moment something needs you, and takes it back once it does not (spec §4.1): each open
/// request of a broadcast (`OperatorRequests`) is posted when it appears and withdrawn when it is answered,
/// unblocked or the broadcast ends, and a finished broadcast posts its debrief once. Called with the run
/// whenever it or its tasks change: what it posts follows the state, never the events that led to it.
@MainActor
final class OperatorNotifier {
    private let notifications: any OperatorNotifications
    private let state: @MainActor () -> AppState
    private let prompts: @MainActor () -> [UUID: String]
    /// What is posted now, by run: each id this run of AiTerm has sent and not withdrawn, with the body it carries.
    private var posted: [UUID: [String: String]] = [:]
    /// What an earlier run of AiTerm left in the notification centre, read once, at the first call.
    private var leftBehind: Set<String>?

    /// `state` is the workspace as it stands; `prompts` what each waiting worker's prompt asks, by task,
    /// where it is known (`OperatorRequests.open`).
    init(notifications: any OperatorNotifications, state: @escaping @MainActor () -> AppState,
         prompts: @escaping @MainActor () -> [UUID: String] = { [:] }) {
        self.notifications = notifications
        self.state = state
        self.prompts = prompts
    }

    static func debriefId(_ run: UUID) -> String { "debrief-\(run.uuidString)" }

    /// What the run asks of you now, as notes: each request on its own, and the debrief once it is complete.
    private func wanted(for run: OperatorRun, in state: AppState) -> [OperatorNote] {
        var notes: [OperatorNote] = OperatorRequests.open(run: run, state: state, prompts: prompts()).map { request in
            // A prompt only you can answer opens its task's window; anything else, the broadcast's overview.
            var target = OperatorNote.Target.overview(run.id)
            if request.kind == .permission, let task = request.taskId { target = .task(task) }
            return OperatorNote(id: request.id, title: run.name, body: request.text, target: target)
        }
        if run.state == .complete, run.intent != .stopped {
            let count = state.tasks(inRun: run.id).count
            notes.append(OperatorNote(id: Self.debriefId(run.id), title: run.name,
                                      body: count == 1 ? "The task is done. The debrief is ready." : "All \(count) tasks are done. The debrief is ready.",
                                      target: .overview(run.id)))
        }
        return notes
    }

    /// Posts what the run now asks of you that it has not posted, and withdraws what it posted that no
    /// longer stands. An ended run asks nothing, so everything of it is withdrawn. A note says again, in
    /// place, when what it says has changed. The first call also takes back what an earlier run of AiTerm
    /// left in the notification centre that no run asks any more, and does not post again what it left
    /// that is still asked.
    func requestsChanged(run: OperatorRun) {
        let state = state()
        let run = state.run(id: run.id) ?? run
        if leftBehind == nil {
            let delivered = Set(notifications.deliveredAtLaunch.filter { $0.hasPrefix("request-") || $0.hasPrefix("debrief-") })
            leftBehind = delivered
            let open = Set(state.runs.flatMap { wanted(for: $0, in: state).map(\.id) })
            let stale = delivered.subtracting(open)
            if !stale.isEmpty { notifications.withdraw(ids: stale.sorted()) }
        }
        let wanted = wanted(for: run, in: state)
        // A run first seen: what the earlier run left for it, still asked, counts as posted.
        var before = posted[run.id] ?? Dictionary(uniqueKeysWithValues: wanted.filter { leftBehind?.contains($0.id) == true }.map { ($0.id, $0.body) })
        for note in wanted where before[note.id] != note.body { notifications.post(note) }
        let gone = Set(before.keys).subtracting(wanted.map(\.id))
        if !gone.isEmpty { notifications.withdraw(ids: gone.sorted()) }
        before = Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0.body) })
        posted[run.id] = before
    }
}
