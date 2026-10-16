import Foundation
import AiTermCore

/// A tool's answer: the result the operator reads, or an error it reads as the tool's failure.
enum ToolAnswer: Equatable, Sendable {
    case result(JSONValue), error(String)
    var value: JSONValue? { if case .result(let value) = self { value } else { nil } }
    var message: String? { if case .error(let message) = self { message } else { nil } }
}

/// Why a tool did not act, said to the operator as the tool's error.
struct ToolRefusal: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One call's arguments, read with the error the operator needs when one is missing.
struct ToolCall {
    let tool: String, arguments: JSONValue

    func string(_ key: String) throws(ToolRefusal) -> String {
        guard let value = optionalString(key) else { throw ToolRefusal("\(tool) needs `\(key)`.") }
        return value
    }

    func optionalString(_ key: String) -> String? {
        arguments[key]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The Jira search behind `jira_search`: the app's client, or a test's.
protocol OperatorJira: Sendable {
    func search(jql: String, in projects: [JiraProjectRef]) async throws -> [JiraTicket]
}

extension JiraClient: OperatorJira {}

/// Answers the operator's tools (spec §6), each forwarded by the daemon as an `operator.request` and
/// answered with an `operator.reply`. The app is the only writer of runs and tasks, so every tool's
/// effect is a workspace change made here; the operator's view of it is `run_status`, numbered by what
/// changed. Every mutating tool is safe to repeat: by its key, its revision, its outcome and SHA, or
/// the task's current state (spec §11) — the repeat returns what was recorded.
@MainActor
final class OperatorToolHandler {
    let workspace: WorkspaceStore
    let live: LiveSessions
    let daemon: @MainActor () -> (any DaemonCommands)?
    let ports: OperatorPorts
    let notifier: OperatorNotifier
    let waker: OperatorWaker
    /// Each run's last `run_status`, and the revision it was numbered.
    private var numbered: [UUID: (content: RunStatus, revision: Int)] = [:]
    /// The second opinions running now, by challenge id: one in a run's records but not here was lost
    /// with AiTerm's restart.
    var runningChallenges: [String: Task<Void, Never>] = [:]
    /// The challenges whose acting call is performing now: a second call for one is refused, not performed too.
    var actingChallenges: Set<String> = []
    /// The latest challenge's run, for a test to await. Set by `OperatorToolHandler+Challenge.swift`.
    var lastChallenge: Task<Void, Never>?
    /// The latest reply sent, for a test to await.
    private(set) var lastReply: Task<Void, Never>?
    /// Told when a call starts and stops acting on a task: the controller's `acting`.
    var onActing: @MainActor (UUID, Bool) -> Void = { _, _ in }
    /// Said after an operator's own change to its run: what may start now starts.
    var onChange: @MainActor (UUID) -> Void = { _ in }

    /// The tools that act on one task while they run: its row's operator mark breathes meanwhile.
    static let actsOnTask: Set<String> = ["message_task", "mark_task", "finish_task"]

    /// The tools that change the run, its tasks or its records: the operator has seen what they changed.
    /// `finish_task` is one from M3 (part G): a publication changes the run, and may complete it.
    static let mutating: Set<String> = ["create_task", "update_task", "submit_plan", "message_task", "mark_task", "resume_task",
                                        "retry_task", "finish_task", "ask_you", "resolve_question", "propose_lesson", "log_decision"]

    init(workspace: WorkspaceStore, live: LiveSessions, daemon: @escaping @MainActor () -> (any DaemonCommands)?, ports: OperatorPorts,
         notifier: OperatorNotifier, waker: OperatorWaker) {
        self.workspace = workspace
        self.live = live
        self.daemon = daemon
        self.ports = ports
        self.notifier = notifier
        self.waker = waker
    }

    var state: AppState { workspace.state }

    /// Answers `request` through the helper. A reply that cannot be sent is the daemon's to time out:
    /// the operator reads "AiTerm isn't answering" and calls again, which the tool's key makes safe.
    func handle(_ request: OperatorRequest) {
        lastReply = Task {
            let answer = await self.answer(request)
            guard let daemon = daemon() else { return }
            await Log.daemon.attempt("Replying to the operator’s \(request.tool) request \(request.requestId)") {
                switch answer {
                case .result(let value): try await daemon.replyToOperator(requestId: request.requestId, result: value, error: nil)
                case .error(let message): try await daemon.replyToOperator(requestId: request.requestId, result: nil, error: message)
                }
            }
        }
    }

    func answer(_ request: OperatorRequest) async -> ToolAnswer {
        guard let id = UUID(uuidString: request.runId), let run = state.run(id: id) else { return .error("This operation is no longer in AiTerm.") }
        guard run.state != .stopped, run.intent != .stopped else { return .error("This operation has ended; its tools no longer act.") }
        let call = ToolCall(tool: request.tool, arguments: request.arguments), before = currentStatus(of: run)
        let actingOn = Self.actsOnTask.contains(call.tool) ? call.optionalString("task").flatMap { state.task(inRun: id, named: $0)?.id } : nil
        if let actingOn { onActing(actingOn, true) }
        defer { if let actingOn { onActing(actingOn, false) } }
        do {
            if let instead = try await challengeGate(call, in: run) { return .result(instead) }
            // The gate marks a challenge it lets act; whatever way this call ends, the mark goes with it.
            let acting = call.optionalString("challengeId").flatMap { actingChallenges.contains($0) ? $0 : nil }
            defer { if let acting { actingChallenges.remove(acting) } }
            let value = try await perform(call, in: run)
            recordActed(call, in: id, answer: value)
            if Self.mutating.contains(call.tool), let before, let after = state.run(id: id).flatMap(currentStatus(of:)) {
                waker.ownChange(from: before, to: after, of: id)
                onChange(id)
            }
            return .result(value)
        } catch let refusal as ToolRefusal {
            return .error(refusal.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// One tool, by its name.
    func perform(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        switch call.tool {
        case "run_status": return try runStatus(run)
        case "jira_search": return try await jiraSearch(call, in: run)
        case "ask_you": return try askYou(call, in: run)
        case "resolve_question": return try resolveQuestion(call, in: run)
        case "propose_lesson": return try proposeLesson(call, in: run)
        case "log_decision": return try logDecision(call, in: run)
        case "create_task": return try createTask(call, in: run)
        case "update_task": return try updateTask(call, in: run)
        case "submit_plan": return try submitPlan(call, in: run)
        case "read_task": return try await readTask(call, in: run)
        case "message_task": return try await messageTask(call, in: run)
        case "mark_task": return try await markTask(call, in: run)
        case "resume_task": return try resumeTask(call, in: run)
        case "retry_task": return try retryTask(call, in: run)
        case "finish_task":
            throw ToolRefusal("finish_task is available in M3. In M1 a task ends at its commit: once you accept it, it is done.")
        default: throw ToolRefusal("AiTerm has no tool called \(call.tool).")
        }
    }

    func currentStatus(of run: OperatorRun) -> RunStatus? {
        OperatorController.status(of: run.id, state: state, sessions: live.sessions, revision: 0)
    }

    /// The task an operator names in `key`, in this run.
    func task(_ call: ToolCall, _ key: String = "task", in run: OperatorRun) throws(ToolRefusal) -> TaskItem {
        let ref = try call.string(key)
        guard let task = state.task(inRun: run.id, named: ref) else { throw ToolRefusal("No task \(ref) in this operation.") }
        return task
    }

    // -- reading -------------------------------------------------------------------------------
    /// The snapshot, numbered by the per-run counter here: the same content keeps its revision,
    /// anything changed gets the next one.
    private func runStatus(_ run: OperatorRun) throws -> JSONValue {
        guard let content = currentStatus(of: run) else { throw ToolRefusal("This operation is no longer in AiTerm.") }
        let previous = numbered[run.id]
        let revision = previous?.content == content ? previous?.revision ?? 1 : (previous?.revision ?? 0) + 1
        numbered[run.id] = (content, revision)
        var status = content
        status.revision = revision
        waker.acknowledged(status, of: run.id)
        return try JSONValue(encoding: status)
    }

    private func jiraSearch(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let jql = try call.string("jql")
        guard let jira = ports.jira() else { throw ToolRefusal("Jira isn’t connected in AiTerm’s Settings › Integrations.") }
        let linked = run.projectIds.compactMap(state.project(id:)).flatMap(\.jiraProjects).linkedOnce
        guard !linked.isEmpty else {
            throw ToolRefusal("None of this operation’s projects is linked to a Jira project, so there is nothing jira_search may search.")
        }
        let tickets = try await jira.search(jql: jql, in: linked)
        return .array(tickets.map { ticket in
            ["key": .string(ticket.key), "summary": .string(ticket.summary), "status": ticket.status.map(JSONValue.string) ?? .null,
             "type": ticket.issueType.map(JSONValue.string) ?? .null, "url": .string(ticket.url),
             "description": ticket.description.map { .string(String($0.prefix(4000))) } ?? .null]
        })
    }

    // -- the records ----------------------------------------------------------------------------
    private func askYou(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), text = try call.string("question")
        let taskId = try call.optionalString("task").map { _ in try task(call, in: run).id }
        if let open = run.questions.first(where: { $0.id == key }) { return Self.questionAnswer(open) }
        let question = OperatorQuestion(id: key, text: text, task: taskId, askedAt: ports.now(), resolution: nil)
        workspace.mutate { state in
            state.updateRun(id: run.id) { $0.questions.append(question) }
            if let taskId { state.updateOperated(taskId) { $0.flags.insert(.waitingOnYou) } }
        }
        let updated = state.run(id: run.id) ?? run
        notifier.questionAsked(question, in: updated, otherWorkCanProceed: state.otherWorkCanProceed(in: updated))
        return Self.questionAnswer(question)
    }

    private func resolveQuestion(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), summary = try call.string("summary")
        guard var question = run.questions.first(where: { $0.id == key }) else { throw ToolRefusal("No question \(key) in this operation.") }
        guard question.resolution == nil else { return Self.questionAnswer(question) }
        question.resolution = summary
        workspace.mutate { state in
            state.updateRun(id: run.id) { run in
                if let i = run.questions.firstIndex(where: { $0.id == key }) { run.questions[i].resolution = summary }
            }
            // The row stops waiting on you once none of its questions is open.
            if let taskId = question.task, state.run(id: run.id)?.questions.contains(where: { $0.task == taskId && $0.resolution == nil }) == false {
                state.updateOperated(taskId) { $0.flags.remove(.waitingOnYou) }
            }
        }
        return Self.questionAnswer(question)
    }

    private func proposeLesson(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), lesson = try call.string("lesson"), because = try call.string("because")
        if let proposed = run.lessons.first(where: { $0.key == key }) {
            return ["lesson": .string(key), "proposed": true, "decided": proposed.decided.map { .string($0.rawValue) } ?? .null]
        }
        workspace.mutate { $0.updateRun(id: run.id) { $0.lessons.append(ProposedLesson(key: key, lesson: lesson, because: because, decided: nil)) } }
        return ["lesson": .string(key), "proposed": true, "decided": .null]
    }

    private func logDecision(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), text = try call.string("text")
        let taskId = try call.optionalString("task").map { _ in try task(call, in: run).id }
        if !run.decisions.contains(where: { $0.key == key }) {
            let decision = OperatorDecision(key: key, text: text, task: taskId, at: ports.now(), challenge: nil)
            workspace.mutate { $0.updateRun(id: run.id) { $0.decisions.append(decision) } }
        }
        return ["decision": .string(key), "logged": true]
    }

    private static func questionAnswer(_ question: OperatorQuestion) -> JSONValue {
        ["question": .string(question.id), "open": .bool(question.resolution == nil),
         "resolution": question.resolution.map(JSONValue.string) ?? .null]
    }
}
