import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm

/// A task row is never wider than the sidebar gives it. Its badges are chips at their own width, so a
/// ticket, a merge request and a long `+1416 −1072` once outgrew the row and pushed the status mark out
/// of the pill; now the badge line gives up what does not fit (`TaskRowBadges.fits`).
@MainActor
struct TaskRowOverflowTests {
    @Test(arguments: [200, 240, 280] as [CGFloat])
    func theRowKeepsItsWidthWhateverItsBadges(width: CGFloat) throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "FE-1783 Dependency updates: patch", branch: "feat/fe-1783-dependency-updates",
                            worktreePath: "/wt", baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil,
                            firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w-1")
        let row = TaskRow(id: task.id, title: task.title, jiraKey: "FE-1783", jiraUrl: "https://j/FE-1783",
                          mr: MergeRequestRef(iid: 45, title: "Dependency updates", url: "https://gitlab.example.com/mr/45"),
                          branch: BranchLabel(name: task.branch, extra: 0, drifted: false, detail: ""), avatars: AvatarGroup(marks: [], overflow: 0), status: .idle,
                          diff: BaseDiff(base: "main", stat: DiffStat(added: 1416, removed: 1072)))
        let host = NSHostingController(rootView: TaskRowView(row: row, task: task, controller: controller))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
        #expect(size.width <= width, "the row asked for \(size.width) pt of \(width)")
    }
}
