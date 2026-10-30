import Foundation
import AiTermCore

/// The Operator's activity log: each call a known run's Operator makes, with how it went, is a line of the run
/// folder's `activity.jsonl` (`ActivityLog`), whatever the answer was and without changing it.
extension OperatorToolHandler {
    /// Writes `request`'s line off the main actor, after the lines of the calls that ended before it. A write that
    /// fails is logged, never said to the Operator. A call for a run AiTerm no longer has leaves no line: it has no folder,
    /// and one forgotten while the lines before it were written is not made again (`OperatorController.forget`).
    func record(_ request: OperatorRequest, answer: ToolAnswer, outcome: ActivityEntry.Outcome) {
        guard let id = UUID(uuidString: request.runId), state.run(id: id) != nil else { return }
        let call = ToolCall(tool: request.tool, arguments: request.arguments)
        let task = call.optionalString("task").flatMap { state.task(inRun: id, named: $0) }
        let result: String
        switch answer {
        case .result(let value): result = Self.json(value)
        case .error(let message): result = message
        }
        // A repeated resolution describes the recorded outcome, even if this call asked for a different one.
        var lineArguments = request.arguments
        if request.tool == "resolve_question", case .result(let value) = answer, case .object(var fields) = lineArguments {
            fields["summary"] = value["resolution"]
            fields["withdrawn"] = value["withdrawn"]
            lineArguments = .object(fields)
        }
        let reason = ActivityLine.reason(tool: request.tool, arguments: lineArguments, outcome: outcome, result: result)
        let entry = ActivityEntry(at: ports.now(), tool: request.tool, task: task?.id, taskLabel: task.flatMap { $0.jira?.key ?? $0.operated?.key },
                                  arguments: request.arguments, outcome: outcome, result: result,
                                  line: ActivityLine.line(tool: request.tool, arguments: lineArguments, task: task, outcome: outcome),
                                  reason: reason.nonEmpty)
        append(entry, to: id)
    }

    /// Writes `entry` as a line of run `id`'s activity log, after the lines before it: a tool call's (`record`), or the
    /// gate's for a shell command (`OperatorToolHandler+Gate.swift`).
    func append(_ entry: ActivityEntry, to id: UUID) {
        let folder = OperatorCommand.runFolder(id, home: ports.home), before = lastRecording
        lastRecording = Task {
            await before?.value
            guard state.run(id: id) != nil else { return }
            await Log.daemon.attempt("Recording the Operator’s \(entry.tool) call in broadcast \(id.uuidString)’s activity log") {
                try await BackgroundWork.run {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try ActivityLog.append(entry, runFolder: folder)
                }
            }
            onActivity(id)
        }
    }
}
