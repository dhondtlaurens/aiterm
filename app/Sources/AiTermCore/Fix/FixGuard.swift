import Foundation

/// What AiTerm checks in the clone once the agent says it applied — never taking its word for it.
/// Each check is git's own answer: a stopped operation, `diff --check`'s leftover markers in the
/// branch that will land, a dirty tree, a branch that moved without being named, and a commit lost.
public enum FixGuard {
    public static let localOnlyLimit = 200

    /// `limit` is the most local-only commits a branch may have; tests pass a small one.
    public static func check(_ clone: FixClone, proposal: FixProposal, before: [String: String],
                             limit: Int = localOnlyLimit) throws(FixRefusal) {
        let git = clone.git, dir = clone.path
        do {
            if try operationInProgress(in: dir, git: git) { throw FixRefusal.operationInProgress }
            // The branch that lands, not HEAD: landing moves refs only, and the agent may have left HEAD elsewhere.
            let landing = try clone.tip(clone.branch)
            let markers = try leftoverMarkers(in: dir, since: clone.startTip, origin: clone.originTip, to: landing, git: git)
            if !markers.isEmpty { throw FixRefusal.conflictMarkers(markers) }
            if !(try git.run(["status", "--porcelain", "--untracked-files=no"], in: dir)).isEmpty { throw FixRefusal.uncommittedChanges }
            let after = try clone.branchTips()
            for (branch, tip) in before.sorted(by: { $0.key < $1.key }) where !proposal.moves.contains(branch) && after[branch] != tip {
                throw FixRefusal.movedOtherBranch(branch)
            }
            for branch in proposal.moves { try keepsCommits(clone, branch: branch, drops: Set(proposal.drops), limit: limit) }
        } catch let refusal as FixRefusal {
            throw refusal
        } catch {
            throw .cloneFailed(GitError.displayReason(of: error))
        }
    }

    static func operationInProgress(in dir: String, git: any GitRunning) throws -> Bool {
        let states = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer", "BISECT_LOG"]
        let paths = try git.run(["rev-parse", "--path-format=absolute"] + states.flatMap { ["--git-path", $0] }, in: dir)
        return paths.split(separator: "\n").contains { FileManager.default.fileExists(atPath: String($0)) }
    }

    /// Files of `tip` with a leftover conflict marker the fix added: flagged by `git diff --check`
    /// against `start` and — when there is an origin — against origin's tip too, so a line that
    /// arrived from origin (an RST `=======` underline) never blames the agent.
    static func leftoverMarkers(in dir: String, since start: String, origin: String?, to tip: String,
                                git: any GitRunning) throws -> [String] {
        var files = try flagged(from: start, to: tip, in: dir, git: git)
        if let origin { files.formIntersection(try flagged(from: origin, to: tip, in: dir, git: git)) }
        return files.sorted()
    }

    /// Files whose diff holds a leftover conflict marker, as `git diff --check` reports them
    /// (`<file>:<line>: leftover conflict marker`, exit 2). Whitespace findings are switched off:
    /// they are not wanted, and a big diff of them would fill the error's capped stdout first.
    private static func flagged(from base: String, to tip: String, in dir: String, git: any GitRunning) throws -> Set<String> {
        let off = "-trailing-space,-space-before-tab,-indent-with-non-tab,-tab-in-indent,-cr-at-eol,-blank-at-eof"
        let report: String
        do { report = try git.run(["-c", "core.quotePath=false", "-c", "core.whitespace=" + off, "diff", "--check", base, tip], in: dir) }
        catch let error as GitError where error.code == 2 && !error.timedOut { report = error.stdout }
        let suffix = ": leftover conflict marker"
        return Set(report.split(separator: "\n").compactMap { line -> String? in
            guard line.hasSuffix(suffix) else { return nil }
            let located = line.dropLast(suffix.count)   // `path:line`; the path may hold colons itself
            return located.lastIndex(of: ":").map { String(located[..<$0]) }
        })
    }

    /// Spec §7.2: every commit of the start tip that origin lacks is in the new tip, unless the plan
    /// named it in `drops`. “In” is by content first (`git cherry` compares patch ids), then by
    /// identity: resolving a conflict changes a commit's diff, so a rebased commit whose author,
    /// author date and subject a commit of the new tip still has — which a rebase keeps — is the same
    /// commit, resolved. Each such twin vouches for one commit, and only a twin origin does not have
    /// counts. A local merge commit that a rebase linearised away has no twin and is refused unless
    /// it is in `drops`.
    static func keepsCommits(_ clone: FixClone, branch: String, drops: Set<String>, limit: Int) throws {
        let git = clone.git, dir = clone.path, start = clone.startTip
        let new = try clone.tip(branch)
        // With an origin, the local-only commits are those past the merge base; without one, the
        // start tip's commits the new tip lacks — never the whole history.
        let lostRange: [String], twinRange: [String], cherry: [String]
        if let origin = clone.originTip {
            let base = try git.run(["merge-base", start, origin], in: dir)
            lostRange = [start, "^" + base]; twinRange = [new, "^" + origin]; cherry = ["cherry", new, start, base]
        } else {
            lostRange = [start, "^" + new]; twinRange = [new, "^" + start]; cherry = ["cherry", new, start]
        }
        let output = try git.run(["rev-list", "--count"] + lostRange, in: dir)
        guard let count = Int(output) else {
            throw GitError(args: ["rev-list", "--count"] + lostRange, code: 0, stderr: "git answered “\(output)” to a count")
        }
        guard count <= limit else { throw FixRefusal.tooManyCommits(branch, count: count) }
        // `git cherry <upstream> <head> [<limit>]`: “+ sha” is a commit of head with no equivalent in upstream.
        let lost = try git.run(cherry, in: dir).split(separator: "\n").filter { $0.hasPrefix("+ ") }
            .map { String($0.dropFirst(2)) }.filter { !drops.contains($0) }
        guard !lost.isEmpty else { return }
        var twins = try records(twinRange, in: dir, git: git).reduce(into: [String: Int]()) { $0[$1.identity, default: 0] += 1 }
        let identities = Dictionary(try records(["--no-walk=unsorted"] + lost, in: dir, git: git).map { ($0.sha, $0.identity) },
                                    uniquingKeysWith: { a, _ in a })
        for sha in lost {
            guard let identity = identities[sha], let left = twins[identity], left > 0 else { throw FixRefusal.droppedCommit(branch, sha: sha) }
            twins[identity] = left - 1
        }
    }

    /// Each commit of `revisions` with what a rebase keeps of it — author, author date and subject. Every
    /// record ends in a `.` field, so the whole-output trim of `GitRunner` cannot eat an empty subject's tab.
    private static func records(_ revisions: [String], in dir: String, git: any GitRunning) throws -> [(sha: String, identity: String)] {
        try git.run(["log", "--format=%H%x09%ae%x09%at%x09%s%x09."] + revisions, in: dir).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { return nil }
            return (String(fields[0]), fields[1..<(fields.count - 1)].joined(separator: "\t"))
        }
    }
}
