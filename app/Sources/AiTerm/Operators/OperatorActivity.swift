import Foundation
import AiTermCore
import AiTermUI

/// Runtime identity, not saved chat state. Equal words from different events decode again.
struct OperatorActivity: Equatable {
    var id = UUID()
    var line: OperatorLine?
    var completed: OperatorLine?
    /// Whether the chat waits for your pause (`OperatorSessionKeeper.pauseWords`), whichever line is the latest.
    var chatWaitsForPause = false
}

/// A task's act the Operator is running, as its row says it: "Operator " and the words.
struct OperatorAct: Equatable {
    var task: UUID
    var words: String
}

/// What the Operator is doing now, runtime only: its row's activity (`during`), each task's acts (`acting`) and the
/// tasks that have just woken it (`woke`).
@MainActor final class OperatorActivityTracker {
    private(set) var event = OperatorActivity()
    private var running: [(id: UUID, line: OperatorLine)] = []
    /// The acts running on tasks, oldest first.
    private var acts: [(id: UUID, act: OperatorAct)] = []
    /// The tasks whose wake marches up their stretch of the status line now, each with the wake that started it.
    private var pulses: [UUID: UUID] = [:]
    /// How long a wake's march lasts: `Motion.pulse`; a test shortens it.
    var pulseLength: Duration = .seconds(Motion.pulse)
    /// Whether any activity or act runs.
    var isRunning: Bool { !running.isEmpty || !acts.isEmpty }
    var changed: () -> Void = {}

    /// A task's current act: the latest it began that is still running.
    func act(for task: UUID) -> String? { acts.last { $0.act.task == task }?.act.words }
    /// Each task's current act.
    var actsByTask: [UUID: String] {
        acts.reduce(into: [:]) { result, entry in result[entry.act.task] = entry.act.words }
    }
    /// The most recent act still running, for the Operator's row.
    var latestAct: OperatorAct? { acts.last?.act }
    /// The tasks that woke the Operator within the last `pulseLength`: their stretch of the status line marches up.
    var waking: Set<UUID> { Set(pulses.keys) }
    /// `task` woke the Operator (its worker ended its turn, or its stage is blocked): its stretch marches up, once,
    /// for `pulseLength`, then ends by itself. A second wake within it starts the march again.
    func woke(task: UUID) {
        let id = UUID()
        pulses[task] = id
        changed()
        let length = pulseLength
        Task { [weak self] in
            try? await Task.sleep(for: length)
            guard let self, self.pulses[task] == id else { return }
            self.pulses[task] = nil
            self.changed()
        }
    }
    /// `body` run as `task`'s act, shown on its row while it runs; a nested act shows until it ends.
    func acting<Result>(task: UUID, act words: String, _ body: @MainActor () async throws -> Result) async rethrows -> Result {
        let id = begin(task: task, act: words)
        defer { end(id) }
        return try await body()
    }
    /// Begins `task`'s act; `end` with the id it returns ends it.
    func begin(task: UUID, act words: String) -> UUID {
        let id = UUID()
        acts.append((id, OperatorAct(task: task, words: words)))
        changed()
        return id
    }
    func end(_ id: UUID) {
        acts.removeAll { $0.id == id }
        changed()
    }

    func pulse(completed: OperatorLine? = nil) {
        event = OperatorActivity(line: running.last?.line, completed: running.isEmpty ? completed : nil,
                                 chatWaitsForPause: running.contains { $0.line.text == OperatorSessionKeeper.pauseWords })
        changed()
    }
    func during<Result>(_ words: String, _ body: @MainActor () async throws -> Result) async rethrows -> Result {
        let id = UUID()
        let line = OperatorLine(words, look: .acting)
        running.append((id, line))
        pulse()
        defer { running.removeAll { $0.id == id }; pulse(completed: line) }
        return try await body()
    }
    nonisolated static func name(_ task: TaskItem) -> String { task.jira?.key ?? task.mr.map { "request \($0.iid)" } ?? task.title }
    nonisolated static func words(for request: OperatorRequest, task: TaskItem?) -> String {
        let name = task.map(name) ?? "the workload"
        switch request.tool {
        case "run_status": return "reading status"
        case "read_task": return "reading \(name)’s worker"
        case "message_task", "answer_worker": return "answering \(name)’s worker"
        case "open_tab", "resume_task": return "starting \(name)’s worker"
        case "choose_agent": return "choosing \(name)’s agent and project"
        case "finish_stage": return "checking \(name)’s result"
        case "ask_oracle": return "consulting the Oracle"
        case "ask_you": return "asking you about \(name)"
        case "resolve_question": return request.arguments["withdraw"]?.stringValue == nil ? "recording your answer" : "withdrawing its question"
        case "jira_search": return "searching Jira"
        case "note": return "updating \(name)’s journal"
        case "gate_command": return "checking a shell command"
        default: return "checking an Operator request"
        }
    }
}
