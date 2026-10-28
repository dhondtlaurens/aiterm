import Foundation
import AiTermCore

/// `check_goal`: the Operator's verdict on the broadcast's goal once every task is done, which the Oracle vetoes
/// (broadcast setup v2, The goal loop). Met completes the broadcast; not met plans what is missing while extra rounds are
/// left, and otherwise leaves it for you and completes.
extension OperatorToolHandler {
    /// What the Operator reads on a check while none is due.
    static let noGoalCheck = "No goal check is due: AiTerm wakes you for it once every task is done."

    /// Whether a goal check is due for `run`, whose every task is done (`RunScheduler.isComplete`): it has a goal not yet
    /// resolved, and either no check yet or a plan revision submitted since the last one.
    static func goalCheckIsDue(_ run: OperatorRun) -> Bool {
        guard run.goal != nil, run.goalOutcome == nil else { return false }
        return run.revisionAtLastCheck.map { run.planRevision > $0 } ?? true
    }

    /// Whether `check_goal` is taken now: while one is due, or as the check again once the last answer was planMore
    /// and no revision has been submitted since, when the Operator found nothing it could plan.
    static func acceptsGoalCheck(_ run: OperatorRun) -> Bool {
        run.goalCheckDue || isRecheck(run)
    }

    /// The last answer was planMore, and no revision has been submitted since.
    private static func isRecheck(_ run: OperatorRun) -> Bool {
        run.goal != nil && run.goalOutcome == nil && run.goalChecks.last?.met == false && run.revisionAtLastCheck == run.planRevision
    }

    /// A check_goal's arguments, refused when they can't be one: not met needs what is missing.
    static func goalVerdict(_ call: ToolCall) throws(ToolRefusal) -> (met: Bool, evidence: String, missing: [String]) {
        guard let met = call.optionalBool("met") else { throw ToolRefusal("check_goal needs `met`.") }
        let evidence = try call.string("evidence")
        let missing = (call.arguments["missing"]?.arrayValue ?? []).compactMap { OperatorCommand.said($0.stringValue) }
        guard met || !missing.isEmpty else {
            throw ToolRefusal("check_goal needs `missing` when the goal isn’t met: what is still to do, one line each.")
        }
        return (met, evidence, met ? [] : missing)
    }

    /// Whether `call` is the check `run` last acted on, again with its reply lost: it answers what it answered, and is
    /// neither a check again nor asked of the Oracle again.
    static func repeatsLastGoalCheck(_ call: ToolCall, in run: OperatorRun) -> Bool {
        guard let last = run.goalChecks.last, !run.goalCheckDue, run.revisionAtLastCheck == run.planRevision,
              let verdict = try? goalVerdict(call) else { return false }
        return (last.met, last.evidence, last.missing) == verdict
    }

    func checkGoal(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let verdict = try Self.goalVerdict(call)
        if Self.repeatsLastGoalCheck(call, in: run) { return Self.goalAnswer(run) }
        guard Self.acceptsGoalCheck(run), let goal = run.goal else { throw ToolRefusal(Self.noGoalCheck) }
        // The Oracle's yes is this call's (`vettedCalls`); without it the check acts unchallenged, not checked by the Oracle.
        let agreed: Bool? = vettedCalls.contains(Self.invocation(call)) ? true : nil
        // A round is left only for a check that is due: the check again, finding nothing to plan, takes none.
        let planMore = !verdict.met && run.goalCheckDue && run.roundsUsed < goal.extraRounds
        let check = GoalCheck(round: run.roundsUsed, met: verdict.met, evidence: verdict.evidence, missing: verdict.missing,
                              oracleAgreed: agreed, at: ports.now())
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) { run in
                run.goalChecks.append(check)
                run.goalCheckDue = false
                run.revisionAtLastCheck = run.planRevision
                if planMore {
                    run.roundsUsed += 1
                } else {
                    run.goalOutcome = agreed == nil ? .unchecked : verdict.met ? .met : .notMet
                    for line in verdict.missing where !run.leftForYou.contains(line) { run.leftForYou.append(line) }
                }
            }
        }
        return Self.goalAnswer(state.run(id: run.id) ?? run)
    }

    /// The answer to the last check `run` acted on: complete, planMore with the rounds left, or stopped with what went to you.
    private static func goalAnswer(_ run: OperatorRun) -> JSONValue {
        guard let last = run.goalChecks.last else { return .null }
        guard run.goalOutcome != nil else {
            return ["answer": "planMore", "roundsLeft": .int(max(0, (run.goal?.extraRounds ?? 0) - run.roundsUsed)),
                    "missing": .array(last.missing.map(JSONValue.string)),
                    "note": "Plan only what missing names: create_task, then submit_plan. If nothing can be planned, call check_goal again before submitting anything."]
        }
        guard !last.met else {
            return ["answer": "complete", "note": "The goal is met and the broadcast is complete: write its summary with write_summary."]
        }
        return ["answer": "stopped", "leftForYou": .array(last.missing.map(JSONValue.string)),
                "note": "The goal isn’t met and no more is planned: what is missing went to the person, and the broadcast is complete. Write its summary with write_summary."]
    }

    /// Each of `run`'s tasks as the Oracle judges the goal by: its accepted commit, its merge record, its diff stat and its
    /// verdicts, as JSON.
    func goalResults(in run: OperatorRun) async -> String {
        var results: [JSONValue] = []
        for task in state.tasks(inRun: run.id) {
            guard let operated = task.operated else { continue }
            var result: [String: JSONValue] = ["key": .string(operated.key), "title": .string(task.title),
                                               "state": .string(operated.state.rawValue), "end": .string(operated.end.rawValue)]
            if let sha = operated.acceptance?.resultSHA {
                result["acceptedSHA"] = .string(sha)
                if let stat = await diffStat(of: task, at: sha, in: run) { result["diffStat"] = .string(stat) }
            }
            if let publication = operated.publication, let merge = try? JSONValue(encoding: publication) { result["merge"] = merge }
            if !operated.reviewVerdicts.isEmpty, let verdicts = try? JSONValue(encoding: operated.reviewVerdicts) {
                result["verdicts"] = verdicts
            }
            results.append(.object(result))
        }
        return Self.json(.array(results))
    }

    /// `git diff --shortstat` from where the task's branch left its base to `sha`; nil without a worktree, or when git can't say.
    private func diffStat(of task: TaskItem, at sha: String, in run: OperatorRun) async -> String? {
        guard task.hasCheckout, let base = try? await diffBase(of: task, in: run) else { return nil }
        let git = ports.git, path = task.worktreePath
        return try? await BackgroundWork.run {
            try git.run(["diff", "--shortstat", "\(base)...\(sha)"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
