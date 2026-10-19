import Foundation

/// Something that needs you in a broadcast (spec §4.1): one thing, said once, as the notification, the
/// row and the banner say it. A request lasts exactly as long as what asks stands: answered, unblocked or
/// ended, it is gone.
public struct Request: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case permission, question, blocked, problem }
    public var kind: Kind
    public var runId: UUID
    /// The task it is about; nil for the Operator's own question.
    public var taskId: UUID?
    /// The whole request, as a sentence: the notification's body and a tooltip's text.
    public var text: String
    /// A question's key: each open question is its own request.
    public var key: String?

    /// What a notification is posted and withdrawn by: `request-<runId>-<taskId|run>-<kind>`, and for a
    /// question `request-<runId>-question-<questionKey>`.
    public var id: String {
        if kind == .question, let key { return "request-\(runId.uuidString)-question-\(key)" }
        return "request-\(runId.uuidString)-\(taskId?.uuidString ?? "run")-\(kind.rawValue)"
    }

    public init(kind: Kind, runId: UUID, taskId: UUID?, text: String, key: String? = nil) {
        self.kind = kind; self.runId = runId; self.taskId = taskId; self.text = text; self.key = key
    }
}

public enum OperatorRequests {
    /// Every open request of the run: a worker's permission or unknown prompt, an open `ask_you` question,
    /// a blocked task and a task whose `problem` is set. `prompts` is what each waiting worker's prompt asks,
    /// by task, as a verb phrase ("run npm install"), where it is known; a prompt without one is said by
    /// what its question recorded. A task you took over contributes none, and an ended run has none.
    public static func open(run: OperatorRun, state: AppState, prompts: [UUID: String]) -> [Request] {
        guard run.state != .stopped, run.intent != .stopped else { return [] }
        let tasks = state.tasks(inRun: run.id)
        let takenOver = Set(tasks.filter { $0.operated?.takenOver == true }.map(\.id))
        var requests: [Request] = []

        for task in tasks where !takenOver.contains(task.id) {
            guard let operated = task.operated else { continue }
            let agent = task.agent.harness.displayName
            let recorded = run.questions.first { $0.task == task.id && $0.resolution == nil && $0.id.hasPrefix("prompt-") }
            if recorded != nil || prompts[task.id] != nil {
                let said = prompts[task.id].map { "\(agent) asks to \($0)" } ?? recorded?.text ?? "\(agent) waits for input"
                requests.append(Request(kind: .permission, runId: run.id, taskId: task.id, text: sentence("\(said) in \(task.title)")))
            }
            if operated.problem != nil {
                // The banner's sentence is the reason a blocked task keeps; one that kept its state has only the issue.
                let said = operated.blockedReason.map(lowercasingFirst) ?? "problem is shown in the banner"
                requests.append(Request(kind: .problem, runId: run.id, taskId: task.id, text: sentence("\(task.title)’s \(said)")))
            } else if operated.state == .blocked {
                let reason = operated.blockedReason ?? "it needs you"
                requests.append(Request(kind: .blocked, runId: run.id, taskId: task.id, text: sentence("\(task.title) is blocked: \(reason)")))
            }
        }
        for question in run.questions where question.resolution == nil && !question.id.hasPrefix("prompt-") {
            if let task = question.task, takenOver.contains(task) { continue }
            requests.append(Request(kind: .question, runId: run.id, taskId: question.task, text: "The Operator asks: \(question.text)", key: question.id))
        }
        return requests
    }

    /// `text` as one sentence: ended with a full stop, never two.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }

    static func lowercasingFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
