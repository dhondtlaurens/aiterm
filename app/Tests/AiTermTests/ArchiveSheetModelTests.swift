import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor
@Suite struct ArchiveSheetModelTests {
    func entry(_ title: String, at: TimeInterval) -> ShelfRow {
        let task = TaskItem.make(project: UUID(), title: title, branch: "feat/\(title.lowercased())", worktreePath: "/w",
            createdAt: Date())
        return .task(.init(archived: ArchivedTask(task: task, archivedAt: Date(timeIntervalSince1970: at)), projectName: "repo", provider: .git))
    }



    @Test func theHighlightStartsOnTheNewestWrapsAndResetsWhenTheQueryChanges() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2), c = entry("Gamma", at: 3)
        let model = ArchiveSheetModel(entries: { [a, b, c] }, restore: { _ in }, remove: { _ in })
        #expect(model.projection.highlighted == c)
        model.move(by: 1); #expect(model.projection.highlighted == b)
        model.move(by: -2); #expect(model.projection.highlighted == a, "wraps")
        // "e" is in all three rows (their branch and project), so nothing but the reset puts the
        // highlight back on the newest: `a` would stay highlighted without it.
        model.query = "e"; #expect(model.projection.rows.count == 3); #expect(model.projection.highlighted == c, "the highlight resets with the query")
        model.query = "be"; #expect(model.projection.highlighted == b)
        model.query = "zzz"; #expect(model.projection.highlighted == nil)
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
        model.highlight(a.id)
        #expect(model.performHighlighted())
        #expect(model.removeHighlighted())
        #expect(restored == [a.id] && removed == [a.id])
        model.query = "zzz"
        #expect(!model.performHighlighted())
    }



    @Test func theStatusCountsTheArchiveOrTheMatches() {
        let model = ArchiveSheetModel(entries: { [self.entry("Alpha", at: 1), self.entry("Beta", at: 2)] }, restore: { _ in }, remove: { _ in })
        #expect(model.projection.status == "2 archived")
        model.query = "alp"
        #expect(model.projection.status == "1 of 2")
    }

    @Test func theArchiveOpensOnlyWithNoSheetUpAndAWorkspaceThatCanChange() throws {
        let controller = AppController(preferences: .scratch())
        try controller.workspace.load()
        #expect(controller.canPresentArchive)
        controller.presentArchive()
        guard case .archive = controller.sheet else { Issue.record("no archive sheet"); return }
        #expect(!controller.canPresentArchive, "not over another sheet")
    }
    /// An ended broadcast is on the Archive, and Open puts its sheet in the Archive's place; the live one is not.


    /// Remove on an ended broadcast asks first, then forgets it; Cancel keeps it.


    @Test func movingReadsAndRanksOneConsistentArchive() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2)
        var reads = 0
        let model = ArchiveSheetModel(entries: { reads += 1; return [a, b] }, restore: { _ in }, remove: { _ in })
        model.move(by: 1)
        #expect(reads == 1)
        #expect(model.projection.highlighted == a)
    }

}
