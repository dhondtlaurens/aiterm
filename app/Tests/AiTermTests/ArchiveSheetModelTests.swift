import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor
@Suite struct ArchiveSheetModelTests {
    func entry(_ title: String, at: TimeInterval) -> ArchiveSearch.Entry {
        let task = TaskItem.make(project: UUID(), title: title, branch: "feat/\(title.lowercased())", worktreePath: "/w",
            createdAt: Date())
        return .init(archived: ArchivedTask(task: task, archivedAt: Date(timeIntervalSince1970: at)), projectName: "repo", provider: .git)
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
    @Test func movingReadsAndRanksOneConsistentArchive() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2)
        var reads = 0
        let model = ArchiveSheetModel(entries: { reads += 1; return [a, b] }, restore: { _ in }, remove: { _ in })
        model.move(by: 1)
        #expect(reads == 1)
        #expect(model.projection.highlighted == a)
    }

    /// Without a search the rows fall under their dates' groups, newest first, and ↑ ↓ pass straight over a heading;
    /// a search lists its best matches first, under no heading. A row's menu restores or removes its own row.
    @Test func theRowsGroupByDateWithoutASearch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now: TimeInterval = 1_791_800_000 // Mon 12 Oct 2026, 09:33 UTC
        let today = entry("Login", at: now - 3600), yesterday = entry("Header", at: now - 86_400),
            october = entry("Daemon", at: now - 9 * 86_400)
        var restored: [UUID] = [], removed: [UUID] = []
        let model = ArchiveSheetModel(entries: { [october, today, yesterday] }, restore: { restored.append($0) },
                                      remove: { removed.append($0) })
        model.now = { Date(timeIntervalSince1970: now) }
        let groups = model.groups(calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(groups.map(\.heading) == ["Today", "Yesterday", "October"])
        #expect(groups.map { $0.items.map(\.id) } == [[today.id], [yesterday.id], [october.id]])
        model.move(by: 1); #expect(model.projection.highlighted == yesterday, "past the Yesterday heading")
        model.query = "da"
        let found = model.groups(calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(found.map(\.heading) == [nil])
        #expect(found.first?.items.map(\.id) == [october.id])
        model.restore(today.id); model.remove(yesterday.id)
        #expect(restored == [today.id] && removed == [yesterday.id])
    }

}
