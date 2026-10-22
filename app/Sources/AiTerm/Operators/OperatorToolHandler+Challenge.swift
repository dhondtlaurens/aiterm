import Foundation
import Synchronization
import AiTermCore

/// The Oracle's challenge (spec §8), enforced by AiTerm rather than the Operator: a challenged call does not
/// take effect on its first call. The critique comes back instead, and only a later call with its
/// `challengeId` acts — with the act revised or `challengeReply` answering each point — and is logged
/// with the critique. A critique not ready within the reply budget is said to be pending; the call
/// that first returns it still does not act. Each challenge is a `ChallengeRecord` in its run, saved
/// with the workspace, so a lost reply or a restart neither loses it nor makes it act twice.
extension OperatorToolHandler {
    /// With the Oracle on, a plan and a verdict on a task are critiqued (spec §8), a backlog addition past
    /// the threshold (`backlog` is `.needsOracle`) gets its veto (spec §4.1), and a `finish_task` that would merge
    /// (`merges`) its yes that the conditions written in the Review and the Done hold (spec §5); with it off,
    /// nothing is. A message to a worker never is.
    static func isChallenged(_ call: ToolCall, oracleIsOn: Bool, backlog: BacklogBudget.Verdict = .free, merges: Bool = false) -> Bool {
        guard oracleIsOn else { return false }
        switch call.tool {
        case "submit_plan": return true
        case "mark_task": return ["accepted", "blocked", "failed"].contains(call.optionalString("outcome") ?? "")
        case "create_task": return backlog == .needsOracle
        case "finish_task": return merges
        default: return false
        }
    }

    /// The task a `finish_task` would merge now, unless the Oracle said yes for its accepted commit already: a merge
    /// end, through the request or local, with the Merge slice on, accepted and not going into review, or in review
    /// with this call ending it. Nil for anything else, which the Oracle is not asked about.
    private func mergeAwaitingOracle(_ call: ToolCall, in run: OperatorRun) -> TaskItem? {
        guard call.tool == "finish_task", run.profile.slices.merge, PublicationGuard.runRefusal(run) == nil,
              let task = try? task(call, in: run), let operated = task.operated, operated.end.merges, !operated.takenOver,
              let sha = operated.acceptance?.resultSHA, operated.publication?.merged != true,
              operated.publication?.conditionsHeld != sha else { return nil }
        switch operated.state {
        case .inReview: return task
        case .accepted: return TaskPublisher.Context.entersReview(operated, run: run) ? nil : task
        default: return nil
        }
    }

    /// Where a `create_task` stands against the backlog now: free for any other tool, or for a key already made.
    private func backlog(of call: ToolCall, in run: OperatorRun) -> BacklogBudget.Verdict {
        guard call.tool == "create_task", let key = call.optionalString("key"),
              !state.tasks(inRun: run.id).contains(where: { $0.operated?.key == key }) else { return .free }
        return backlogVerdict(run)
    }

