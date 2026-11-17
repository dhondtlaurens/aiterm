import Foundation
import AiTermCore

/// The served Signal contract. Every external
/// effect receives a live authority check; an uncertain delivery is never blindly replayed.
@MainActor final class SignalOperatorToolHandler {
    struct Ports {
        var oracleEnabled: @MainActor () -> Bool
        var workerQuestion: @MainActor (UUID, String) -> Bool
        var read: @MainActor (TaskItem) async throws -> JSONValue
        var message: @MainActor (TaskItem, String, String, @escaping @MainActor () -> Bool) async throws -> Void
        var openTab: @MainActor (TaskItem, String, AgentChoice, String, String, @escaping @MainActor () -> Bool) async throws -> JSONValue
        var jiraSearch: @MainActor (String) async throws -> JSONValue
        /// An Oracle check, bound to the task's claim when there is a task.
        var consult: @MainActor (TaskItem?, OracleLaunch.Question) async -> OracleConsult.Outcome
        var actionsAllowed: @MainActor () -> Bool = { true }
        var sessions: @MainActor () -> [SessionInfo] = { [] }
        var instructions: @MainActor () -> String? = { nil }
        var usage: @MainActor () -> UsageSnapshot = { .empty }
        var installedAgents: @MainActor () -> Set<AgentKind> = { [] }
        var issues: @MainActor () -> [OperatorIssues.Issue] = { [] }
    }
    let workspace: WorkspaceStore
    let stages: StageRunner
    let questions: QuestionRounds
    let choices: AgentChoiceRounds
    let journal: SignalJournal
    let now: () -> Date
    let ports: Ports
    /// The tasks an Operator effect runs on: `message_task` and `open_tab` hold theirs while they type or open.
    let effects: OperatorInFlight
    private var running: Set<String> = []
    var changed: () -> Void = {}
    var recorded: (OperatorRequest, ToolAnswer) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, stages: StageRunner, questions: QuestionRounds, choices: AgentChoiceRounds, journal: SignalJournal,
         now: @escaping () -> Date, ports: Ports, effects: OperatorInFlight = OperatorInFlight()) {
        self.workspace = workspace; self.stages = stages; self.questions = questions; self.choices = choices
        self.journal = journal; self.now = now; self.ports = ports; self.effects = effects
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
        guard let tool = OperatorTool(rawValue: request.tool) else { throw ToolRefusal("Unknown Operator tool: \(request.tool).") }
        try requireSession(request, mutating: tool.mutating)
        let call = ToolCall(tool: request.tool, arguments: request.arguments)
        let key = tool.requiresKey ? try call.string("key") : nil
        let ledgerKey = key.map { "tool:\(tool.rawValue):" + $0 }
        let arguments = try request.arguments.canonicalJSON()
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
            if tool.mutating, !claim.allows(in: workspace) { throw ToolRefusal("Its signal is switched off or this task cannot be acted on.") }
            task = value
        } else {
            guard !tool.taskRequired else { throw ToolRefusal("\(tool.rawValue) needs `task`.") }
            task = nil
        }
        let claim = task.flatMap(SignalClaim.init)
        let allowed: @MainActor () -> Bool = { [weak self] in
            guard let self, (try? self.requireSession(request, mutating: tool.mutating)) != nil, !Task.isCancelled else { return false }
            if tool == .messageTask, let task, self.ports.workerQuestion(task.id, call.optionalString("tab") ?? "main") { return false }
            return claim.map { tool.mutating ? $0.allows(in: self.workspace) : $0.holds(in: self.workspace.state) } ?? true
        }
        if let ledgerKey { running.insert(ledgerKey) }
        defer { if let ledgerKey { running.remove(ledgerKey) } }
        // These effects may have happened when a connection drops. Record uncertainty first;
        // the same key then asks for inspection instead of typing/opening a duplicate.
        if let ledgerKey, [.messageTask, .openTab, .askOracle, .resumeTask, .finishStage, .chooseAgent].contains(tool) {
            try remember(["status": "uncertain", "next": "Inspect run_status and read_task before another action."], key: ledgerKey, arguments: arguments)
        }
        let result = try await execute(tool, call: call, task: task, key: key, allowed: allowed)
        // Stage owners intentionally advance authority. They check their own effects after every await.
        try requireSession(request, mutating: tool.mutating)
        let advancesStage: Set<OperatorTool> = [.resumeTask, .finishStage, .chooseAgent]
        if advancesStage.contains(tool), let task, workspace.state.signalItem(id: task.id).flatMap(SignalClaim.init) == nil {
            throw ToolRefusal("The task is no longer the Operator’s.")
        }
        if !advancesStage.contains(tool), let claim, !claim.holds(in: workspace.state) {
            throw ToolRefusal("The task changed while this call ran.")
        }
        if let ledgerKey, result["status"] != "pending" { try remember(result, key: ledgerKey, arguments: arguments) }
        if tool.mutating { changed() }
        return result
    }
    func requireSession(_ request: OperatorRequest, mutating: Bool) throws {
        guard let session = workspace.state.operatorSession, session.id.uuidString == request.operatorId,
              session.generation == request.generation, !session.lifecycle.isChanging else { throw ToolRefusal("This Operator session is no longer current.") }
        if mutating {
            guard ports.actionsAllowed(), workspace.canChangeWorkspace, !session.paused, !Task.isCancelled else { throw ToolRefusal("The Operator is paused or the workspace is unavailable.") }
        }
    }
    private func remember(_ result: JSONValue, key: String, arguments: String) throws {
        workspace.mutate { $0.operatorSession?.remember(key: key, result: result, at: now(), arguments: arguments) }
        guard workspace.flush() else { throw ToolRefusal("The tool result couldn’t be saved.") }
    }
}
