import Foundation

/// Auto-close's branch rule. Only the accepted local head may go; a host's merge at that head also
/// proves a squash merge, whose original commits need not be ancestors of the default branch.
public enum MergedBranchCheck {
    @discardableResult
    public static func delete(branch: String, acceptedSHA: String?, end: TaskEnd, publication: TaskPublication?,
                              path: String, git: any GitRunning) async throws -> Bool {
        try await BackgroundWork.run(on: TaskWorkflow.queue) {
            try deleteNow(branch: branch, acceptedSHA: acceptedSHA, end: end, publication: publication, path: path, git: git)
        }
    }

    private static func deleteNow(branch: String, acceptedSHA: String?, end: TaskEnd, publication: TaskPublication?,
                                  path: String, git: any GitRunning) throws -> Bool {
        guard [.merge, .mergeLocal].contains(end), let acceptedSHA, !acceptedSHA.isEmpty else { return false }
        let repository = Repository(path, git: git), ref = "refs/heads/" + branch
        guard try git.ask(["rev-parse", "--verify", ref], in: path, none: [128])?
            .trimmingCharacters(in: .whitespacesAndNewlines) == acceptedSHA else { return false }
        let target = repository.defaultBranch()
        guard branch != target, try !repository.worktrees().contains(where: { $0.branch == branch }) else { return false }
        var merged = publication?.merged == true && publication?.mergedHead == acceptedSHA
        if !merged {
            merged = try git.ask(["merge-base", "--is-ancestor", acceptedSHA, "refs/heads/" + target],
                                 in: path, none: [1, 128]) != nil
        }
        if !merged, try repository.hasOrigin {
            // A stale remote-tracking ref cannot prove today's merge. A failed fetch keeps the branch.
            do { try repository.fetchFromOrigin(target, timeout: OperatorTiming.diffBaseFetchTimeout) }
            catch { return false }
            merged = try git.ask(["merge-base", "--is-ancestor", acceptedSHA, "refs/remotes/origin/" + target],
                                 in: path, none: [1, 128]) != nil
        }
        guard merged else { return false }
        // The expected old value makes the final deletion atomic with the head check. This handles
        // squash merges without asking git branch -d's narrower HEAD/upstream question.
        try git.run(["update-ref", "--no-deref", "-d", ref, acceptedSHA], in: path)
        return true
    }
}
