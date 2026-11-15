import Foundation
import AiTermCore

/// The signal contract, kept beside the served broadcast handler until activation. Every external
/// effect receives a live authority check; an uncertain delivery is never blindly replayed.
@MainActor final class SignalOperatorToolHandler {
    struct Ports {
        var oracleEnabled: @MainActor () -> Bool
        var workerQuestion: @MainActor (UUID, String) -> Bool
        var read: @MainActor (TaskItem) async throws -> JSONValue
        var message: @MainActor (TaskItem, String, String, @escaping @MainActor () -> Bool) async throws -> Void
        var openTab: @MainActor (TaskItem, String, AgentChoice, String, String, @escaping @MainActor () -> Bool) async throws -> JSONValue
        var jiraSearch: @MainActor (String) async throws -> JSONValue
        var oracle: @MainActor (TaskItem?, String, String) async throws -> String
        var actionsAllowed: @MainActor () -> Bool = { true }
        var sessions: @MainActor () -> [SessionInfo] = { [] }
        var instructions: @MainActor () -> String? = { nil }
        var usage: @MainActor () -> UsageSnapshot = { .empty }
    }
    let workspace: WorkspaceStore
    let stages: StageRunner
    let questions: QuestionRounds
    let journal: SignalJournal
    let now: () -> Date
    let ports: Ports
    private var running: Set<String> = []
    var changed: () -> Void = {}
    var recorded: (OperatorRequest, ToolAnswer) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, stages: StageRunner, questions: QuestionRounds, journal: SignalJournal,
         now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.stages = stages; self.questions = questions
        self.journal = journal; self.now = now; self.ports = ports
    }
    func respond(_ request: OperatorRequest) async -> ToolAnswer {
        let answer: ToolAnswer
        do { answer = .result(try await perform(request)) }
        catch let refusal as ToolRefusal { answer = .error(refusal.message) }
        catch { answer = .error(OperationIssue.reason(of: error)) }
        recorded(request, answer)
        return answer
    }
    private func perform(_ request: OperatorRequest) async throws -> JSONValue {
        guard let tool = SignalOperatorTool(rawValue: request.tool) else { throw ToolRefusal("Unknown Operator tool: \(request.tool).") }
        try requireSession(request, mutating: tool.mutating)
        let call = ToolCall(tool: request.tool, arguments: request.arguments)
        let key = tool.requiresKey ? try call.string("key") : nil
        let ledgerKey = key.map { "tool:\(tool.rawValue):" + $0 }
        let arguments = try Self.json(request.arguments)
        if let ledgerKey, let old = workspace.state.operatorSession?.ledger.first(where: { $0.key == ledgerKey && now().timeIntervalSince($0.at) <= 7 * 86400 }) {
            guard old.arguments == arguments else { throw ToolRefusal("This key already names a different call. Use the original arguments to retry.") }
            if running.contains(ledgerKey) { return ["status": "pending"] }
            var replay: JSONValue?
            workspace.mutate { replay = $0.operatorSession?.cached(key: ledgerKey, at: now()) }
            guard workspace.flush() else { throw ToolRefusal("The retry result couldn’t be saved.") }
            return replay ?? old.result
        }
        if let ledgerKey, running.contains(ledgerKey) { return ["status": "pending"] }
        let task: TaskItem?
        if let name = call.optionalString("task") {
            guard let id = UUID(uuidString: name), let value = workspace.state.signalItem(id: id), let claim = SignalClaim(value) else {
                throw ToolRefusal("This task is no longer the Operator’s.")
            }
            if tool != .runStatus {
                guard request.arguments["stage"]?.intValue == claim.stage, request.arguments["ownership"]?.intValue == claim.ownership else {
                    throw ToolRefusal("The task's stage or ownership changed. Read run_status again.")
                }
            }
            if tool.mutating, !claim.canAct(in: workspace.state) { throw ToolRefusal("Its signal is switched off or this task cannot be acted on.") }
            task = value
        } else {
            guard !tool.taskRequired else { throw ToolRefusal("\(tool.rawValue) needs `task`.") }
            task = nil
        }
        let claim = task.flatMap(SignalClaim.init)
        let allowed: @MainActor () -> Bool = { [weak self] in
            guard let self, (try? self.requireSession(request, mutating: tool.mutating)) != nil, !Task.isCancelled else { return false }
            if tool == .messageTask, let task, self.ports.workerQuestion(task.id, call.optionalString("tab") ?? "main") { return false }
            return claim.map { tool.mutating ? $0.canAct(in: self.workspace.state) : $0.holds(in: self.workspace.state) } ?? true
        }
        if let ledgerKey { running.insert(ledgerKey) }
        defer { if let ledgerKey { running.remove(ledgerKey) } }
        if let task, let act = tool.act {
            workspace.mutate { $0.updateSignalTask(task.id) { $0.currentAct = act } }
        }
        defer {
            if let claim, claim.holds(in: workspace.state) {
                workspace.mutate { $0.updateSignalTask(claim.task) { $0.currentAct = nil } }
            }
        }
        // These effects may have happened when a connection drops. Record uncertainty first;
        // the same key then asks for inspection instead of typing/opening a duplicate.
        if let ledgerKey, [.messageTask, .openTab, .askOracle, .resumeTask, .finishStage].contains(tool) {
            try remember(["status": "uncertain", "next": "Inspect run_status and read_task before another action."], key: ledgerKey, arguments: arguments)
        }
        let result = try await execute(tool, call: call, task: task, key: key, allowed: allowed)
        // Stage owners intentionally advance authority. They check their own effects after every await.
        try requireSession(request, mutating: tool.mutating)
        if [.resumeTask, .finishStage].contains(tool), let task, workspace.state.signalItem(id: task.id).flatMap(SignalClaim.init) == nil {
            throw ToolRefusal("The task is no longer the Operator’s.")
        }
        if tool != .resumeTask && tool != .finishStage, let claim, !claim.holds(in: workspace.state) {
            throw ToolRefusal("The task changed while this call ran.")
        }
        if let ledgerKey, result["status"] != "pending" { try remember(result, key: ledgerKey, arguments: arguments) }
        if tool.mutating { changed() }
        return result
    }
    func requireSession(_ request: OperatorRequest, mutating: Bool) throws {
        guard let session = workspace.state.operatorSession, session.id.uuidString == request.runId,
              session.generation == request.generation, !session.startingFresh else { throw ToolRefusal("This Operator session is no longer current.") }
        if mutating {
            guard ports.actionsAllowed(), workspace.canChangeWorkspace, !session.paused, !Task.isCancelled else { throw ToolRefusal("The Operator is paused or the workspace is unavailable.") }
        }
    }
    private func remember(_ result: JSONValue, key: String, arguments: String) throws {
        workspace.mutate { $0.operatorSession?.remember(key: key, result: result, at: now(), arguments: arguments) }
        guard workspace.flush() else { throw ToolRefusal("The tool result couldn’t be saved.") }
    }
    static func json(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
