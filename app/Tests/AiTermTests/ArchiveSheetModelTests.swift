import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor
@Suite struct ArchiveSheetModelTests {
    func entry(_ title: String, at: TimeInterval) -> ShelfRow {
        let task = TaskItem(id: UUID(), projectId: UUID(), title: title, branch: "feat/\(title.lowercased())", worktreePath: "/w",
                            baseBranch: "main", jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: nil)
        return .task(.init(archived: ArchivedTask(task: task, archivedAt: Date(timeIntervalSince1970: at)), projectName: "repo", provider: .git))
    }

    func broadcast(_ name: String, at: TimeInterval) -> ShelfRow {
        .broadcast(ShelvedBroadcast(runId: UUID(), name: name, asked: "Implement the sprint.", endedAt: Date(timeIntervalSince1970: at)))
    }

    @Test func theHighlightStartsOnTheNewestWrapsAndResetsWhenTheQueryChanges() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2), c = entry("Gamma", at: 3)
        let model = ArchiveSheetModel(entries: { [a, b, c] }, restore: { _ in }, open: { _ in }, remove: { _ in })
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
        let model = ArchiveSheetModel(entries: { [] }, restore: { _ in }, open: { _ in }, remove: { _ in })
        model.query = "login"
        #expect(model.clearQuery())
        #expect(model.query.isEmpty)
        #expect(!model.clearQuery(), "nothing to clear: the sheet closes")
    }

    @Test func restoreAndRemoveActOnTheHighlightedRowOnly() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2)
        var restored: [UUID] = [], removed: [UUID] = []
        let model = ArchiveSheetModel(entries: { [a, b] }, restore: { restored.append($0) }, open: { _ in }, remove: { removed.append($0) })
        model.highlight(a.id)
        #expect(model.performHighlighted())
        #expect(model.removeHighlighted())
        #expect(restored == [a.id] && removed == [a.id])
        model.query = "zzz"
        #expect(!model.performHighlighted())
    }

    @Test func aBroadcastRowOpensWhereATaskRowRestores() {
        let task = entry("Alpha", at: 1), ended = broadcast("Sprint 42", at: 2)
        var restored: [UUID] = [], opened: [UUID] = [], removed: [UUID] = []
        let model = ArchiveSheetModel(entries: { [task, ended] }, restore: { restored.append($0) }, open: { opened.append($0) },
                                      remove: { removed.append($0) })
        #expect(model.projection.highlighted == ended && model.projection.primaryTitle == "Open")
        #expect(model.performHighlighted())
        #expect(opened == [ended.id] && restored.isEmpty, "⌘↩ opens a broadcast, never restores it")
        #expect(model.removeHighlighted())
        #expect(removed == [ended.id])
        model.highlight(task.id)
        #expect(model.projection.primaryTitle == "Restore")
        #expect(model.performHighlighted())
        #expect(restored == [task.id] && opened == [ended.id])
    }

    @Test func theStatusCountsTheArchiveOrTheMatches() {
        let model = ArchiveSheetModel(entries: { [self.entry("Alpha", at: 1), self.entry("Beta", at: 2)] }, restore: { _ in }, open: { _ in }, remove: { _ in })
        #expect(model.projection.status == "2 shelved")
        model.query = "alp"
        #expect(model.projection.status == "1 of 2")
    }

    @Test func theArchiveOpensOnlyWithNoSheetUpAndAWorkspaceThatCanChange() throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        #expect(controller.canPresentArchive)
        controller.presentArchive()
        guard case .archive = controller.sheet else { Issue.record("no archive sheet"); return }
        #expect(!controller.canPresentArchive, "not over another sheet")
    }
    /// An ended broadcast is on the Shelf, and Open puts its sheet in the Shelf's place; the live one is not.
    @Test func anEndedBroadcastOpensFromTheShelfInItsPlace() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let ended = OperatorUIFixtures.run(name: "Sprint 41", state: .stopped), live = OperatorUIFixtures.run(name: "Sprint 42")
        controller.workspace.mutate { $0.runs = [ended, live] }
        controller.presentArchive()
        guard case .archive(let model) = controller.sheet else { Issue.record("no archive sheet"); return }
        #expect(model.projection.rows.map(\.id) == [ended.id])
        #expect(model.performHighlighted())
        guard case .shelvedBroadcast(let id)? = controller.sheet else { Issue.record("no shelved broadcast"); return }
        #expect(id == ended.id && controller.sheet?.id == "shelved-\(ended.id)")
        controller.sheet = nil
        controller.presentShelved(run: live.id)
        #expect(controller.sheet == nil, "the live broadcast opens from the sidebar, not the Shelf")
    }

    /// Remove on an ended broadcast asks first, then forgets it; Cancel keeps it.
    @Test func removingAShelvedBroadcastAsksThenForgetsIt() async throws {
        let prompter = ScriptedPrompter(answering: "Cancel", "Remove")
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let ended = OperatorUIFixtures.run(name: "Sprint 41", state: .stopped)
        controller.workspace.mutate { $0.runs = [ended] }
        #expect(await !controller.confirmRemoveShelved(ended.id))
        #expect(controller.state.runs.map(\.id) == [ended.id], "cancelled")
        let asked = try #require(prompter.asked.first)
        #expect(asked == AlertPrompt(message: "Remove “Sprint 41” from the Shelf?",
                                     detail: "Its activity log and summary are deleted. Its tasks stay where they are.",
                                     buttons: ["Remove", "Cancel"], defaultDeletes: true))
        #expect(await controller.confirmRemoveShelved(ended.id))
        #expect(controller.state.runs.isEmpty)
    }

    @Test func movingReadsAndRanksOneConsistentArchive() {
        let a = entry("Alpha", at: 1), b = entry("Beta", at: 2)
        var reads = 0
        let model = ArchiveSheetModel(entries: { reads += 1; return [a, b] }, restore: { _ in }, open: { _ in }, remove: { _ in })
        model.move(by: 1)
        #expect(reads == 1)
        #expect(model.projection.highlighted == a)
    }

}
