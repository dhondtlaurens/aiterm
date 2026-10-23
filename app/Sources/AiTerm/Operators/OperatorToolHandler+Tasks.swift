import Foundation
import AiTermCore

/// A started task, as the operator works it (spec §6): what it reads of the worker — its own words
/// from its conversation file, its branch's diff, the prompt it has open — what it says to it through
/// the daemon's delivery, and the outcome it records. A task you took over refuses all but reading.
extension OperatorToolHandler {
    /// The most of a diff a review's prompt carries; `read_task`'s own answer is a `DiffDigest`, which is smaller.
    static let diffLimit = 60_000

    /// Where the task's own work starts (spec §9): a stacked task's parent's accepted commit, else where its branch left
    /// origin's copy of its base branch, fetched first, so a local `main` that lags origin is not read back as the
    /// worker's changes. A project with no origin, or one that has no such branch, is read from the task's own base.
    /// A fetch that fails (offline) is not a refusal: origin's branch is read as it was last fetched.
    ///
    /// The fetch is bounded (`OperatorTiming.diffBaseFetchTimeout`) and done at most once a minute for the same base
    /// (`diffBaseFetchInterval`), a failed try included, so a slow remote or a VPN down never holds `read_task diff` or
    /// `review_task` past the daemon's wait for the app's answer.
    ///
    /// Always where that base and HEAD meet, so what `log` and `diff` measure from is the `base` an answer reports,
    /// even when a parent's accepted commit is not in the branch's history (it was rebased).
    func diffBase(of task: TaskItem, in run: OperatorRun) async throws -> String {
        let stacked = RunScheduler.baseCommit(for: task.id, in: state)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let git = ports.git, path = task.worktreePath, named = task.baseBranch, now = ports.now()
        let recent = Set(diffBaseFetches.filter { now.timeIntervalSince($0.value) < OperatorTiming.diffBaseFetchInterval }.keys)
        let (base, fetched) = try await BackgroundWork.run { () throws -> (String, String?) in
            let repository = Repository(path, git: git)
            if let stacked, !stacked.isEmpty { return (try repository.mergeBase(stacked, "HEAD") ?? stacked, nil) }
            guard try repository.hasOrigin else { return (try repository.mergeBase(named, "HEAD") ?? named, nil) }
            let branch = named.isEmpty ? repository.defaultBranch() : named
            let key = path + "\n" + branch
            let fetching = !recent.contains(key)
            if fetching {
                Log.git.attempt("Fetching \(branch) from origin in \(path)") {
                    try repository.fetchFromOrigin(branch, timeout: OperatorTiming.diffBaseFetchTimeout)
                }
            }
            let base = try repository.mergeBase("origin/" + branch, "HEAD") ?? repository.mergeBase(named, "HEAD") ?? named
            return (base, fetching ? key : nil)
        }
        if let fetched { diffBaseFetches[fetched] = now }
        return base
    }

    /// The worker's tab: the task's first worker, never one of the Operator's extra tabs (`TaskItem.firstWorker`).
    func workerTab(of task: TaskItem) -> SessionInfo? { task.firstWorker(in: live.sessions) }

    /// Every worker tab of the task: its first worker, then each extra tab (`TaskItem.workerTabs`).
    func workerTabs(of task: TaskItem) -> [WorkerTab] { task.workerTabs(in: live.sessions) }

    /// The worker tab the call's `tab` names (`TaskItem.workerTab`): the first worker without one. A key the task has no
    /// tab for is refused, naming the tabs it has.
    func worker(_ call: ToolCall, of task: TaskItem) throws(ToolRefusal) -> WorkerTab {
        let key = call.optionalString("tab")
        if let tab = task.workerTab(key, in: live.sessions) { return tab }
        let keys = [WorkerTab.firstKey] + workerTabs(of: task).compactMap(\.key)
        throw ToolRefusal("\(task.operated?.key ?? task.title) has no tab \(key ?? ""). Its tabs are \(keys.joined(separator: ", ")).")
    }

    /// Why `tab` has no agent to reach: an extra tab closed or still opening, or a first worker with no tab listed.
    static func noAgent(in tab: WorkerTab, of task: TaskItem) -> String {
        let key = task.operated?.key ?? task.title
        guard let name = tab.key else { return "\(key)’s worker has no open tab right now." }
        return tab.isOpening ? "\(key)’s tab \(name) is still opening; try again in a moment."
                             : "\(key)’s tab \(name) was closed. AiTerm doesn’t open it again."
    }

