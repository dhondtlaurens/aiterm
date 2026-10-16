import Foundation
import AiTermCore

/// A started task, as the operator works it (spec §6): what it reads of the worker — its own words
/// from its conversation file, its branch's diff, the prompt it has open — what it says to it through
/// the daemon's delivery, and the outcome it records. A task you took over refuses all but reading.
extension OperatorToolHandler {
    /// The most of a diff an answer carries.
    static let diffLimit = 60_000

    /// The worker's tab: the task's first agent tab.
    func workerTab(of task: TaskItem) -> SessionInfo? {
        live.sessions.filter { $0.taskUUID == task.id && $0.agent.agentKind != nil }.min { $0.tabIndex < $1.tabIndex }
    }

    func readTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), key = task.operated?.key ?? task.title
        switch try call.string("what") {
        case "lastMessage":
            guard let conversation = workerTab(of: task)?.conversationId ?? task.conversations.first(where: { $0.agent == task.agent })?.id else {
                return ["lastMessage": .null, "note": "Its worker hasn’t started a conversation yet."]
            }
            let home = ports.home, agent = task.agent
            let text = await BackgroundWork.run { WorkerTranscript.lastMessage(agent: agent, conversation: conversation, home: home) }
            // No reply found is unknown, not silence: the transcript reads only its tail, and a worker may have said it earlier.
            guard let text else {
                return ["lastMessage": .null, "note": "No reply found in the recent part of its conversation; that doesn’t mean it said nothing. Use read_task with what: diff or prompt."]
            }
            return ["lastMessage": .string(text)]
        case "diff":
            guard task.hasCheckout else { throw ToolRefusal("\(key) hasn’t started: it has no worktree yet.") }
            let git = ports.git, path = task.worktreePath, base = task.baseBranch
            let (commits, diff) = try await BackgroundWork.run {
                (try git.run(["log", "--oneline", "\(base)..HEAD"], in: path), try git.run(["diff", base], in: path))
            }
            return ["commits": .string(commits), "diff": .string(String(diff.prefix(Self.diffLimit))), "truncated": .bool(diff.count > Self.diffLimit)]
        case "prompt":
            guard let tab = workerTab(of: task), let daemon = daemon() else { return ["prompt": .null] }
            return ["prompt": try await daemon.prompt(sessionId: tab.sessionId).map { .string($0.rawValue) } ?? .null]
        case let other:
            throw ToolRefusal("read_task reads lastMessage, diff or prompt, not \(other).")
        }
    }

    /// Delivered by the daemon's rules (spec §7.1) with the task's ownership generation, so a send begun
    /// before a takeover cannot land after it. Never retried here: the result says what happened.
    func messageTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), text = try call.string("text")
        try acceptsWork(run)
        let operated = try notTakenOver(task)
        guard ![.planned, .queued, .stopped].contains(operated.state) else {
            throw ToolRefusal("\(operated.key) has no worker to message: it is \(operated.state.rawValue).")
        }
        guard let tab = workerTab(of: task) else { throw ToolRefusal("\(operated.key)’s worker has no open tab right now.") }
        guard let daemon = daemon() else { throw ToolRefusal("AiTerm’s helper isn’t connected; try again in a moment.") }
        let delivery = try await daemon.deliver(sessionId: tab.sessionId, text: text, ownership: operated.ownership, wake: false,
                                                worktree: task.worktreePath)
        return ["result": .string(delivery.result.rawValue), "reason": delivery.reason.map(JSONValue.string) ?? .null]
    }

    /// The operator's outcome (spec §6, §8). Accepted needs the commit its branch is on, unmoved, and the
    /// worker's check output; the same outcome for the same commit returns what was recorded.
    func markTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run)
        try acceptsWork(run)
        let operated = try notTakenOver(task), outcome = try call.string("outcome")
        let action: OperatedAction
        switch outcome {
        case "accepted":
            let given = try call.string("sha"), check = try call.string("checkOutput")
            let sha = try await commit(given, in: task)
            if operated.state == .accepted, operated.acceptance?.resultSHA == sha { return Self.taskAnswer(task, created: false) }
            let tip = try await commit("refs/heads/" + task.branch, in: task)
            guard sha == tip else {
                throw ToolRefusal("\(operated.key)’s branch is at \(tip.prefix(7)), not \(given): accept the commit its branch is on.")
            }
            let prerequisites = RunScheduler.baseCommit(for: task.id, in: state).map { [$0] } ?? []
            // Part C refuses it again on another commit once a code dependent has started (M1, spec §8).
            action = .accept(TaskAcceptance(resultSHA: sha, prerequisiteSHAs: prerequisites, checkOutput: check,
                                            note: call.optionalString("note"), at: ports.now()), branchHead: tip)
        case "noChange":
            if operated.state == .noChange { return Self.taskAnswer(task, created: false) }
            action = .noChange(note: call.optionalString("note"))
        case "blocked", "failed":
            let reason = try call.string("note")
            if operated.state.rawValue == outcome, operated.blockedReason == reason { return Self.taskAnswer(task, created: false) }
            action = outcome == "blocked" ? .block(reason: reason) : .fail(reason: reason)
        default:
            throw ToolRefusal("mark_task’s outcome is accepted, noChange, blocked or failed.")
        }
        try apply(action, to: task)
        let marked = state.task(id: task.id) ?? task
        if outcome == "blocked" { notifier.taskBlocked(marked, reason: call.optionalString("note") ?? "", in: run) }
        return Self.taskAnswer(marked, created: false)
    }

    /// `blocked` → `working`, once the reason is resolved; a working task answers as it is.
    func resumeTask(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let task = try self.task(call, in: run)
        try acceptsWork(run)
        let operated = try notTakenOver(task)
        if operated.state != .working { try apply(.resume, to: task) }
        return Self.taskAnswer(state.task(id: task.id) ?? task, created: false)
    }

    /// `failed` → `queued` while retries are left; AiTerm then starts it again (`WorkerStarter`).
    func retryTask(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let task = try self.task(call, in: run)
        try acceptsWork(run)
        let operated = try notTakenOver(task)
        guard operated.state == .failed else { return Self.taskAnswer(task, created: false) }
        let limit = run.persona.limits.retries
        guard operated.retriesUsed < limit else {
            throw ToolRefusal("\(operated.key) has used its \(limit) retr\(limit == 1 ? "y" : "ies"). Ask the person with ask_you how to go on.")
        }
        try apply(.retry, to: task)
        return Self.taskAnswer(state.task(id: task.id) ?? task, created: false)
    }

    // -- helpers ---------------------------------------------------------------------------------
    /// Work moves only in an active or complete operation (spec §9).
    func acceptsWork(_ run: OperatorRun) throws(ToolRefusal) {
        switch run.state {
        case .active, .complete: return
        case .planning: throw ToolRefusal("This operation’s plan isn’t under way yet.")
        case .paused: throw ToolRefusal("The person paused this operation. Wait until they resume it.")
        case .operatorOffline: throw ToolRefusal("AiTerm has this operation offline; it resumes it first.")
        case .stopped: throw ToolRefusal("This operation was stopped; its tools no longer act.")
        }
    }

    func notTakenOver(_ task: TaskItem) throws(ToolRefusal) -> OperatedTask {
        guard let operated = task.operated else { throw ToolRefusal("\(task.title) isn’t this operation’s.") }
        guard !operated.takenOver else { throw ToolRefusal("The person took over \(operated.key). Leave it until they hand it back.") }
        return operated
    }

    /// A transition of the task by the operator, through part C's table under this build's milestone:
    /// a failed task's dependents are blocked with it; a refusal is the tool's error, in C's words.
    func apply(_ action: OperatedAction, to task: TaskItem) throws {
        let milestone = ports.milestone
        do {
            try workspace.mutate { state in
                _ = try OperatedTransitions.apply(action, toTask: task.id, in: &state, by: .operatorTool, milestone: milestone)
            }
        } catch let refused as OperatedTransitionError {
            throw ToolRefusal(refused.description)
        }
    }

    /// `ref` as the full commit it names in the task's repository.
    private func commit(_ ref: String, in task: TaskItem) async throws -> String {
        guard let project = state.project(id: task.projectId) else { throw ToolRefusal("Its project is no longer in AiTerm.") }
        let git = ports.git, path = project.path
        do {
            return try await BackgroundWork.run {
                try git.run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            throw ToolRefusal("\(ref) isn’t a commit in \(project.name).")
        }
    }
}
