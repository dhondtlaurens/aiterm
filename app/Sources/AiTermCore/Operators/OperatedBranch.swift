import Foundation

/// The branch of a task an operator creates: `<type>/<ticket>-<title>` as New Task names one. A
/// ticket the operator splits into several tasks — keys `PLUTO-231/api`, `PLUTO-231/ui` — or two
/// titles that slug alike take the first of `-2`, `-3`… no other branch has, so every task gets a
/// worktree and a branch of its own.
public enum OperatedBranch {
    public static func name(ticket: String?, title: String, type: BranchType = .feat, taken: Set<String>) -> String {
        let base = "\(type.rawValue)/" + BranchNaming.branchSlug(key: ticket, summary: title)
        var candidate = base, n = 1
        while taken.contains(candidate) { n += 1; candidate = "\(base)-\(n)" }
        return candidate
    }

    /// Every branch name in use for `project`: its tasks' and its repository's own (local and on origin).
    public static func taken(in state: AppState, project: UUID, repositoryBranches: [String]) -> Set<String> {
        Set(state.tasks.filter { $0.projectId == project }.map(\.branch)).union(repositoryBranches)
    }
}
