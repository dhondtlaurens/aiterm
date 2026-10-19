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
    /// With the Oracle on, a plan, a verdict on a task, and a message that answers a worker's question
    /// are challenged, as round 1's Healthy doubt did; with it off, nothing is.
    static func isChallenged(_ call: ToolCall, oracleIsOn: Bool, answersQuestion: Bool) -> Bool {
        guard oracleIsOn else { return false }
        switch call.tool {
        case "submit_plan": return true
        case "mark_task": return ["accepted", "blocked", "failed"].contains(call.optionalString("outcome") ?? "")
        case "message_task": return answersQuestion
        default: return false
        }
    }

    /// Nil: the call takes effect. Otherwise what the operator reads instead.
    func challengeGate(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue? {
        let opinion = run.profile.oracle
        // A call naming a challenge of its tool is that challenge's, whatever the Oracle's switch or the worker's tab say now: the
        // worker may have started working since, and the acting call repeated must still replay, not act again.
        let named = call.optionalString("challengeId").flatMap { id in
            state.run(id: run.id)?.challenges.first { $0.id == id && $0.tool == call.tool }
        }
        if named == nil, !Self.isChallenged(call, oracleIsOn: opinion.isOn, answersQuestion: answersQuestion(call, in: run)) { return nil }
        if let id = call.optionalString("challengeId") {
            guard let kept = named else {
                throw ToolRefusal("No challenge \(id) for \(call.tool) here; call again without challengeId.")
            }
            guard !actingChallenges.contains(id) else {
                throw ToolRefusal("Challenge \(id) is already acting on \(call.tool); call again for its result.")
            }
            let reply = call.optionalString("challengeReply")
            switch kept.stage {
            case .acted:
                // The acting call again — its reply lost, or AiTerm restarted since: what it answered, and nothing more.
                guard kept.actedArguments == Self.invocation(call), let result = kept.result,
                      let answer = try? JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)) else {
                    throw ToolRefusal("Challenge \(id) has already acted on \(call.tool). Call again without challengeId for another change.")
                }
                return answer
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
                record(call, in: run, challenge: kept.critique ?? "", reply: reply ?? "revised the call")
                actingChallenges.insert(id)
                return nil
            case .unchallenged:
                record(call, in: run, challenge: "unchallenged: \(kept.unchallengedReason ?? "")", reply: reply ?? "proceeded")
                actingChallenges.insert(id)
                return nil
            }
        }
        let id = UUID().uuidString
        mutate(in: run.id) { $0.updateRun(id: run.id) { $0.challenges.append(ChallengeRecord(id: id, tool: call.tool, askedAt: ports.now())) } }
        let runner = ports.secondOpinion, folder = OperatorCommand.runFolder(run.id, home: ports.home)
        let projects = run.projectIds.compactMap(state.project(id:)).map(\.path)
        let prompt = ChallengeLaunch.prompt(tool: call.tool, arguments: Self.json(call.arguments),
                                            status: Self.json(currentStatus(of: run).flatMap { try? JSONValue(encoding: $0) } ?? .null),
                                            instructions: run.profile.instructions)
        // The runner turns every thrown error, a cancellation included, into `.unchallenged`; a challenge
        // cancelled (AiTerm quitting) is not an answer, so it settles as nil, and its record stays `.running`.
        let challenge = Task { () -> SecondOpinionRunner.Verdict? in
            let verdict = await runner.challenge(opinion, prompt: prompt, runFolder: folder, projects: projects)
            return Task.isCancelled ? nil : Self.capped(verdict)
        }
        // Kept for the operator's next call, when it outlasts this one's reply.
        let settled = Task { [weak self] in
            let verdict = await withTaskCancellationHandler { await challenge.value } onCancel: { challenge.cancel() }
            guard let self else { return }
            runningChallenges[id] = nil
            guard let verdict, state.run(id: run.id)?.challenges.first(where: { $0.id == id })?.stage == .running else { return }
            updateChallenge(id, in: run.id) { kept in
                switch verdict {
                case .critique(let critique): kept.stage = .ready; kept.critique = critique
                case .unchallenged(let reason): kept.stage = .unchallenged; kept.unchallengedReason = reason
                }
            }
        }
        runningChallenges[id] = settled
        lastChallenge = settled
        switch await Self.first(challenge, within: ports.challengeReplyBudget) {
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

    /// A message answers a worker's question when the worker's turn has ended — no prompt open is
    /// `message_task`'s own check — rather than steering it mid-turn.
    private func answersQuestion(_ call: ToolCall, in run: OperatorRun) -> Bool {
        guard call.tool == "message_task", let task = try? task(call, in: run), let tab = workerTab(of: task) else { return false }
        return tab.state != .working
    }

    private func updateChallenge(_ id: String, in run: UUID, _ change: (inout ChallengeRecord) -> Void) {
        mutate(in: run) { state in
            state.updateRun(id: run) { run in
                if let i = run.challenges.firstIndex(where: { $0.id == id }) { change(&run.challenges[i]) }
            }
        }
    }

    /// The critique and the reply, in the decisions log the overview shows.
    private func record(_ call: ToolCall, in run: OperatorRun, challenge: String, reply: String) {
        let taskId = (try? task(call, in: run))?.id
        let decision = OperatorDecision(key: "challenge-\(UUID().uuidString)", text: "\(call.tool): \(reply)", task: taskId,
                                        at: ports.now(), challenge: challenge)
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
    private static func json(_ value: JSONValue) -> String {
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
