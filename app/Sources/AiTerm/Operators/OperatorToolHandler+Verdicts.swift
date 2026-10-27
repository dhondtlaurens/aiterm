import Foundation
import AiTermCore

/// `record_review`: a review tab's verdict on one commit of its task, kept on the task (`ReviewVerdict`).
extension OperatorToolHandler {
    func recordReview(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let task = try self.task(call, in: run), key = try call.string("key")
        let verdicts = task.operated?.reviewVerdicts ?? []
        if let index = verdicts.firstIndex(where: { $0.key == key }) {
            return try Self.verdictAnswer(Array(verdicts[...index]))
        }
        let operated = try self.operated(task, in: run)
        let tab = try call.string("tab")
        guard operated.extraTabs.contains(where: { $0.key == tab && $0.role == .review }) else {
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
        let sha: String
        do {
            sha = try ports.git.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], in: task.worktreePath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try ports.git.run(["merge-base", "--is-ancestor", sha, "refs/heads/" + task.branch], in: task.worktreePath)
        } catch {
            throw ToolRefusal("sha must name a commit on \(operated.key)'s branch, \(task.branch).")
        }
        let verdict = ReviewVerdict(tab: tab, sha: sha, passed: passed, round: round, rounds: rounds, critical: critical,
                                    important: important, minor: minor, summary: summary, at: ports.now(), key: key)
        let answer = try Self.verdictAnswer(verdicts + [verdict])
        mutate(in: run.id) { $0.updateOperated(task.id) { $0.reviewVerdicts.append(verdict) } }
        return answer
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
