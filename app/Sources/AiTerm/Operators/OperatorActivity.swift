import Foundation
import AiTermCore

/// Runtime identity, not saved chat state. Equal words from different events decode again.
struct OperatorActivity: Equatable {
    var id = UUID()
    var line: OperatorLine?
    var completed: OperatorLine?
}

@MainActor final class OperatorActivityTracker {
    private(set) var event = OperatorActivity()
    private var running: [(id: UUID, line: OperatorLine)] = []
    var isRunning: Bool { !running.isEmpty }
    var changed: () -> Void = {}

    func pulse(completed: OperatorLine? = nil) {
        event = OperatorActivity(line: running.last?.line, completed: running.isEmpty ? completed : nil)
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
        case "resolve_question": return "recording your answer"
        case "report_snag": return "recording a snag"
        case "jira_search": return "searching Jira"
        case "note": return "updating \(name)’s journal"
        case "gate_command": return "checking a shell command"
        default: return "checking an Operator request"
        }
    }
}
