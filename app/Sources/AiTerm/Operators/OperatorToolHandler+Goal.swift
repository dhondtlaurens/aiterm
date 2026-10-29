import Foundation
import AiTermCore

/// `check_goal`: the Operator's verdict on the broadcast's goal once every task is done, which the Oracle vetoes
/// (broadcast setup v2, The goal loop). Met completes the broadcast; not met plans what is missing while extra rounds are
/// left, and otherwise leaves it for you and completes.
extension OperatorToolHandler {
    /// What the Operator reads on a check while none is due.
    static let noGoalCheck = "No goal check is due: AiTerm wakes you for it once every task is done."

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

    /// The check `run` last acted on, when `call` is that check again with its reply lost: it answers what it answered,
    /// and is neither a check again nor asked of the Oracle again.
    static func repeatedGoalCheck(_ call: ToolCall, in run: OperatorRun) -> GoalCheck? {
        guard let last = run.goalChecks.last, !run.goalCheckDue, run.revisionAtLastCheck == run.planRevision,
              let verdict = try? goalVerdict(call), (last.met, last.evidence, last.missing) == verdict else { return nil }
        return last
    }

    func checkGoal(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let verdict = try Self.goalVerdict(call)
        if let last = Self.repeatedGoalCheck(call, in: run) { return Self.goalAnswer(run, last) }
        guard BroadcastCompletion.goalToCheck(run) != nil else { throw ToolRefusal(Self.noGoalCheck) }
        // The Oracle's yes is this call's (`vettedCalls`); without it the check acts unchallenged, not checked by the Oracle.
        let agreed: Bool? = vettedCalls.contains(Self.invocation(call)) ? true : nil
        let check = GoalCheck(round: run.roundsUsed, met: verdict.met, evidence: verdict.evidence, missing: verdict.missing,
                              oracleAgreed: agreed, at: ports.now())
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) { BroadcastCompletion.record(check, in: &$0) }
        }
        return Self.goalAnswer(state.run(id: run.id) ?? run, check)
    }

    /// The answer to `last`, the last check `run` acted on: complete, planMore with the rounds left, or stopped with what
    /// went to you.
    private static func goalAnswer(_ run: OperatorRun, _ last: GoalCheck) -> JSONValue {
        guard run.goalOutcome != nil else {
            return ["answer": "planMore", "roundsLeft": .int(max(0, (run.goal?.extraRounds ?? 0) - run.roundsUsed)),
                    "missing": .array(last.missing.map(JSONValue.string)),
                    "note": .string("Plan only what missing names: create_task, then submit_plan. If nothing can be planned, call check_goal "
                                    + "again before submitting anything, with new evidence saying why.")]
        }
        guard !last.met else {
            return ["answer": "complete", "note": "The goal is met and the broadcast is complete: write its summary with write_summary."]
        }
        return ["answer": "stopped", "leftForYou": .array(last.missing.map(JSONValue.string)),
                "note": "The goal isn’t met and no more is planned: what is missing went to the person, and the broadcast is complete. Write its summary with write_summary."]
    }

    /// The most a task's diff stat may take: every task is read at once, ahead of the Oracle's reply budget, inside the
    /// daemon's wait for the answer.
    nonisolated static let goalStatTimeout: TimeInterval = 5

    /// Each of `run`'s tasks as the Oracle judges the goal by: its accepted commit, its merge record, its diff stat and its
    /// verdicts, as JSON. The stats are read from local commits, nothing fetched, every task at once.
    func goalResults(in run: OperatorRun) async -> String {
        let tasks = state.tasks(inRun: run.id).compactMap { task in task.operated.map { (task, $0) } }
        let git = ports.git
        let reads = tasks.map { task, operated in
            (path: task.hasCheckout ? task.worktreePath : nil, sha: operated.acceptance?.resultSHA,
             base: RunScheduler.baseCommit(for: task.id, in: state) ?? task.baseBranch,
             merge: operated.publication?.merged == true ? operated.publication?.mergedSHA : nil)
        }
        let stats = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, read) in reads.enumerated() {
                guard let path = read.path, let sha = read.sha else { continue }
                group.addTask { await BackgroundWork.run { (i, Self.diffStat(git: git, in: path, base: read.base, sha: sha, merge: read.merge)) } }
            }
            var stats: [Int: String] = [:]
            for await (i, stat) in group { stats[i] = stat }
            return stats
        }
        let results = tasks.enumerated().map { i, entry -> JSONValue in
            let (task, operated) = entry
            var result: [String: JSONValue] = ["key": .string(operated.key), "title": .string(task.title),
                                               "state": .string(operated.state.rawValue), "end": .string(operated.end.rawValue)]
            if let sha = operated.acceptance?.resultSHA { result["acceptedSHA"] = .string(sha) }
            if let stat = stats[i] { result["diffStat"] = .string(stat) }
            if let publication = operated.publication { result["merge"] = Self.mergeRecord(publication) }
            if !operated.reviewVerdicts.isEmpty, let verdicts = try? JSONValue(encoding: operated.reviewVerdicts) {
                result["verdicts"] = verdicts
            }
            return .object(result)
        }
        return Self.json(.array(results))
    }

    /// What the Oracle reads of a task's publication: whether it merged, at which commit, and its request, with what became
    /// of it where the record can tell: merged, merged with another head, or left for you. Nil for one with neither a merge
    /// nor a request.
    private static func mergeRecord(_ publication: TaskPublication) -> JSONValue? {
        var record: [String: JSONValue] = [:]
        if publication.merged { record["merged"] = true }
        if let sha = publication.mergedSHA { record["mergedSHA"] = .string(sha) }
        if let url = publication.mergeRequestURL {
            var request: [String: JSONValue] = ["url": .string(url)]
            if publication.merged { request["state"] = "merged" }
            else if publication.mergedSHA != nil { request["state"] = "mergedWithAnotherHead" }
            else if publication.leftForYou { request["state"] = "leftForYou" }
            record["request"] = .object(request)
        }
        return record.isEmpty ? nil : .object(record)
    }

    /// `git diff --shortstat` of a task's work, from local commits: a merge commit here (two parents or more) against its
    /// first parent; anything else, a squash, a fast-forward or a merge that isn't here among it, from where its branch left
    /// `base` (its default branch when empty) to `sha`. Nil when git can't say, or the stat comes out empty.
    nonisolated static func diffStat(git: any GitRunning, in path: String, base: String, sha: String, merge: String?) -> String? {
        let parents = merge.flatMap { try? git.run(["rev-list", "--parents", "-n", "1", $0], in: path, timeout: goalStatTimeout) }
        let range = if let merge, (parents?.split(separator: " ").count ?? 0) > 2 { ["\(merge)^1", merge] }
                    else { ["\(base.isEmpty ? Repository(path, git: git).defaultBranch() : base)...\(sha)"] }
        let stat = (try? git.run(["diff", "--shortstat"] + range, in: path, timeout: goalStatTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stat?.isEmpty == false ? stat : nil
    }
}
