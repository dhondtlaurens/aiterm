import Foundation

/// Auto-close's branch rule. Only the accepted local head may go; a host's merge at that head also
/// proves a squash merge, whose original commits need not be ancestors of the default branch.
public enum MergedBranchCheck {
    /// Deletes the local branch when the rule holds and `saveDeletion` has saved the task's record as
    /// saying so, so a record on disk never says a deleted branch was kept. False when anything fails.
    public static func delete(branch: String, acceptedSHA: String?, end: TaskEnd, publication: TaskPublication?,
                              kind: TaskKind = .task, path: String, git: any GitRunning,
                              saveDeletion: @MainActor () -> Bool) async -> Bool {
        guard kind != .review, let acceptedSHA, !acceptedSHA.isEmpty else { return false }
        let merged = (try? await BackgroundWork.run(on: TaskWorkflow.queue) {
            try isMerged(branch: branch, acceptedSHA: acceptedSHA, end: end, publication: publication, path: path, git: git)
        }) ?? false
        guard merged, await saveDeletion() else { return false }
        return (try? await BackgroundWork.run(on: TaskWorkflow.queue) { () throws -> Void in
            // The expected old value makes the deletion atomic with the head check. This handles
            // squash merges without asking git branch -d's narrower HEAD/upstream question.
            try git.run(["update-ref", "--no-deref", "-d", "refs/heads/" + branch, acceptedSHA], in: path)
            // What git branch -D also drops. A branch with no settings has none to remove.
            _ = try? git.run(["config", "--remove-section", "branch." + branch], in: path)
        }) != nil
    }

    private static func isMerged(branch: String, acceptedSHA: String, end: TaskEnd, publication: TaskPublication?,
                                 path: String, git: any GitRunning) throws -> Bool {
        guard [.merge, .mergeLocal].contains(end) else { return false }
        let repository = Repository(path, git: git), ref = "refs/heads/" + branch
        guard try git.ask(["rev-parse", "--verify", ref], in: path, none: [128])?
            .trimmingCharacters(in: .whitespacesAndNewlines) == acceptedSHA else { return false }
        let target = repository.defaultBranch()
        guard branch != target, try !repository.worktrees().contains(where: { $0.branch == branch }) else { return false }
        if publication?.merged == true && publication?.mergedHead == acceptedSHA { return true }
        if try git.ask(["merge-base", "--is-ancestor", acceptedSHA, "refs/heads/" + target], in: path, none: [1, 128]) != nil {
            return true
        }
        guard try repository.hasOrigin else { return false }
        // A stale remote-tracking ref cannot prove today's merge. A failed fetch keeps the branch.
        do { try repository.fetchFromOrigin(target, timeout: OperatorTiming.diffBaseFetchTimeout) }
        catch { return false }
        return try git.ask(["merge-base", "--is-ancestor", acceptedSHA, "refs/remotes/origin/" + target],
                           in: path, none: [1, 128]) != nil
    }
}
