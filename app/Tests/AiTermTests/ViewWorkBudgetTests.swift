import AppKit
import SwiftUI
import Testing
import Observation
import AiTermUI
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite(.serialized) struct ViewWorkBudgetTests {

    private func archivedRow(_ title: String, id: UUID = UUID(), at: Date) -> ArchiveSearch.Entry {
        let project = Project.make(id: UUID(uuidString: "E7A1C0DE-0000-4000-8000-000000000001")!, name: "Shop")
        let task = TaskItem.make(id: id, project: project.id, title: title)
        return .init(archived: ArchivedTask(task: task, archivedAt: at), projectName: project.name, provider: .git)
    }

    @Test func movingTheArchiveHighlightDoesNotRankAgain() {
        let rows = (0..<3).map { archivedRow("Task \($0)", at: Snapshots.clock.now.addingTimeInterval(-Double($0))) }
        let model = ArchiveSheetModel(entries: { rows }, restore: { _ in }, remove: { _ in })
        let meter = WorkMeter()
        WorkMeter.$current.withValue(meter) {
            _ = model.projection
            for _ in 0..<5 { model.move(by: 1); _ = model.projection }
        }
        print("Archive rankings for five highlight moves: \(meter[.archiveRank])")
        #expect(meter[.archiveRank] == 1, "baseline 11; final 1 for one opening and five highlight moves")
        #expect(model.projection.highlighted?.id == rows[2].id)
    }

    @Observable final class ArchiveSource {
        var rows: [ArchiveSearch.Entry]
        init(_ rows: [ArchiveSearch.Entry]) { self.rows = rows }
    }

    @Test func theArchiveRankingFollowsLiveReplacementRemovalAndQueryChanges() {
        let id = UUID(), now = Snapshots.clock.now
        let old = archivedRow("Old", id: id, at: now)
        let renamed = archivedRow("Renamed", id: id, at: now)
        let source = ArchiveSource([old])
        let model = ArchiveSheetModel(entries: { source.rows }, restore: { _ in }, remove: { _ in })
        #expect(model.projection.rows == [old])
        #expect(invalidates({ _ = model.projection }, by: { source.rows = [renamed] }), "a cache hit still observes the source")
        model.query = "renamed"
        #expect(model.projection.rows == [renamed])
        source.rows = []
        #expect(model.projection.rows.isEmpty && model.projection.highlighted == nil)
        source.rows = [old]
        #expect(model.projection.rows.isEmpty, "the query is still applied")
        model.query = "old"
        #expect(model.projection.rows == [old])
    }

    @Test func theArchiveMaterializesItsViewportAndKeepsHighlightScrolling() throws {
        let project = Project.make()
        let rows: [ArchiveSearch.Entry] = (0..<100).map { index in
            let date = Snapshots.clock.now.addingTimeInterval(-Double(index) * 60)

            let task = TaskItem.make(project: project.id, title: "Task \(index)")
            return .init(archived: ArchivedTask(task: task, archivedAt: date), projectName: project.name, provider: .git)
        }
        let model = ArchiveSheetModel(entries: { rows }, restore: { _ in }, remove: { _ in })
        model.now = { Snapshots.clock.now }
        let counter = RowBodyCounter()
        let host = testHost(ArchiveSheet(model: model).environment(\.rowBodyCounter, counter).environment(\.footerClock, Snapshots.clock),
                            size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host, describing: "the Archive rows") { !counter.counts.isEmpty }
        let initial = counter.counts.count
        print("Archive initial materialized rows: \(initial) of 100")
        // The first date heading (Today) takes the room of one row.
        #expect(initial == 7, "baseline 100; final 7 Archive rows under their heading in its sheet viewport")
        #expect(model.projection.rows.map(\.id) == rows.map(\.id))
        let scroll = try #require(host.firstDescendant(NSScrollView.self))
        model.highlight(rows.last!.id)
        settle(host, describing: "the last highlighted Archive row at the bottom") {
            counter.counts[rows.last!.id] != nil && scroll.documentVisibleRect.minY > 0
                && abs((scroll.documentView?.bounds.maxY ?? 0) - scroll.documentVisibleRect.maxY) <= 32
        }
        #expect(model.projection.highlighted?.id == rows.last?.id)
        #expect(counter.counts[rows.last!.id] != nil)
    }
}
