import Foundation
import AiTermCore

/// `record_review`: a review tab's verdict on one commit of its task, kept on the task (`ReviewVerdict`).
extension OperatorToolHandler {
    func recordReview(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), key = try call.string("key")
        if let answer = try Self.recordedVerdict(key, on: task) { return answer }
        let operated = try self.operated(task, in: run)
        let tab = try call.string("tab")
        guard let reviewTab = operated.extraTabs.first(where: { $0.key == tab && $0.role == .review }) else {
            throw ToolRefusal("\(tab) is not a review tab of \(operated.key).")
        }
        guard let passed = call.optionalBool("passed") else { throw ToolRefusal("passed must be true or false.") }
        let critical = try reviewCount("critical", in: call), important = try reviewCount("important", in: call)
        let minor = try reviewCount("minor", in: call), round = try reviewCount("round", in: call, minimum: 1)
        let rounds = try call.arguments["rounds"].flatMap { $0 == .null ? nil : try reviewCount("rounds", in: call) }
        let summary = try call.string("summary")
        guard summary.rangeOfCharacter(from: .newlines) == nil else { throw ToolRefusal("summary must be one line.") }
        let ref = try call.string("sha")
        guard task.hasCheckout else { throw ToolRefusal("\(operated.key) has no worktree in which to check its branch.") }
        let git = ports.git, path = task.worktreePath, branch = task.branch
        let read = await BackgroundWork.run {
            Result {
                let sha = try git.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], in: path)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try git.run(["merge-base", "--is-ancestor", sha, "refs/heads/" + branch], in: path)
                return sha
            }
        }
        guard let current = state.task(id: task.id), current.operated?.runId == run.id,
              let fresh = state.run(id: run.id) else { throw ToolRefusal("This task is no longer in this broadcast.") }
        // A call with this key may have finished while git was reading, even if this read failed.
        if let answer = try Self.recordedVerdict(key, on: current) { return answer }
        guard !fresh.hasEnded else { throw ToolRefusal("This broadcast has ended; its tools no longer act.") }
        try recheck(task)
        guard current.branch == branch, current.worktreePath == path, current.projectId == task.projectId,
              current.operated?.extraTabs.first(where: { $0.key == tab }) == reviewTab else {
            throw ToolRefusal("This task or review tab changed while AiTerm was checking it; read run_status and try again.")
        }
        let sha: String
        do { sha = try read.get() }
        catch {
            throw ToolRefusal("sha must name a commit on \(operated.key)'s branch, \(task.branch).")
        }
        let verdict = ReviewVerdict(tab: tab, sha: sha, passed: passed, round: round, rounds: rounds, critical: critical,
                                    important: important, minor: minor, summary: summary, at: ports.now(), key: key)
        let answer = try Self.verdictAnswer((current.operated?.reviewVerdicts ?? []) + [verdict])
        mutate(in: run.id) { $0.updateOperated(task.id) { $0.reviewVerdicts.append(verdict) } }
        return answer
    }

    private static func recordedVerdict(_ key: String, on task: TaskItem) throws -> JSONValue? {
        let verdicts = task.operated?.reviewVerdicts ?? []
        guard let index = verdicts.firstIndex(where: { $0.key == key }) else { return nil }
        return try verdictAnswer(Array(verdicts[...index]))
    }

    private func reviewCount(_ field: String, in call: ToolCall, minimum: Int = 0) throws -> Int {
        guard let value = call.arguments[field]?.intValue, value >= minimum else {
            throw ToolRefusal("\(field) must be an integer of at least \(minimum).")
        }
        return value
    }

    private static func verdictAnswer(_ verdicts: [ReviewVerdict]) throws -> JSONValue {
        ["verdicts": try JSONValue(encoding: verdicts), "failed": .int(verdicts.filter { !$0.passed }.count)]
    }
}
