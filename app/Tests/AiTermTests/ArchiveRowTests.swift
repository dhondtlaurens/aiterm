import Foundation
import Testing
@testable import AiTerm
import AiTermCore
@testable import AiTermTestSupport

@MainActor struct ArchiveRowTests {
    @Test func theRequestURLDecidesItsHost() {
        let task = TaskItem.make(project: UUID(), title: "Review", branch: "feat/review", worktreePath: "/w", kind: .review,
            mr: MergeRequestRef(iid: 12, title: "Fix", url: "https://github.com/org/repo/pull/12"), createdAt: Date())
        let row = ArchiveRow(entry: .init(archived: .init(task: task, archivedAt: Date()), projectName: "Repo", provider: .gitlab), commands: [])
        #expect(row.badges.mrHost == .gitHub)
        #expect(row.badges.mr == "#12")
    }
}
