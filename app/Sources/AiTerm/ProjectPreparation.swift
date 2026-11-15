import Foundation
import AiTermCore

struct ProjectPreparation: Sendable {
    var project: Project
    var worktrees: [Worktree]
    var defaultBranch: String?
    var importIssue: OperationIssue?
    var pickedPath: String
    init(project: Project, worktrees: [Worktree] = [], defaultBranch: String? = nil,
         importIssue: OperationIssue? = nil, pickedPath: String? = nil) {
        self.project = project; self.worktrees = worktrees; self.defaultBranch = defaultBranch
        self.importIssue = importIssue; self.pickedPath = pickedPath ?? project.path
    }
    var canImport: Bool { defaultBranch != nil && importIssue == nil && !worktrees.isEmpty }
}