    func readTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), key = task.operated?.key ?? task.title
        switch try call.string("what") {
        case "lastMessage":
            let worker = try self.worker(call, of: task)
            guard let conversation = worker.conversation else {
                return ["lastMessage": .null, "note": "Its worker hasn’t started a conversation yet."]
            }
            let home = ports.home, claudeConfig = ports.claudeConfig, agent = worker.agent
            let text = await BackgroundWork.run {
                WorkerTranscript.lastMessage(agent: agent, conversation: conversation, home: home, claudeConfig: claudeConfig)
            }
            // No reply found is unknown, not silence: the transcript reads only its tail, and a worker may have said it earlier.
            guard let text else {
                return ["lastMessage": .null, "note": "No reply found in the recent part of its conversation; that doesn’t mean it said nothing. Use read_task with what: diff or prompt."]
            }
            return ["lastMessage": .string(text)]
        case "diff":
            guard task.hasCheckout else { throw ToolRefusal("\(key) hasn’t started: it has no worktree yet.") }
            // The committed work mark_task accepts: from where the branch left its base to HEAD, so a base that
            // moved on is not read back as the worker's changes; edits not yet committed are told apart.
            let git = ports.git, path = task.worktreePath
            let read: (head: String, commits: String, stat: String, diff: String, uncommitted: String)
            let base: String
            do {
                base = try await diffBase(of: task, in: run)
                read = try await BackgroundWork.run {
                    (try git.run(["rev-parse", "HEAD"], in: path),
                     try git.run(["log", "--oneline", "\(base)..HEAD"], in: path), try git.run(["diff", "--stat", "\(base)...HEAD"], in: path),
                     try git.run(["diff", "\(base)...HEAD"], in: path), try git.run(["status", "--porcelain"], in: path))
                }
            } catch {
                throw ToolRefusal("AiTerm couldn’t read \(key)’s branch against \(task.baseBranch.isEmpty ? "its base" : task.baseBranch).")
            }
            // The whole answer is small, not only its patches: a wide diff lists some of its files, and the stat, the
            // commits and the uncommitted edits keep their ends.
            let stat = DiffDigest.lastLines(read.stat, DiffDigest.statLines), commits = DiffDigest.firstLines(read.commits, DiffDigest.commitLines)
            let uncommitted = DiffDigest.firstLines(read.uncommitted, DiffDigest.uncommittedLines)
            // What those leave of the answer's room is the patches': a file a line of stat lists is about a line of its answer.
            let budget = DiffDigest.patchBudget(others: stat.text.count + commits.text.count + uncommitted.text.count,
                                                files: read.stat.split(separator: "\n").count)
            let digest = DiffDigest.build(diff: read.diff, total: budget)
            var files = digest.files.prefix(DiffDigest.listedFiles).map { file -> JSONValue in
                var entry: [String: JSONValue] = ["path": .string(file.path), "truncated": .bool(file.truncated)]
                if let patch = file.patch { entry["patch"] = .string(patch) }
                if let summary = file.summary { entry["summary"] = .string(summary) }
                return .object(entry)
            }
            let unlisted = digest.files.count - files.count
            if unlisted > 0 { files.append(["path": .string("and \(unlisted) more files"), "truncated": true]) }
            return ["base": .string(base), "head": .string(read.head), "stat": .string(stat.text), "commits": .string(commits.text),
                    "files": .array(files), "truncated": .bool(digest.truncated || unlisted > 0 || stat.cut || commits.cut || uncommitted.cut),
                    "uncommitted": .string(uncommitted.text)]
        case "prompt":
            let worker = try self.worker(call, of: task)
            guard let tab = worker.session, !worker.isOpening else {
                return ["prompt": .null, "note": .string(worker.key == nil ? "Its worker has no open tab right now." : Self.noAgent(in: worker, of: task))]
            }
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
        guard call.operatorTool == .messageTask else { return nil }
        let task = try self.task(call, in: run), text = try call.string("text"), now = ports.now()
        deliveredMessages = deliveredMessages.filter { now.timeIntervalSince($0.value.at) < Self.messageReplayWindow }
        return deliveredMessages[MessageKey(task: task.id, tab: Self.tabKey(call), text: text)]?.answer
    }

    /// The extra tab the call's `tab` names; nil for the first worker, named or not.
    static func tabKey(_ call: ToolCall) -> String? { call.optionalString("tab").flatMap { $0 == WorkerTab.firstKey ? nil : $0 } }

    /// Delivered by the daemon's rules (spec §7.1) with the task's ownership generation, so a send begun
    /// before a takeover cannot land after it. Never retried here: the result says what happened. To the first
    /// worker, or to the tab `tab` names.
    func messageTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), text = try call.string("text")
        let operated = try self.operated(task, in: run)
        // An ended task is left as it ended: more steering would move its branch past what was accepted. A task in
        // review is steered to fix its reviewers' feedback, and accepted again after; one accepted keeps its worker until
        // its commit is on origin, so a push the hook refused can be put to it (spec §D).
        guard [.working, .blocked, .inReview].contains(operated.state) || OperatedTransitions.isReopenable(operated) else {
            let why = operated.state != .accepted ? "" : operated.publication?.leftForYou == true ? " and its publication is left to you"
                                                                                                  : " and its commit is on origin"
            throw ToolRefusal("\(operated.key) is \(operated.state.rawValue)\(why): there is no worker to steer.")
        }
        let worker = try self.worker(call, of: task)
        let key = MessageKey(task: task.id, tab: worker.key, text: text), now = ports.now()
        deliveredMessages = deliveredMessages.filter { now.timeIntervalSince($0.value.at) < Self.messageReplayWindow }
        if let recorded = deliveredMessages[key] { return recorded.answer }
        guard sendingMessages.insert(key).inserted else { throw ToolRefusal("This message is still being delivered; call again for its result.") }
        defer { sendingMessages.remove(key) }
        guard let tab = worker.session, !worker.isOpening else { throw ToolRefusal(Self.noAgent(in: worker, of: task)) }
        guard let daemon = daemon() else { throw ToolRefusal("AiTerm’s helper isn’t connected; try again in a moment.") }
        let delivery = try await daemon.deliver(sessionId: tab.sessionId, text: text, ownership: operated.ownership, wake: false,
                                                worktree: task.worktreePath)
        // Its worker has the Operator's word: what its last turn asked or left is answered (spec §J).
        if delivery.result == .delivered, worker.key == nil { onMessaged(task.id) }
        var fields: [String: JSONValue] = ["result": .string(delivery.result.rawValue), "reason": delivery.reason.map(JSONValue.string) ?? .null]
        // Steered, an accepted task is at work again; accepting it on its commit or another says what came of it.
        if delivery.result == .delivered, operated.state == .accepted, reopen(task) { fields["reopened"] = true }
        let answer = JSONValue.object(fields)
        if delivery.result == .delivered { deliveredMessages[key] = (ports.now(), answer) }
        return answer
    }

    /// An accepted task back to its worker, in one change; a complete operation holding work again settles once it is
    /// done. False where the task moved on while its message was delivered: the worker has it, the task stays as it is.
    private func reopen(_ task: TaskItem) -> Bool {
        do {
            try mutate(in: task.operated?.runId) { state in
                try OperatedTransitions.apply(.reopen, toTask: task.id, in: &state, by: .operatorTool)
                Self.reactivateCompleteRuns(holding: [task.id], in: &state)
            }
            return true
        } catch { return false }
    }

    /// A complete operation holding work again is not complete: it settles once that is done, and its summary, which no
    /// longer tells the whole of it, goes with its completion.
    private static func reactivateCompleteRuns(holding ids: [UUID], in state: inout AppState) {
        let runs = Set(ids.compactMap { state.task(id: $0)?.operated?.runId })
        for id in runs {
            guard let run = state.run(id: id), run.state == .complete, !RunScheduler.isComplete(run, in: state) else { continue }
            state.updateRun(id: id) { $0.state = .active; $0.reopen() }
        }
    }

    /// The operator's outcome (spec §6, §8). Accepted needs the commit its branch is on, unmoved, and the
    /// worker's check output; the same outcome for the same commit returns what was recorded.
    func markTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), outcome = try call.string("outcome")
        // A repeat of what was recorded changes nothing, so it answers even while paused or taken over.
        if let operated = task.operated, try await isRepeat(of: outcome, call, operated, in: task) { return Self.taskAnswer(task, created: false) }
        try recheck(task)
        let operated = try self.operated(task, in: run)
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
            // A task whose code parent was accepted again builds on the new commit before it is accepted (spec §8).
            let why = try await upstreamRefusal(task, result: sha)
            try recheck(task)
            if let why { throw ToolRefusal(why) }
            let prerequisites = RunScheduler.baseCommit(for: task.id, in: state).map { [$0] } ?? []
            let acceptance = TaskAcceptance(resultSHA: sha, prerequisiteSHAs: prerequisites, checkOutput: check,
                                            note: call.optionalString("note"), at: ports.now())
            // Accepted again on another commit: its dependents are revoked and flagged.
            if [.accepted, .published, .inReview].contains(operated.state) {
                return try reaccept(task, as: acceptance)
            }
            // Steered back to work after it was accepted (spec §D), and now on another commit: what its children were
            // built on is replaced, as for any task accepted again.
            if operated.state == .working, let earlier = operated.reopenedFrom,
               !OperatedTransitions.sameCommit(earlier, sha) {
                return try reacceptReopened(task, as: acceptance, branchHead: tip)
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
        return try answerRevoking(task) { state in
            do {
                let revoked = try UpstreamReplacement.reaccept(task.id, as: acceptance, in: &state)
                state.updateOperated(task.id) { $0.flags.remove(.upstreamReplaced) }
                return revoked
            } catch let refusal as UpstreamReplacement.Refusal {
                switch refusal {
                case .notAccepted(let why), .merged(let why): throw ToolRefusal(why)
                }
            }
        }
    }

    /// A task steered back to work after it was accepted (`reopenedFrom`), accepted now on another commit: the accept and
    /// the replacement of its children in one change, answered as `reaccept` does.
    private func reacceptReopened(_ task: TaskItem, as acceptance: TaskAcceptance, branchHead: String) throws -> JSONValue {
        try recheck(task)
        return try answerRevoking(task) { state in
            do {
                try OperatedTransitions.apply(.accept(acceptance, branchHead: branchHead), toTask: task.id, in: &state, by: .operatorTool)
            } catch let refused as OperatedTransitionError {
                throw ToolRefusal(refused.description)
            }
            state.updateOperated(task.id) { $0.flags.remove(.upstreamReplaced) }
            return UpstreamReplacement.revokeDependents(of: task.id, newSHA: acceptance.resultSHA, in: &state)
        }
    }

    /// `change` made in one mutation, which returns the dependents it revoked: an operation that was complete holds work
    /// again, each one holding a revoked task is woken once, and the answer names them.
    private func answerRevoking(_ task: TaskItem, _ change: (inout AppState) throws -> [UUID]) throws -> JSONValue {
        let revoked = try mutate(in: task.operated?.runId) { state in
            let revoked = try change(&state)
            Self.reactivateCompleteRuns(holding: [task.id] + revoked, in: &state)
            return revoked
        }
        let keys = revoked.compactMap { id in state.task(id: id)?.operated.map { ($0.runId, $0.key) } }
        for (run, keys) in Dictionary(grouping: keys, by: \.0) {
            let seen = run == task.operated?.runId ? state.run(id: run).flatMap(currentStatus(of:)) : nil
            waker.say(keys.count == 1 ? "one task needs rebasing: another was accepted again" : "some tasks need rebasing: another was accepted again",
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
        let operated = try self.operated(task, in: run)
        if operated.state != .working { try apply(.resume, to: task) }
        return Self.taskAnswer(state.task(id: task.id) ?? task, created: false)
    }

    /// `failed` → `queued` while retries are left; AiTerm then starts it again (`WorkerStarter`).
    func retryTask(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let task = try self.task(call, in: run)
        let operated = try self.operated(task, in: run)
        guard operated.state == .failed else { return Self.taskAnswer(task, created: false) }
        let limit = OperatorTiming.retries
        guard operated.retriesUsed < limit else {
            throw ToolRefusal("\(operated.key) has used its \(limit) retr\(limit == 1 ? "y" : "ies"). Ask the person how to go on, in your chat and with ask_you.")
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
        _ = try self.operated(task, in: run)
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

    /// The task's record, once its broadcast takes work (`acceptsWork`) and the person hasn't taken it over (`notTakenOver`),
    /// refused in that order.
    func operated(_ task: TaskItem, in run: OperatorRun) throws(ToolRefusal) -> OperatedTask {
        try acceptsWork(run)
        return try notTakenOver(task)
    }

    func notTakenOver(_ task: TaskItem) throws(ToolRefusal) -> OperatedTask {
        guard let operated = task.operated else { throw ToolRefusal("\(task.title) isn’t this broadcast’s.") }
        guard !operated.takenOver else { throw ToolRefusal("The person took over \(operated.key). Leave it until they hand it back.") }
        return operated
    }

    /// A transition of the task by the operator, through part C's table: a failed task's dependents are blocked
    /// with it; a refusal is the tool's error, in C's words.
    func apply(_ action: OperatedAction, to task: TaskItem) throws {
        do {
            try mutate(in: task.operated?.runId) { state in
                _ = try OperatedTransitions.apply(action, toTask: task.id, in: &state, by: .operatorTool)
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
