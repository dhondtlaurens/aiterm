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
        let rounds = try call.arguments["rounds"].flatMap { $0 == .null ? nil : try reviewCount("rounds", in: call, minimum: 1) }
        if let rounds, round > rounds { throw ToolRefusal("round must not exceed rounds.") }
        let summary = try call.string("summary")
        guard summary.rangeOfCharacter(from: .newlines) == nil else { throw ToolRefusal("summary must be one line.") }
        let ref = try call.string("sha")
        // A ref such as HEAD or main would record whatever it names now, not the commit the tab reviewed.
        guard (4...64).contains(ref.count), ref.allSatisfy(\.isHexDigit) else {
            throw ToolRefusal(Self.notASHA)
        }
        guard task.hasCheckout else { throw ToolRefusal("\(operated.key) has no worktree in which to check its branch.") }
        let git = ports.git, path = task.worktreePath, branch = task.branch, baseBranch = task.baseBranch
        let read = await BackgroundWork.run {
            Result { () throws -> ReviewedCommit in
                guard let sha = try git.ask(["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"], in: path, none: [1])?
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return .offBranch }
                // A branch or tag named in hex resolves before the commit it spells.
                guard sha.hasPrefix(ref.lowercased()) else { return .notASHA }
                guard try git.ask(["merge-base", "--is-ancestor", sha, "refs/heads/" + branch], in: path, none: [1]) != nil else {
                    return .offBranch
                }
                // Below the fork point the commit is the base's, not the task's: here or on origin.
                let base = baseBranch.isEmpty ? Repository(path, git: git).defaultBranch() : baseBranch
                let holders = try git.run(["for-each-ref", "--contains", sha, "--format=%(refname)",
                                           "refs/heads/" + base, "refs/remotes/origin/" + base], in: path)
                return holders.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .commit(sha) : .onBase(base)
            }
        }
        guard let current = state.task(id: task.id), current.operated?.runId == run.id,
              let fresh = state.run(id: run.id) else { throw ToolRefusal("This task is no longer in this broadcast.") }
        // A call with this key may have finished while git was reading, even if this read failed.
        if let answer = try Self.recordedVerdict(key, on: current) { return answer }
        guard !fresh.hasEnded else { throw ToolRefusal.ended }
        try recheck(task)
        guard current.branch == branch, current.worktreePath == path, current.projectId == task.projectId,
              let now = current.operated?.extraTabs.first(where: { $0.key == tab }),
              now.role == reviewTab.role, now.agent == reviewTab.agent else {
            throw ToolRefusal("This task or review tab changed while AiTerm was checking it; read run_status and try again.")
        }
        let sha: String
        do {
            switch try read.get() {
            case .commit(let commit): sha = commit
            case .notASHA: throw ToolRefusal(Self.notASHA)
            case .offBranch: throw ToolRefusal("sha must name a commit on \(operated.key)'s branch, \(task.branch).")
            case .onBase(let base): throw ToolRefusal("sha must be one of \(operated.key)'s own commits, not one already on \(base).")
            }
        } catch let refusal as ToolRefusal {
            throw refusal
        } catch {
            throw ToolRefusal("AiTerm couldn't read \(operated.key)'s branch; try again. \(error.localizedDescription)")
        }
        let verdict = ReviewVerdict(tab: tab, sha: sha, passed: passed, round: round, rounds: rounds, critical: critical,
                                    important: important, minor: minor, summary: summary, at: ports.now(), key: key)
        let answer = try Self.verdictAnswer((current.operated?.reviewVerdicts ?? []) + [verdict])
        mutate(in: run.id) { $0.updateOperated(task.id) { $0.reviewVerdicts.append(verdict) } }
        return answer
    }

    /// What git says of the commit a verdict names.
    private enum ReviewedCommit { case commit(String), notASHA, offBranch, onBase(String) }

    private static let notASHA = "sha must be a commit SHA, not a branch name or revision expression."

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
