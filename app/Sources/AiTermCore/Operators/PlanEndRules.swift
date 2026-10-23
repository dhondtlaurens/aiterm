import Foundation

/// What a plan's ends must agree on. Every end is allowed on its own: commit, draft MR, merge,
/// local merge. A stacked task's request targets its parent's branch, so a task that ends in a request
/// builds only on a parent whose own end pushes that branch (a local merge pushes nothing); one that
/// ends in a merge, through the request or local, merges after its parent, so not on a draft.
public enum PlanEndRules {
    public static func refusal(for tasks: [TaskItem]) -> String? {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for task in tasks {
            guard let operated = task.operated, let parentId = operated.stackedOn,
                  let parent = byId[parentId]?.operated else { continue }
            switch (operated.end, parent.end) {
            case (.draftMR, .commit), (.merge, .commit):
                let end = operated.end == .merge ? "a merge" : "a draft MR"
                return "\(operated.key) ends in \(end) but builds on \(parent.key), which ends in a commit: its request would target a branch that is never pushed. Give \(parent.key) a draft MR or a merge too, or end \(operated.key) in a commit."
            case (.draftMR, .mergeLocal), (.merge, .mergeLocal):
                let end = operated.end == .merge ? "a merge" : "a draft MR"
                return "\(operated.key) ends in \(end) but builds on \(parent.key), which ends in a local merge: its request would target a branch that is never pushed. Give \(parent.key) a draft MR or a merge, or end \(operated.key) in a local merge too."
            case (.merge, .draftMR), (.mergeLocal, .draftMR):
                let end = operated.end == .merge ? "a merge" : "a local merge"
                return "\(operated.key) ends in \(end) but builds on \(parent.key), which ends in a draft MR and never merges. Merge \(parent.key) too, or end \(operated.key) in a draft MR."
            default:
                continue
            }
        }
        return nil
    }
}
