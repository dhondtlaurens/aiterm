import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore

@MainActor
@Suite struct ArchiveSheetModelTests {
    func entry(_ title: String, at: TimeInterval) -> ArchiveSearch.Entry {
        let task = TaskItem(id: UUID(), projectId: UUID(), title: title, branch: "feat/\(title.lowercased())", worktreePath: "/w",
                            baseBranch: "main", jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: nil)
        return .init(archived: ArchivedTask(task: task, archivedAt: Date(timeIntervalSince1970: at)), projectName: "repo", provider: .git)
    }

    @Test func theHighlightStartsOnTheNewestWrapsAndResetsWhenTheQueryChanges() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2), c = entry("Gamma", at: 3)
        let model = ArchiveSheetModel(entries: { [a, b, c] }, restore: { _ in }, remove: { _ in })
        #expect(model.highlighted == c)
        model.move(by: 1); #expect(model.highlighted == b)
        model.move(by: -2); #expect(model.highlighted == a, "wraps")
        // "e" is in all three rows (their branch and project), so nothing but the reset puts the
        // highlight back on the newest: `a` would stay highlighted without it.
        model.query = "e"; #expect(model.rows.count == 3); #expect(model.highlighted == c, "the highlight resets with the query")
        model.query = "be"; #expect(model.highlighted == b)
        model.query = "zzz"; #expect(model.highlighted == nil)
    }

    @Test func escapeClearsASearchBeforeTheSheetCloses() {
        let model = ArchiveSheetModel(entries: { [] }, restore: { _ in }, remove: { _ in })
        model.query = "login"
        #expect(model.clearQuery())
        #expect(model.query.isEmpty)
        #expect(!model.clearQuery(), "nothing to clear: the sheet closes")
    }

    @Test func restoreAndRemoveActOnTheHighlightedRowOnly() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2)
        var restored: [UUID] = [], removed: [UUID] = []
        let model = ArchiveSheetModel(entries: { [a, b] }, restore: { restored.append($0) }, remove: { removed.append($0) })
        model.highlight(a.archived.id)
        #expect(model.restoreHighlighted())
        #expect(model.removeHighlighted())
        #expect(restored == [a.archived.id] && removed == [a.archived.id])
        model.query = "zzz"
        #expect(!model.restoreHighlighted())
    }

    @Test func theStatusCountsTheArchiveOrTheMatches() {
        let model = ArchiveSheetModel(entries: { [self.entry("Alpha", at: 1), self.entry("Beta", at: 2)] }, restore: { _ in }, remove: { _ in })
        #expect(model.status == "2 shelved")
        model.query = "alp"
        #expect(model.status == "1 of 2")
    }

    @Test func theArchiveOpensOnlyWithNoSheetUpAndAWorkspaceThatCanChange() throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        #expect(controller.canPresentArchive)
        controller.presentArchive()
        guard case .archive = controller.sheet else { Issue.record("no archive sheet"); return }
        #expect(!controller.canPresentArchive, "not over another sheet")
    }
}
