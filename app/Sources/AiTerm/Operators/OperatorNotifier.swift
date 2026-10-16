import Foundation
import AiTermCore

/// One notification: what it says, and what a click on it opens — an operation's overview, or a task's
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
    /// Where a click on a note goes.
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)? { get set }
}

/// Decides when you hear of what an operation needs, by `InterruptPolicy` (spec §4.1). A question always
/// shows in the overview at once; the stop decides when it notifies, and the ones it holds are sent
/// together. A worker's prompt, a blocked task, a waiting plan and a finished operation notify at once.
@MainActor
final class OperatorNotifier {
    private let notifications: any OperatorNotifications
    private let now: @MainActor () -> Date
    /// The questions each run's stop is holding back, oldest first.
    private(set) var held: [UUID: [OperatorQuestion]] = [:]

    init(notifications: any OperatorNotifications, now: @escaping @MainActor () -> Date) {
        self.notifications = notifications
        self.now = now
    }

    func questionAsked(_ question: OperatorQuestion, in run: OperatorRun, otherWorkCanProceed: Bool) {
        if notifies(.question(holdsUpEverything: !otherWorkCanProceed), run, otherWorkCanProceed: otherWorkCanProceed, waited: 0) {
            post("question-\(run.id.uuidString)-\(question.id)", "\(run.persona.name) asks you", question.text, to: .overview(run.id))
        } else if held[run.id]?.contains(where: { $0.id == question.id }) != true {
            // `ask_you` is idempotent by key, so a repeat is not a second question.
            held[run.id, default: []].append(question)
        }
    }

    /// Sends what the run's stop has held, once the stop says it is time — or the run has ended: asked
    /// on every reconcile pass.
    func releaseHeld(in run: OperatorRun, otherWorkCanProceed: Bool) {
        guard let oldest = held[run.id]?.first else { return }
        let ended = run.state == .complete || run.state == .stopped
        guard ended || notifies(.question(holdsUpEverything: !otherWorkCanProceed), run, otherWorkCanProceed: otherWorkCanProceed,
                                waited: now().timeIntervalSince(oldest.askedAt)) else { return }
        postHeld(in: run)
    }

    /// A worker waits on a prompt only you answer: its window opens from the note.
    func workerPrompt(_ kind: PromptKind?, task: TaskItem, in run: OperatorRun) {
        guard notifies(kind == .permission ? .permissionPrompt : .unknownPrompt, run, otherWorkCanProceed: true, waited: 0) else { return }
        let agent = task.agent.harness.displayName
        let body = kind == .permission ? "\(agent) asks for permission. Answer it in its window."
                                       : "\(agent) shows a prompt AiTerm can’t read. Answer it in its window."
        post("prompt-\(task.id.uuidString)", "\(task.title) waits on you", body, to: .task(task.id))
    }

    func planWaiting(_ run: OperatorRun) {
        guard notifies(.planWaiting, run, otherWorkCanProceed: false, waited: 0) else { return }
        post("plan-\(run.id.uuidString)", "\(run.persona.name)’s plan waits for you", "Approve “\(run.name)” in its overview.",
             to: .overview(run.id))
    }

    /// A blocked task notifies at once at every stop, and sends with it the questions the stop was holding.
    func taskBlocked(_ task: TaskItem, reason: String, in run: OperatorRun) {
        if notifies(.runBlocked, run, otherWorkCanProceed: false, waited: 0) {
            post("blocked-\(task.id.uuidString)", "“\(run.name)” is held up", "\(task.title): \(reason)", to: .overview(run.id))
        }
        postHeld(in: run)
    }

    /// A finished operation notifies at once, and sends with it the questions the stop was holding.
    func runComplete(_ run: OperatorRun) {
        if notifies(.runComplete, run, otherWorkCanProceed: false, waited: 0) {
            post("done-\(run.id.uuidString)", "“\(run.name)” is done", "\(run.persona.name) finished the operation.", to: .overview(run.id))
        }
        postHeld(in: run)
    }

    private func notifies(_ event: InterruptPolicy.Event, _ run: OperatorRun, otherWorkCanProceed: Bool, waited: TimeInterval) -> Bool {
        InterruptPolicy.decide(event, autonomy: run.persona.autonomy, otherWorkCanProceed: otherWorkCanProceed, waited: waited) == .notifyNow
    }

    private func postHeld(in run: OperatorRun) {
        guard let questions = held.removeValue(forKey: run.id), let first = questions.first else { return }
        let body = questions.count == 1 ? first.text : "\(questions.count) questions wait on you in “\(run.name)”."
        post("questions-\(run.id.uuidString)", "\(run.persona.name) asks you", body, to: .overview(run.id))
    }

    private func post(_ id: String, _ title: String, _ body: String, to target: OperatorNote.Target) {
        notifications.post(OperatorNote(id: id, title: title, body: body, target: target))
    }
}