    /// Nil: the call takes effect. Otherwise what the operator reads instead.
    func challengeGate(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue? {
        if call.tool == "finish_task", let task = try? task(call, in: run), task.operated?.publication?.mergeRefusal != nil {
            mutate(in: run.id) { $0.updateOperated(task.id) { $0.publication?.mergeRefusal = nil } }
        }
        let opinion = run.profile.oracle
        // A call naming a challenge of its tool is that challenge's, whatever the call's arguments say now: the acting call
        // repeated must still replay, not act again.
        let named = call.optionalString("challengeId").flatMap { id in
            state.run(id: run.id)?.challenges.first { $0.id == id && $0.tool == call.tool }
        }
        let merging = mergeAwaitingOracle(call, in: run)
        if named == nil, !Self.isChallenged(call, oracleIsOn: opinion.isOn, backlog: backlog(of: call, in: run), merges: merging != nil) { return nil }
        if let id = call.optionalString("challengeId") {
            guard let kept = named else {
                throw ToolRefusal("No challenge \(id) for \(call.tool) here; call again without challengeId.")
            }
            guard !actingChallenges.contains(id) else {
                throw ToolRefusal("Challenge \(id) is already acting on \(call.tool); call again for its result.")
            }
            if kept.stage == .acted {
                // The acting call again — its reply lost, or AiTerm restarted since: what it answered, and nothing more.
                guard kept.actedArguments == Self.invocation(call), let result = kept.result,
                      let answer = try? JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)) else {
                    throw ToolRefusal("Challenge \(id) has already acted on \(call.tool). Call again without challengeId for another change.")
                }
                return answer
            }
            if kept.kind == .veto { return try await vetoAnswer(call, kept, in: run) }
            let reply = call.optionalString("challengeReply")
            switch kept.stage {
            case .acted:
                return nil
            case .running where runningChallenges[id] != nil:
                return Self.pendingAnswer(id)
            case .running:
                // Its second opinion was lost with AiTerm's restart, and never holds the act up (spec §4.4).
                let reason = "AiTerm restarted before the second opinion answered."
                updateChallenge(id, in: run.id) { $0.stage = .unchallenged; $0.unchallengedReason = reason }
                record(call, in: run, challenge: "unchallenged: \(reason)", reply: reply ?? "proceeded")
                actingChallenges.insert(id)
                return nil
            case .ready:
                updateChallenge(id, in: run.id) { $0.stage = .delivered }
                return Self.challengedAnswer(id, kept.critique ?? "")
            case .delivered:
                // Answered and kept as it was, the act goes against the critique: the Operator's decision, with the objection.
                record(call, in: run, challenge: kept.critique ?? "", reply: reply ?? "revised the call", objection: reply.flatMap { _ in kept.critique })
                actingChallenges.insert(id)
                return nil
            case .unchallenged:
                record(call, in: run, challenge: "unchallenged: \(kept.unchallengedReason ?? "")", reply: reply ?? "proceeded")
                actingChallenges.insert(id)
                return nil
            }
        }
        let kind: ChallengeKind = ["create_task", "finish_task"].contains(call.tool) ? .veto : .critique
        let status = Self.json(currentStatus(of: run).flatMap { try? JSONValue(encoding: $0) } ?? .null)
        let prompt: String
        if let merging, let operated = merging.operated, let sha = operated.acceptance?.resultSHA {
            // Only a finished review of this very commit is evidence for merging it.
            let evidence = operated.agentReview.flatMap { review in
                review.head == sha && review.findings != nil ? (try? JSONValue(encoding: review)).map(Self.json) : nil
            }
            prompt = ChallengeLaunch.mergePrompt(task: operated.key, acceptedSHA: sha, brief: operated.brief, review: OperatorCommand.said(run.review),
                                                 done: OperatorCommand.said(run.done), agentReview: evidence, run: status)
        } else if kind == .veto {
            // A call that would be refused anyway costs no Oracle run.
            try await vetoPrecheck(call, in: run)
            prompt = ChallengeLaunch.vetoPrompt(addition: Self.invocation(call), run: status)
        } else {
            prompt = ChallengeLaunch.prompt(tool: call.tool, arguments: Self.json(call.arguments), status: status,
                                            instructions: run.profile.instructions)
        }
        let id = UUID().uuidString
        // A merge's yes holds for the commit accepted now, which the record keeps.
        let askedSHA = merging?.operated?.acceptance?.resultSHA
        let asked = ChallengeRecord(id: id, tool: call.tool, kind: kind, askedArguments: Self.invocation(call), askedSHA: askedSHA,
                                    askedAt: ports.now())
        mutate(in: run.id) { $0.updateRun(id: run.id) { $0.challenges.append(asked) } }
        let runner = ports.secondOpinion, folder = OperatorCommand.runFolder(run.id, home: ports.home)
        let projects = run.projectIds.compactMap(state.project(id:)).map(\.path)
        // The runner turns every thrown error, a cancellation included, into `.unchallenged`; a challenge
        // cancelled (AiTerm quitting) is not an answer, so it settles as nil, and its record stays `.running`.
        let challenge = Task { () -> SecondOpinionRunner.Verdict? in
            let verdict = await runner.challenge(opinion, prompt: prompt, runFolder: folder, projects: projects)
            return Task.isCancelled ? nil : Self.capped(verdict)
        }
        // The Oracle is consulted until it answers, however long that outlasts the call: the lines say so.
        let consulting = OperatorActivity(run: run.id, task: call.optionalString("task").flatMap { state.task(inRun: run.id, named: $0)?.id },
                                          act: .consultingTheOracle)
        onActing(consulting, true)
        // Kept for the operator's next call, when it outlasts this one's reply.
        let settled = Task { [weak self] in
            let verdict = await withTaskCancellationHandler { await challenge.value } onCancel: { challenge.cancel() }
            guard let self else { return }
            runningChallenges[id] = nil
            onActing(consulting, false)
            guard let verdict, state.run(id: run.id)?.challenges.first(where: { $0.id == id })?.stage == .running else { return }
            updateChallenge(id, in: run.id) { kept in
                switch verdict {
                case .critique(let critique) where kind == .veto:
                    let veto = Self.veto(critique)
                    kept.stage = .ready; kept.approved = veto.approved; kept.critique = veto.reason
                case .critique(let critique): kept.stage = .ready; kept.critique = critique
                case .unchallenged(let reason): kept.stage = .unchallenged; kept.unchallengedReason = reason
                }
            }
        }
        runningChallenges[id] = settled
        lastChallenge = settled
        let answered = await Self.first(challenge, within: ports.challengeReplyBudget)
        if kind == .veto {
            // Within the budget the answer is this call's, and the record goes: its id was never named to the operator.
            guard case .some(.some(let verdict)) = answered else { return try vetoPendingAnswer(call, id, in: run) }
            mutate(in: run.id) { $0.updateRun(id: run.id) { $0.challenges.removeAll { $0.id == id } } }
            switch verdict {
            case .critique(let text):
                let veto = Self.veto(text)
                guard veto.approved else { try await refuseVetoed(call, in: run, why: veto.reason) }
                try approve(call, in: run, askedSHA: askedSHA)
                return nil
            case .unchallenged:
                if call.tool == "finish_task" { try proceedUnchallenged(call, in: run, askedSHA: askedSHA); return nil }
                try await refuseUnanswered(call, in: run)
            }
        }
        switch answered {
        case nil, .some(nil):
            // Out of budget, or cancelled with AiTerm quitting: its record stays running, and the next call
            // with the id reads it as lost with the restart.
            return Self.pendingAnswer(id)
        case .critique(let critique)??:
            updateChallenge(id, in: run.id) { $0.stage = .delivered; $0.critique = critique }
            return Self.challengedAnswer(id, critique)
        case .unchallenged(let reason)??:
            // Its id was never named to the operator, so nothing calls with it: the record goes.
            mutate(in: run.id) { $0.updateRun(id: run.id) { $0.challenges.removeAll { $0.id == id } } }
            record(call, in: run, challenge: "unchallenged: \(reason)", reply: "proceeded")
            return nil
        }
    }

    /// A veto's call again with its id (spec §4.1). Unlike a critique, only the Oracle's yes acts, with no reply
    /// needed and only for the call it was asked about; a no, a failure, a timeout, or a veto lost with AiTerm's
    /// restart refuses, and AiTerm notes the addition for the summary.
    private func vetoAnswer(_ call: ToolCall, _ kept: ChallengeRecord, in run: OperatorRun) async throws -> JSONValue? {
        let id = kept.id
        // A challenge answers only the call it was asked about, whatever its stage: never another task's.
        guard kept.askedArguments == Self.invocation(call) else {
            throw ToolRefusal("Challenge \(id) was asked about another \(call.tool). Call again without challengeId.")
        }
        switch kept.stage {
        case .running where runningChallenges[id] != nil:
            return try vetoPendingAnswer(call, id, in: run)
        case .running:
            updateChallenge(id, in: run.id) { $0.stage = .unchallenged; $0.unchallengedReason = "AiTerm restarted before the Oracle answered." }
            if call.tool == "finish_task" { try proceedUnchallenged(call, in: run, askedSHA: kept.askedSHA); return nil }
            try await refuseUnanswered(call, in: run)
        case .unchallenged:
            if call.tool == "finish_task" { try proceedUnchallenged(call, in: run, askedSHA: kept.askedSHA); return nil }
            try await refuseUnanswered(call, in: run)
        case .ready, .delivered, .acted:
            guard kept.approved == true else { try await refuseVetoed(call, in: run, why: kept.critique) }
            try approve(call, in: run, askedSHA: kept.askedSHA)
            updateChallenge(id, in: run.id) { $0.stage = .delivered }
            actingChallenges.insert(id)
            return nil
        }
    }

    /// The Oracle's answer to a veto as AiTerm keeps it: an answer that is neither yes nor no is a no.
    private static func veto(_ answer: String) -> (approved: Bool, reason: String?) {
        guard let verdict = ChallengeLaunch.verdict(answer) else { return (false, "The Oracle gave no clear yes.") }
        return (verdict.approved, verdict.reason)
    }

    /// The Oracle's yes: an addition is let past the threshold for this call; a merge goes ahead for `askedSHA`, the commit
    /// accepted when the Oracle was asked, recorded on the task so the merge's later polls hold to it. Refused, and nothing
    /// recorded, when the task was accepted again on another commit meanwhile.
    private func approve(_ call: ToolCall, in run: OperatorRun, askedSHA: String?) throws {
        guard call.tool == "finish_task" else { vettedCalls.insert(Self.invocation(call)); return }
        let task = try task(call, in: run)
        guard let sha = askedSHA, let operated = task.operated, operated.acceptance?.resultSHA == sha else {
            throw ToolRefusal("\(task.operated?.key ?? "The task") was accepted again on another commit while the Oracle judged its merge: "
                              + "call finish_task again without challengeId.")
        }
        mutate(in: run.id) { state in
            state.updateOperated(task.id) { operated in
                var publication = operated.publication ?? TaskPublication()
                publication.conditionsHeld = sha
                operated.publication = publication
            }
        }
        _ = workspace.flush()
    }

    private func refuseVetoed(_ call: ToolCall, in run: OperatorRun, why: String?) async throws -> Never {
        if call.tool == "finish_task" {
            let key = try task(call, in: run).operated?.key ?? "the task"
            let reason = Self.asSentence(why ?? "it gave no reason")
            refuseMerge(call, in: run, problem: "The Oracle judged that the conditions to merge don’t hold yet: \(reason)")
            throw ToolRefusal("The Oracle judged that the conditions to merge \(key) don’t hold yet: \(reason) "
                              + "AiTerm recorded it on the task; call finish_task again once they hold.")
        }
        let filing = await noteFind(call, in: run, why: why ?? "The Oracle judged it off-brief.")
        throw ToolRefusal("The Oracle judged this off-brief. AiTerm noted it for the summary" + Self.ending(filing))
    }

    private func proceedUnchallenged(_ call: ToolCall, in run: OperatorRun, askedSHA: String?) throws {
        try approve(call, in: run, askedSHA: askedSHA)
        let task = try task(call, in: run)
        let why = "The Oracle didn’t answer, so the merge went ahead unchallenged."
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) {
                let key = "unchallenged-merge-\(task.id)-\(askedSHA ?? "")"
                guard !$0.decisions.contains(where: { $0.key == key }) else { return }
                $0.decisions.append(OperatorDecision(key: key, text: "Merged \(task.title) unchallenged.", task: task.id,
                                                     at: ports.now(), challenge: "unchallenged", why: why))
            }
        }
    }

    private func refuseUnanswered(_ call: ToolCall, in run: OperatorRun) async throws -> Never {
        let filing = await noteFind(call, in: run, why: "The Oracle didn’t answer in time.")
        throw ToolRefusal("The Oracle didn’t answer in time. AiTerm noted it for the summary" + Self.ending(filing))
    }

    /// `text` ending as a sentence does.
    static func asSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [".", "!", "?"].contains(trimmed.last.map(String.init) ?? "") ? trimmed : trimmed + "."
    }

    /// Why the Oracle kept a merge from happening, on the task's publication, where its card reads it;
    /// the operator's next finish_task clears it.
    private func refuseMerge(_ call: ToolCall, in run: OperatorRun, problem: String) {
        guard let task = try? task(call, in: run) else { return }
        mutate(in: run.id) { state in
            state.updateOperated(task.id) { operated in
                var publication = operated.publication ?? TaskPublication()
                publication.mergeRefusal = problem
                publication.conditionsHeld = nil
                operated.publication = publication
            }
        }
        _ = workspace.flush()
    }

    private func vetoPendingAnswer(_ call: ToolCall, _ id: String, in run: OperatorRun) throws -> JSONValue {
        if call.tool == "finish_task" {
            let key = try task(call, in: run).operated?.key ?? "the task"
            return ["challenged": true, "challengeId": .string(id), "pending": true,
                    "note": .string("Nothing was done yet. The Oracle is still judging whether the conditions to merge \(key) hold: call finish_task again with this challengeId in a little while.")]
        }
        return ["challenged": true, "challengeId": .string(id), "pending": true,
                "note": "Nothing was added yet. The Oracle is still judging this addition: call create_task again with this challengeId in a little while."]
    }

    /// The acting call's answer, kept with its challenge and saved before the reply goes: a reply lost
    /// after this is answered again from the record (spec §11). Nothing for a call that carried no
    /// challenge of its tool, or whose challenge has not been read.
    func recordActed(_ call: ToolCall, in run: UUID, answer: JSONValue) {
        guard let id = call.optionalString("challengeId") else { return }
        let invocation = Self.invocation(call), result = Self.json(answer)
        var acted = false
        mutate(in: run) { state in
            state.updateRun(id: run) { run in
                guard let i = run.challenges.firstIndex(where: { $0.id == id && $0.tool == call.tool }),
                      [.delivered, .unchallenged].contains(run.challenges[i].stage) else { return }
                run.challenges[i].stage = .acted
                run.challenges[i].actedArguments = invocation
                run.challenges[i].result = result
                acted = true
            }
        }
        if acted, !workspace.flush() {
            Log.workspace.error("A challenged call's answer could not be saved; a repeat after a restart is refused instead of replayed")
        }
    }

    /// A call's arguments as one string, keys sorted, its `challengeId` and `challengeReply` left out:
    /// two calls are the same invocation when these are equal.
    static func invocation(_ call: ToolCall) -> String {
        var arguments = call.arguments.objectValue ?? [:]
        arguments["challengeId"] = nil
        arguments["challengeReply"] = nil
        return json(.object(arguments))
    }

    private func updateChallenge(_ id: String, in run: UUID, _ change: (inout ChallengeRecord) -> Void) {
        mutate(in: run) { state in
            state.updateRun(id: run) { run in
                if let i = run.challenges.firstIndex(where: { $0.id == id }) { change(&run.challenges[i]) }
            }
        }
    }

    /// The critique and the reply, in the decisions log the overview shows; `objection` when the Operator
    /// kept its act against the critique.
    private func record(_ call: ToolCall, in run: OperatorRun, challenge: String, reply: String, objection: String? = nil) {
        let taskId = (try? task(call, in: run))?.id
        let title = taskId.flatMap { state.task(id: $0)?.title } ?? "the plan"
        let words: String
        switch call.tool {
        case "mark_task": words = call.optionalString("outcome") == "accepted" ? "Accepted \(title)" : "Marked \(title) \(call.optionalString("outcome") ?? "done")"
        case "submit_plan": words = "Kept the plan"
        default: words = "Kept the choice for \(title)"
        }
        let capped = objection.map { $0.count > 300 ? String($0.prefix(299)) + "…" : $0 }
        let text = objection == nil ? "\(call.tool): \(reply)" : words + " despite the Oracle’s objection."
        let decision = OperatorDecision(key: "challenge-\(UUID().uuidString)", text: text, task: taskId,
                                        at: ports.now(), challenge: challenge, objection: capped)
        mutate(in: run.id) { $0.updateRun(id: run.id) { $0.decisions.append(decision) } }
    }

    private static func challengedAnswer(_ id: String, _ critique: String) -> JSONValue {
        ["challenged": true, "challengeId": .string(id), "critique": .string(critique),
         "note": "Nothing was done. Revise the call, or answer each point in challengeReply, and call again with this challengeId."]
    }

    private static func pendingAnswer(_ id: String) -> JSONValue {
        ["challenged": true, "challengeId": .string(id), "critique": .null, "pending": true,
         "note": "The second opinion is still thinking. Call again with this challengeId in a little while."]
    }

    /// The most of a critique kept and sent to the operator, in bytes.
    static let critiqueLimit = 8 * 1024
    static let truncationMarker = "\n[critique truncated]"

    /// A critique past the limit cut at a character boundary, with the marker saying so.
    static func capped(_ verdict: SecondOpinionRunner.Verdict) -> SecondOpinionRunner.Verdict {
        guard case .critique(let text) = verdict, text.utf8.count > critiqueLimit else { return verdict }
        var kept = ""
        for character in text {
            guard kept.utf8.count + String(character).utf8.count <= critiqueLimit else { break }
            kept.append(character)
        }
        return .critique(kept + truncationMarker)
    }

    /// Cancels the second opinions still running, as AiTerm quits. Their records stay running, so the next
    /// call with each id after a restart proceeds unchallenged, with that reason, rather than as an answer.
    func cancelChallenges() {
        for task in runningChallenges.values { task.cancel() }
    }

    /// JSON text, keys sorted, so the same value always reads the same.
    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The task's value, or nil once `budget` has passed: whichever comes first. The task itself goes on.
    static func first<Value: Sendable>(_ task: Task<Value, Never>, within budget: Duration) async -> Value? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let finish: @Sendable (Value?) -> Void = { verdict in
                if once.done.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: verdict) }
            }
            // A ready value cancels the timer, so no sleep outlasts it by the rest of the budget.
            let timer = Task { try? await Task.sleep(for: budget); finish(nil) }
            Task { finish(await task.value); timer.cancel() }
        }
    }
}

/// Whichever of two racing tasks finishes first resumes the continuation; the other is ignored.
private final class Once: Sendable { let done = Mutex(false) }
