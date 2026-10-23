import Foundation
import Testing
@testable import AiTerm
import AiTermCore

@MainActor struct ArchiveRowTests {
    @Test func theRequestURLDecidesItsHost() {
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "Review", branch: "feat/review", worktreePath: "/w",
                            baseBranch: "main", jira: nil, kind: .review,
                            mr: MergeRequestRef(iid: 12, title: "Fix", url: "https://github.com/org/repo/pull/12"),
                            agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: nil)
        let row = ArchiveRow(entry: .init(archived: .init(task: task, archivedAt: Date()), projectName: "Repo", provider: .gitlab), date: "today")
        #expect(row.badges.mrHost == .gitHub)
        #expect(row.badges.mr == "#12")
    }
}
