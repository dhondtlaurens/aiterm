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

/// Decides when you hear of what an operation needs (spec §4.1), by round 1's Routine rule until the
/// plan's Task 8 notifies everything at once. A question always shows in the overview at once; the rule
/// decides when it notifies, and the ones it holds are sent together. A worker's prompt, a blocked
/// task, a waiting plan and a finished operation notify at once.
@MainActor
final class OperatorNotifier {
    private let notifications: any OperatorNotifications
    private let now: @MainActor () -> Date
    /// The questions each run's stop is holding back, oldest first.
    private(set) var held: [UUID: [OperatorQuestion]] = [:]
    /// The questions this run of AiTerm has sent (`runId/questionId`): holding one again after a restart
    /// is for what was lost with the last run, not for what went out in this one.
    private var sent: Set<String> = []

    init(notifications: any OperatorNotifications, now: @escaping @MainActor () -> Date) {
        self.notifications = notifications
        self.now = now
    }

    func questionAsked(_ question: OperatorQuestion, in run: OperatorRun, otherWorkCanProceed: Bool) {
        if questionNotifies(holdsUpEverything: !otherWorkCanProceed, otherWorkCanProceed: otherWorkCanProceed, waited: 0) {
            post("question-\(run.id.uuidString)-\(question.id)", "The Operator asks you", question.text, to: .overview(run.id))
            sent.insert("\(run.id.uuidString)/\(question.id)")
        } else if held[run.id]?.contains(where: { $0.id == question.id }) != true {
            // `ask_you` is idempotent by key, so a repeat is not a second question.
            held[run.id, default: []].append(question)
        }
    }

    /// A question still open after AiTerm started again: what was held lived in memory only, so it is
    /// held again, to be sent by `releaseHeld` when the stop says so. Not decided here and not notified.
    func rehold(_ question: OperatorQuestion, in run: OperatorRun) {
        guard held[run.id]?.contains(where: { $0.id == question.id }) != true,
              !sent.contains("\(run.id.uuidString)/\(question.id)") else { return }
        held[run.id, default: []].append(question)
        held[run.id]?.sort { $0.askedAt < $1.askedAt }
    }

    /// Sends what the run's stop has held, once the stop says it is time — or the run has ended: asked
    /// on every reconcile pass.
    func releaseHeld(in run: OperatorRun, otherWorkCanProceed: Bool) {
        guard let oldest = held[run.id]?.first else { return }
        let ended = run.state == .complete || run.state == .stopped
        guard ended || questionNotifies(holdsUpEverything: !otherWorkCanProceed, otherWorkCanProceed: otherWorkCanProceed,
                                        waited: now().timeIntervalSince(oldest.askedAt)) else { return }
        postHeld(in: run)
    }

    /// A worker waits on a prompt only you answer: its window opens from the note.
    func workerPrompt(_ kind: PromptKind?, task: TaskItem, in run: OperatorRun) {
        let agent = task.agent.harness.displayName
        let body = kind == .permission ? "\(agent) asks for permission. Answer it in its window."
                                       : "\(agent) shows a prompt AiTerm can’t read. Answer it in its window."
        post("prompt-\(task.id.uuidString)", "\(task.title) waits on you", body, to: .task(task.id))
    }

    /// A blocked task notifies at once at every stop, and sends with it the questions the stop was holding.
    func taskBlocked(_ task: TaskItem, reason: String, in run: OperatorRun) {
        post("blocked-\(task.id.uuidString)", "“\(run.name)” is held up", "\(task.title): \(reason)", to: .overview(run.id))
        postHeld(in: run)
    }

    /// A finished operation notifies at once, and sends with it the questions the stop was holding.
    func runComplete(_ run: OperatorRun) {
        post("done-\(run.id.uuidString)", "“\(run.name)” is done", "The Operator finished the operation.", to: .overview(run.id))
        postHeld(in: run)
    }

    /// Whether a question notifies now rather than being held: when it holds up everything, when no
    /// other work can go on, or once the oldest held one has waited `routineBundleAfter`.
    private func questionNotifies(holdsUpEverything: Bool, otherWorkCanProceed: Bool, waited: TimeInterval) -> Bool {
        holdsUpEverything || !otherWorkCanProceed || waited >= OperatorTiming.routineBundleAfter
    }

    private func postHeld(in run: OperatorRun) {
        guard let questions = held.removeValue(forKey: run.id), let first = questions.first else { return }
        for question in questions { sent.insert("\(run.id.uuidString)/\(question.id)") }
        let body = questions.count == 1 ? first.text : "\(questions.count) questions wait on you in “\(run.name)”."
        post("questions-\(run.id.uuidString)", "The Operator asks you", body, to: .overview(run.id))
    }

    private func post(_ id: String, _ title: String, _ body: String, to target: OperatorNote.Target) {
        notifications.post(OperatorNote(id: id, title: title, body: body, target: target))
    }
}
