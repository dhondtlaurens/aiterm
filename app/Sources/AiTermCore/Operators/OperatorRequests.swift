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
    /// The whole request, as a sentence: the notification's body and a tooltip's text. A question says who asks:
    /// `The Operator asks: …`, `PAY-236’s worker asks: …` for a worker's question it relayed, or `AiTerm asks: …` for AiTerm's
    /// own (a merge on the host, a command the Oracle stopped).
    public var text: String
    /// A question's key: each open question is its own request. A permission carries its recorded `prompt-` question's.
    public var key: String?
    /// The worker tab whose prompt it is, by key (`WorkerTab.firstKey` for the first worker); nil for a request
    /// no one tab makes.
    public var tab: String?
    /// Whether it holds its task (`OperatorQuestion.holdsTask`): only a request that holds is its task's line. False for
    /// a question the Operator asked about a task that can go on without the answer.
    public var holds: Bool

    /// What a notification is posted and withdrawn by: `request-<runId>-<taskId|run>-<kind>`, and for a
    /// question `request-<runId>-question-<questionKey>`.
    public var id: String {
        if kind == .question, let key { return "request-\(runId.uuidString)-question-\(key)" }
        return "request-\(runId.uuidString)-\(taskId?.uuidString ?? "run")-\(kind.rawValue)"
    }

    public init(kind: Kind, runId: UUID, taskId: UUID?, text: String, key: String? = nil, tab: String? = nil, holds: Bool = true) {
        self.kind = kind; self.runId = runId; self.taskId = taskId; self.text = text; self.key = key; self.tab = tab; self.holds = holds
    }
}

public enum OperatorRequests {
    /// Every open request of the run: a worker's permission or unknown prompt, an open `ask_you` question,
    /// a blocked task and a task whose `problem` is set. A waiting worker's prompt is said by what its question
    /// recorded. A task you took over contributes none, and an ended run has none. A finished task's leftovers ask nothing,
    /// except a question that doesn't hold it: that one asks until the Operator resolves or withdraws it.
    public static func open(run: OperatorRun, state: AppState) -> [BroadcastRequest] {
        guard !run.hasEnded else { return [] }
        let tasks = state.tasks(inRun: run.id)
        // Taken over or finished: what is left open on it asks nothing, but for a finished task's question that never held it.
        let takenOver = Set(tasks.filter { $0.operated?.takenOver == true }.map(\.id))
        let silent = takenOver.union(tasks.filter { $0.operated.map(\.isFinished) == true }.map(\.id))
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
                                                 text: sentence("\(recorded.text) in \(task.title)"), key: recorded.id,
                                                 tab: recorded.tab ?? WorkerTab.firstKey))
            }
            // What waits for the Operator's finish_task asks you nothing (`TaskPublication.operatorHolds`), and a publication's
            // problem is read as it stands now: a task back in review is past it (`OperatedTask.currentPublicationProblem`).
            if operated.problem != nil || operated.publicationFailure != nil {
                // The banner's sentence is the reason a blocked task keeps; one that kept its state has only the issue.
                let said = operated.publicationFailure ?? operated.blockedReason ?? "The problem is shown in the banner"
                requests.append(BroadcastRequest(kind: .problem, runId: run.id, taskId: task.id, text: sentence("\(task.title): \(said)")))
            } else if operated.state == .blocked {
                let reason = operated.blockedReason ?? "it needs you"
                requests.append(BroadcastRequest(kind: .blocked, runId: run.id, taskId: task.id, text: sentence("\(task.title) is blocked: \(reason)")))
            }
        }
        for question in run.questions where question.resolution == nil && !question.id.hasPrefix("prompt-") {
            if let task = question.task, takenOver.contains(task) || (silent.contains(task) && question.holdsTask) { continue }
            let asker = switch question.asker {
            case .aiterm: "AiTerm"
            case .theOperator: "The Operator"
            case .worker: (tasks.first { $0.id == question.task }?.operated?.key).map { "\($0)’s worker" } ?? "Its worker"
            }
            requests.append(BroadcastRequest(kind: .question, runId: run.id, taskId: question.task, text: "\(asker) asks: \(question.text)",
                                             key: question.id, holds: question.holdsTask))
        }
        return requests
    }

    /// `text` as one sentence: ended with a full stop, never two.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

}
