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
            // The committed work mark_task accepts: from where the branch left its base to HEAD, so a base that
            // moved on is not read back as the worker's changes; edits not yet committed are told apart.
            let git = ports.git, path = task.worktreePath, base = task.baseBranch
            let read: (commits: String, diff: String, uncommitted: String)
            do {
                read = try await BackgroundWork.run {
                    (try git.run(["log", "--oneline", "\(base)..HEAD"], in: path), try git.run(["diff", "\(base)...HEAD"], in: path),
                     try git.run(["status", "--porcelain"], in: path))
                }
            } catch {
                throw ToolRefusal("AiTerm couldn’t read \(key)’s branch against \(base.isEmpty ? "its base" : base).")
            }
            return ["commits": .string(read.commits), "diff": .string(String(read.diff.prefix(Self.diffLimit))),
                    "truncated": .bool(read.diff.count > Self.diffLimit), "uncommitted": .string(read.uncommitted)]
        case "prompt":
            guard let tab = workerTab(of: task) else { return ["prompt": .null, "note": "Its worker has no open tab right now."] }
            // No helper is unknown, not "no prompt".
            guard let daemon = daemon() else { throw ToolRefusal("AiTerm’s helper isn’t connected; try again in a moment.") }
            return ["prompt": try await daemon.prompt(sessionId: tab.sessionId).map { .string($0.rawValue) } ?? .null]
        case "review":
            return try await reviewReading(task, in: run)
        case let other:
            throw ToolRefusal("read_task reads lastMessage, diff, prompt or review, not \(other).")
        }
    }

    func replayedMessage(_ call: ToolCall, in run: OperatorRun) throws(ToolRefusal) -> JSONValue? {
        guard call.tool == "message_task" else { return nil }
        let task = try self.task(call, in: run), text = try call.string("text"), now = ports.now()
        deliveredMessages = deliveredMessages.filter { now.timeIntervalSince($0.value.at) < 600 }
        return deliveredMessages[MessageKey(task: task.id, text: text)]?.answer
    }

    /// Delivered by the daemon's rules (spec §7.1) with the task's ownership generation, so a send begun
    /// before a takeover cannot land after it. Never retried here: the result says what happened.
    func messageTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), text = try call.string("text")
        try acceptsWork(run)
        let operated = try notTakenOver(task)
        // An ended task is left as it ended: more steering would move its branch past what was accepted. A task in
        // review is steered to fix its reviewers' feedback, and accepted again after.
        guard [.working, .blocked, .inReview].contains(operated.state) else {
            throw ToolRefusal("\(operated.key) is \(operated.state.rawValue): there is no worker to steer.")
        }
        let key = MessageKey(task: task.id, text: text), now = ports.now()
        deliveredMessages = deliveredMessages.filter { now.timeIntervalSince($0.value.at) < 600 }
        if let recorded = deliveredMessages[key] { return recorded.answer }
        guard sendingMessages.insert(key).inserted else { throw ToolRefusal("This message is still being delivered; call again for its result.") }
        defer { sendingMessages.remove(key) }
        guard let tab = workerTab(of: task) else { throw ToolRefusal("\(operated.key)’s worker has no open tab right now.") }
        guard let daemon = daemon() else { throw ToolRefusal("AiTerm’s helper isn’t connected; try again in a moment.") }
        let delivery = try await daemon.deliver(sessionId: tab.sessionId, text: text, ownership: operated.ownership, wake: false,
                                                worktree: task.worktreePath)
        let answer: JSONValue = ["result": .string(delivery.result.rawValue), "reason": delivery.reason.map(JSONValue.string) ?? .null]
        if delivery.result == .delivered { deliveredMessages[key] = (ports.now(), answer) }
        return answer
    }

    /// The operator's outcome (spec §6, §8). Accepted needs the commit its branch is on, unmoved, and the
    /// worker's check output; the same outcome for the same commit returns what was recorded.
    func markTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), outcome = try call.string("outcome")
        // A repeat of what was recorded changes nothing, so it answers even while paused or taken over.
        if let operated = task.operated, try await isRepeat(of: outcome, call, operated, in: task) { return Self.taskAnswer(task, created: false) }
        try recheck(task)
        try acceptsWork(run)
        let operated = try notTakenOver(task)
        let action: OperatedAction
        switch outcome {
        case "accepted":
            let given = try call.string("sha"), check = try call.string("checkOutput")
            let sha = try await commit(given, in: task)
            try recheck(task)
            let tip = try await commit("refs/heads/" + task.branch, in: task)
            try recheck(task)
            guard sha == tip else {
                throw ToolRefusal("\(operated.key)’s branch is at \(tip.prefix(7)), not \(given): accept the commit its branch is on.")
            }
            // A task whose code parent was accepted again builds on the new commit before it is accepted (M3, spec §8).
            let why = try await upstreamRefusal(task, result: sha)
            try recheck(task)
            if let why { throw ToolRefusal(why) }
            let prerequisites = RunScheduler.baseCommit(for: task.id, in: state).map { [$0] } ?? []
            let acceptance = TaskAcceptance(resultSHA: sha, prerequisiteSHAs: prerequisites, checkOutput: check,
                                            note: call.optionalString("note"), at: ports.now())
            // Accepted again on another commit: its dependents are revoked and flagged. Before M3, part C refuses
            // it once a code dependent has started (M1, spec §8).
            if ports.milestone >= .m3, [.accepted, .published, .inReview].contains(operated.state) {
                return try reaccept(task, as: acceptance)
            }
            action = .accept(acceptance, branchHead: tip)
        case "noChange":
            action = .noChange(note: call.optionalString("note"))
        case "blocked", "failed":
            let reason = try call.string("note")
            action = outcome == "blocked" ? .block(reason: reason) : .fail(reason: reason)
        default:
            throw ToolRefusal("mark_task’s outcome is accepted, noChange, blocked or failed.")
        }
        try apply(action, to: task)
        // Its result holds each code parent's accepted commit (`upstreamRefusal` said so): the flag is done with.
        if outcome == "accepted" { mutate(in: run.id) { $0.updateOperated(task.id) { $0.flags.remove(.upstreamReplaced) } } }
        let marked = state.task(id: task.id) ?? task
        return Self.taskAnswer(marked, created: false)
    }

    /// Whether `outcome` is what the task already records: the same commit accepted, no change, or the same reason.
    private func isRepeat(of outcome: String, _ call: ToolCall, _ operated: OperatedTask, in task: TaskItem) async throws -> Bool {
        switch outcome {
        case "accepted":
            guard [.accepted, .published, .inReview].contains(operated.state), let given = call.optionalString("sha") else { return false }
            return operated.acceptance?.resultSHA == (try await commit(given, in: task))
        case "noChange": return operated.state == .noChange
        case "blocked", "failed": return operated.state.rawValue == outcome && operated.blockedReason == call.optionalString("note")
        default: return false
        }
    }

    /// Why `task`, flagged upstream replaced, cannot be accepted on `result` yet: git must say `result`
    /// holds each code parent's accepted commit. Nil for a task that is not flagged.
    private func upstreamRefusal(_ task: TaskItem, result: String) async throws -> String? {
        guard task.operated?.flags.contains(.upstreamReplaced) == true,
              let project = state.project(id: task.projectId) else { return nil }
        let state = self.state, git = ports.git, path = project.path
        return try await BackgroundWork.run {
            let repository = Repository(path, git: git)
            return try UpstreamReplacement.acceptRefusal(for: task, in: state, contains: { try repository.contains($0, in: result) })
        }
    }

    /// An accepted or published task accepted again on another commit, in one change: its acceptance
    /// replaced (a published draft keeps its request, which `finish_task` pushes the new commit to), its
    /// accepted code dependents back to working and every started one flagged. The answer names them, and
    /// each operation holding one is woken once (`finish_task` of one of them refuses meanwhile).
    private func reaccept(_ task: TaskItem, as acceptance: TaskAcceptance) throws -> JSONValue {
        try recheck(task)
        let revoked: [UUID]
        do {
            revoked = try mutate(in: task.operated?.runId) { state in
                let revoked = try UpstreamReplacement.reaccept(task.id, as: acceptance, in: &state)
                state.updateOperated(task.id) { $0.flags.remove(.upstreamReplaced) }
                // A complete operation holding work again is not complete: it settles once that is done.
                let runs = Set(([task.id] + revoked).compactMap { state.task(id: $0)?.operated?.runId })
                for id in runs {
                    guard let run = state.run(id: id), run.state == .complete, !RunScheduler.isComplete(run, in: state) else { continue }
                    state.updateRun(id: id) { $0.state = .active }
                }
                return revoked
            }
        } catch let refusal as UpstreamReplacement.Refusal {
            switch refusal {
            case .notAccepted(let why), .merged(let why): throw ToolRefusal(why)
            }
        }
        let keys = revoked.compactMap { id in state.task(id: id)?.operated.map { ($0.runId, $0.key) } }
        for (run, keys) in Dictionary(grouping: keys, by: \.0) {
            let seen = run == task.operated?.runId ? state.run(id: run).flatMap(currentStatus(of:)) : nil
            waker.say("\(keys.map(\.1).joined(separator: ", ")) needs a rebase: \(task.operated?.key ?? task.title) was accepted again",
                       to: run, unlessAcknowledged: seen)
        }
        let marked = state.task(id: task.id) ?? task
        guard case .object(var fields) = Self.taskAnswer(marked, created: false) else { return Self.taskAnswer(marked, created: false) }
        fields["revokedDependents"] = .array(keys.map { JSONValue.string($0.1) })
        return .object(fields)
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
        let limit = OperatorTiming.retries
        guard operated.retriesUsed < limit else {
            throw ToolRefusal("\(operated.key) has used its \(limit) retr\(limit == 1 ? "y" : "ies"). Ask the person with ask_you how to go on.")
        }
        try apply(.retry, to: task)
        return Self.taskAnswer(state.task(id: task.id) ?? task, created: false)
    }

    // -- helpers ---------------------------------------------------------------------------------
    func recheck(_ original: TaskItem) throws(ToolRefusal) {
        guard let task = state.task(id: original.id), let operated = task.operated,
              let run = state.run(id: operated.runId), operated.runId == original.operated?.runId else {
            throw ToolRefusal("This task is no longer in this broadcast.")
        }
        try acceptsWork(run)
        _ = try notTakenOver(task)
        guard operated.ownership == original.operated?.ownership, operated.state == original.operated?.state,
              operated.acceptance == original.operated?.acceptance, operated.dependsOn == original.operated?.dependsOn,
              operated.flags == original.operated?.flags else {
            throw ToolRefusal("This task changed while AiTerm was checking it; read run_status and try again.")
        }
    }

    /// Work moves only in an active or complete operation (spec §9).
    func acceptsWork(_ run: OperatorRun) throws(ToolRefusal) {
        if run.intent == .stopped { throw ToolRefusal("This broadcast was stopped; its tools no longer act.") }
        if run.intent == .paused { throw ToolRefusal("The person paused this broadcast. Wait until they resume it.") }
        switch run.state {
        case .active, .complete: return
        case .planning: throw ToolRefusal("This broadcast’s plan isn’t under way yet.")
        case .paused: throw ToolRefusal("The person paused this broadcast. Wait until they resume it.")
        case .operatorOffline: throw ToolRefusal("AiTerm has this broadcast offline; it resumes it first.")
        case .stopped: throw ToolRefusal("This broadcast was stopped; its tools no longer act.")
        }
    }

    func notTakenOver(_ task: TaskItem) throws(ToolRefusal) -> OperatedTask {
        guard let operated = task.operated else { throw ToolRefusal("\(task.title) isn’t this broadcast’s.") }
        guard !operated.takenOver else { throw ToolRefusal("The person took over \(operated.key). Leave it until they hand it back.") }
        return operated
    }

    /// A transition of the task by the operator, through part C's table under this build's milestone:
    /// a failed task's dependents are blocked with it; a refusal is the tool's error, in C's words.
    func apply(_ action: OperatedAction, to task: TaskItem) throws {
        let milestone = ports.milestone
        do {
            try mutate(in: task.operated?.runId) { state in
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
