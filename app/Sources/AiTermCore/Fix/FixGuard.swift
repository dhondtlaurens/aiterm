import Foundation

/// What AiTerm checks in the clone once the agent says it applied — never taking its word for it.
/// Each check is git's own answer: a stopped operation, `diff --check`'s leftover markers, a dirty
/// tree, a branch that moved without being named, and a commit lost by content.
public enum FixGuard {
    public static let localOnlyLimit = 200

    public static func check(_ clone: FixClone, proposal: FixProposal, before: [String: String]) throws(FixRefusal) {
        let git = clone.git, dir = clone.path
        do {
            if try operationInProgress(in: dir, git: git) { throw FixRefusal.operationInProgress }
            let markers = try leftoverMarkers(in: dir, since: clone.startTip, git: git)
            if !markers.isEmpty { throw FixRefusal.conflictMarkers(markers) }
            if !(try git.run(["status", "--porcelain", "--untracked-files=no"], in: dir)).isEmpty { throw FixRefusal.uncommittedChanges }
            let after = try clone.branchTips()
            for (branch, tip) in before.sorted(by: { $0.key < $1.key }) where !proposal.moves.contains(branch) && after[branch] != tip {
                throw FixRefusal.movedOtherBranch(branch)
            }
            for branch in proposal.moves { try keepsCommits(clone, branch: branch, drops: Set(proposal.drops)) }
        } catch let refusal as FixRefusal {
            throw refusal
        } catch {
            throw .cloneFailed(OperationIssue.reason(of: error))
        }
    }

    static func operationInProgress(in dir: String, git: any GitRunning) throws -> Bool {
        let paths = try git.run(["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge", "--git-path", "rebase-apply",
                                 "--git-path", "MERGE_HEAD", "--git-path", "CHERRY_PICK_HEAD"], in: dir)
        return paths.split(separator: "\n").contains { FileManager.default.fileExists(atPath: String($0)) }
    }

    /// Files whose diff from `start` holds a leftover conflict marker, as `git diff --check` reports
    /// them (`<file>:<line>: leftover conflict marker`).
    static func leftoverMarkers(in dir: String, since start: String, git: any GitRunning) throws -> [String] {
        let report: String
        do { report = try git.run(["diff", "--check", start, "HEAD"], in: dir) }
        catch let error as GitError where error.code == 2 && !error.timedOut { report = error.stdout }
        return Array(Set(report.split(separator: "\n").compactMap { line -> String? in
            guard line.hasSuffix("leftover conflict marker") else { return nil }
            return line.split(separator: ":").first.map(String.init)
        })).sorted()
    }

    /// Spec §7.2: every commit of the start tip that origin lacks is in the new tip, unless the plan
    /// named it in `drops`. “In” is by content first (`git cherry` compares patch ids), then by
    /// identity: resolving a conflict changes a commit's diff, so a rebased commit whose author,
    /// author date and subject a commit of the new tip still has — which a rebase keeps — is the same
    /// commit, resolved.
    static func keepsCommits(_ clone: FixClone, branch: String, drops: Set<String>) throws {
        let git = clone.git, dir = clone.path
        let new = try clone.tip(branch)
        let base = clone.originTip.flatMap { try? git.run(["merge-base", clone.startTip, $0], in: dir) }
        let range = base.map { [$0] } ?? []
        let count = Int(try git.run(["rev-list", "--count", clone.startTip] + range.map { "^" + $0 }, in: dir)) ?? 0
        guard count <= localOnlyLimit else { throw FixRefusal.tooManyCommits(branch, count: count) }
        // `git cherry <upstream> <head> [<limit>]`: “+ sha” is a commit of head with no equivalent in upstream.
        let lines = try git.run(["cherry", new, clone.startTip] + range, in: dir)
        let unmatched = lines.split(separator: "\n").filter { $0.hasPrefix("+ ") }.map { String($0.dropFirst(2)) }
        guard !unmatched.isEmpty else { return }
        let kept = Set(try identities(of: [new] + (clone.originTip.map { ["^" + $0] } ?? []), in: dir, git: git))
        for sha in unmatched where !drops.contains(sha) {
            if try !identities(of: ["-1", sha], in: dir, git: git).contains(where: kept.contains) {
                throw FixRefusal.droppedCommit(branch, sha: sha)
            }
        }
    }

    /// What a rebase keeps of a commit: its author, author date and subject, one string each.
    private static func identities(of revisions: [String], in dir: String, git: any GitRunning) throws -> [String] {
        try git.run(["log", "--format=%ae%x09%at%x09%s"] + revisions, in: dir).split(separator: "\n").map(String.init)
    }
}
