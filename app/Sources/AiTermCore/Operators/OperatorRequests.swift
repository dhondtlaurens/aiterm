import Foundation

/// Something that needs you in a broadcast (spec §4.1): one thing, said once, as the notification, the
/// row and the banner say it. A request lasts exactly as long as what asks stands: answered, unblocked or
/// ended, it is gone.
public struct BroadcastRequest: Equatable, Sendable, Identifiable {
    /// What asks, most urgent first: an agent's prompt, then a question, then what blocks, then a problem in AiTerm.
    public enum Kind: String, CaseIterable, Sendable {
        case permission, question, blocked, problem

        /// Its place in that order, 0 the most urgent: of several requests, a line says and a click opens the lowest.
        public var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
    }
    public var kind: Kind
    public var runId: UUID
    /// The task it is about; nil for the Operator's own question.
    public var taskId: UUID?
    /// The whole request, as a sentence: the notification's body and a tooltip's text.
    public var text: String
    /// A question's key: each open question is its own request.
    public var key: String?
    /// The worker tab whose prompt it is, by key (`WorkerTab.firstKey` for the first worker); nil for a request
    /// no one tab makes.
    public var tab: String?

    /// What a notification is posted and withdrawn by: `request-<runId>-<taskId|run>-<kind>`, and for a
    /// question `request-<runId>-question-<questionKey>`.
    public var id: String {
        if kind == .question, let key { return "request-\(runId.uuidString)-question-\(key)" }
        return "request-\(runId.uuidString)-\(taskId?.uuidString ?? "run")-\(kind.rawValue)"
    }

    public init(kind: Kind, runId: UUID, taskId: UUID?, text: String, key: String? = nil, tab: String? = nil) {
        self.kind = kind; self.runId = runId; self.taskId = taskId; self.text = text; self.key = key; self.tab = tab
    }
}

public enum OperatorRequests {
    /// Every open request of the run: a worker's permission or unknown prompt, an open `ask_you` question,
    /// a blocked task and a task whose `problem` is set. A waiting worker's prompt is said by what its question
    /// recorded. A task you took over contributes none, and an ended run has none.
    public static func open(run: OperatorRun, state: AppState) -> [BroadcastRequest] {
        guard !run.hasEnded else { return [] }
        let tasks = state.tasks(inRun: run.id)
        // Taken over or finished: what is left open on it asks nothing.
        let silent = Set(tasks.filter { $0.operated?.takenOver == true || $0.operated.map(\.isFinished) == true }.map(\.id))
        var requests: [BroadcastRequest] = []

        for task in tasks where !silent.contains(task.id) {
            guard let operated = task.operated else { continue }
            // Of several tabs' prompts, the first by tab order: the first worker's, then the extra tabs' as they opened.
            let order = [nil] + operated.extraTabs.map(\.key)
            let rank = { (tab: String?) in order.firstIndex(of: tab) ?? order.count }
            let recorded = run.questions.filter { $0.task == task.id && $0.resolution == nil && $0.id.hasPrefix("prompt-") }
                .min { rank($0.tab) < rank($1.tab) }
            if let recorded {
                requests.append(BroadcastRequest(kind: .permission, runId: run.id, taskId: task.id,
                                                 text: sentence("\(recorded.text) in \(task.title)"), tab: recorded.tab ?? WorkerTab.firstKey))
            }
            if operated.problem != nil || operated.publication?.problem != nil {
                // The banner's sentence is the reason a blocked task keeps; one that kept its state has only the issue.
                let said = operated.publication?.problem ?? operated.blockedReason ?? "The problem is shown in the banner"
                requests.append(BroadcastRequest(kind: .problem, runId: run.id, taskId: task.id, text: sentence("\(task.title): \(said)")))
            } else if operated.state == .blocked {
                let reason = operated.blockedReason ?? "it needs you"
                requests.append(BroadcastRequest(kind: .blocked, runId: run.id, taskId: task.id, text: sentence("\(task.title) is blocked: \(reason)")))
            }
        }
        for question in run.questions where question.resolution == nil && !question.id.hasPrefix("prompt-") {
            if let task = question.task, silent.contains(task) { continue }
            requests.append(BroadcastRequest(kind: .question, runId: run.id, taskId: question.task, text: "The Operator asks: \(question.text)", key: question.id))
        }
        return requests
    }

    /// `text` as one sentence: ended with a full stop, never two.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

}
