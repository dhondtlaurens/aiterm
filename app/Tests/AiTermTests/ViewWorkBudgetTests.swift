import AppKit
import SwiftUI
import Testing
import Observation
import AiTermUI
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite(.serialized) struct ViewWorkBudgetTests {
    private func entry(_ index: Int) -> ActivityEntry {
        ActivityEntry(at: Snapshots.clock.now.addingTimeInterval(-Double(index) * 60), tool: "mark_task", task: nil,
                      taskLabel: nil, arguments: [:], outcome: .ok, result: "ok", line: "Entry \(index)", reason: nil)
    }

    @Test func activityGroupingAndHeadingsAreBuiltOncePerAppend() {
        let presentation = ActivityPresentation(), meter = WorkMeter()
        var entries: [ActivityEntry] = []
        WorkMeter.$current.withValue(meter) {
            for index in 0..<3 {
                entries.insert(entry(index), at: 0)
                let first = presentation.layout(entries, now: Snapshots.clock.now, calendar: Snapshots.clock.calendar)
                let expanded = presentation.layout(entries, now: Snapshots.clock.now, calendar: Snapshots.clock.calendar)
                #expect(first.flatMap(\.entries) == entries && expanded.flatMap(\.entries) == entries)
                #expect(first.map(\.title) == ["Today"])
            }
        }
        print("Activity grouping / day titles: \(meter[.activityDays]) / \(meter[.activityDayTitle])")
        #expect(meter[.activityDays] == 3, "baseline 6; final 3 for three appends and a row expansion after each")
        #expect(meter[.activityDayTitle] == 3, "baseline 6; final 3")
    }

    @Test func activityValuesFollowReplacementCalendarAndMidnight() {
        let presentation = ActivityPresentation(), clock = Snapshots.clock
        let first = entry(0)
        #expect(presentation.layout([first], now: clock.now, calendar: clock.calendar).first?.title == "Today")
        var edited = first; edited.line = "Entry X"
        #expect(presentation.layout([edited], now: clock.now, calendar: clock.calendar).first?.entries == [edited])
        edited.arguments = ["changed": .bool(true)]
        #expect(presentation.layout([edited], now: clock.now, calendar: clock.calendar).first?.entries == [edited])
        var replaced = edited; replaced.at = clock.now.addingTimeInterval(-86_400)
        let changed = presentation.layout([replaced], now: clock.now, calendar: clock.calendar)
        #expect(changed.first?.entries == [replaced] && changed.first?.title != "Today")
        #expect(presentation.layout([first], now: clock.now.addingTimeInterval(86_400), calendar: clock.calendar).first?.title != "Today")
        var calendar = clock.calendar; calendar.timeZone = TimeZone(secondsFromGMT: -12 * 3600)!
        let shifted = presentation.layout([first], now: clock.now, calendar: calendar)
        #expect(shifted.first?.start == calendar.startOfDay(for: first.at))
        var french = clock.calendar; french.locale = Locale(identifier: "fr_FR")
        let localized = presentation.layout([replaced], now: clock.now, calendar: french)
        #expect(localized.first?.title == BroadcastActivityView.dayTitle(replaced.at, now: clock.now, calendar: french))
        #expect(localized.first?.title != changed.first?.title)
        #expect(presentation.layout([], now: clock.now, calendar: calendar).isEmpty)
    }

    @Test func movingTheShelfHighlightDoesNotRankAgain() {
        let rows = (0..<3).map { ShelfRow.broadcast(ShelvedBroadcast(runId: UUID(), name: "Run \($0)", asked: "Work",
                                                                   endedAt: Snapshots.clock.now.addingTimeInterval(-Double($0)))) }
        let model = ArchiveSheetModel(entries: { rows }, restore: { _ in }, open: { _ in }, remove: { _ in })
        let meter = WorkMeter()
        WorkMeter.$current.withValue(meter) {
            _ = model.projection
            for _ in 0..<5 { model.move(by: 1); _ = model.projection }
        }
        print("Shelf rankings for five highlight moves: \(meter[.archiveRank])")
        #expect(meter[.archiveRank] == 1, "baseline 11; final 1 for one opening and five highlight moves")
        #expect(model.projection.highlighted?.id == rows[2].id)
    }

    @Observable final class ShelfSource {
        var rows: [ShelfRow]
        init(_ rows: [ShelfRow]) { self.rows = rows }
    }

    @Test func theShelfRankingFollowsLiveReplacementRemovalAndQueryChanges() {
        let id = UUID(), now = Snapshots.clock.now
        let old = ShelfRow.broadcast(ShelvedBroadcast(runId: id, name: "Old", asked: "Work", endedAt: now))
        let renamed = ShelfRow.broadcast(ShelvedBroadcast(runId: id, name: "Renamed", asked: "Work", endedAt: now))
        let source = ShelfSource([old])
        let model = ArchiveSheetModel(entries: { source.rows }, restore: { _ in }, open: { _ in }, remove: { _ in })
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

    final class Jump: ObservableObject { @Published var target: UUID? }
    struct ActivityList: View {
        let entries: [ActivityEntry]
        @ObservedObject var jump: Jump
        var body: some View {
            ScrollViewReader { scroll in
                ScrollView { BroadcastActivityView(entries: entries) }
                    .onChange(of: jump.target) { _, id in if let id { scroll.scrollTo(id) } }
            }
        }
    }

    @Test func theActivityListMaterializesItsViewportAndStillReachesTheLastEntry() throws {
        let entries = (0..<100).map(entry), jump = Jump(), counter = RowBodyCounter()
        let host = testHost(ActivityList(entries: entries, jump: jump)
            .environment(\.rowBodyCounter, counter).environment(\.footerClock, Snapshots.clock),
                            size: CGSize(width: 560, height: 200))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host, describing: "the Activity rows") { !counter.counts.isEmpty }
        let initial = counter.counts.count
        print("Activity initial materialized rows: \(initial) of 100")
        #expect(initial == 7, "baseline 100; final 7 Activity rows in the 200-point viewport")
        let scroll = try #require(host.firstDescendant(NSScrollView.self))
        jump.target = entries.last?.id
        settle(host, describing: "the last Activity entry at the bottom") {
            counter.counts[entries.last!.id] != nil && scroll.documentVisibleRect.minY > 0
                && abs((scroll.documentView?.bounds.maxY ?? 0) - scroll.documentVisibleRect.maxY) <= 32
        }
        #expect(counter.counts[entries.last!.id] != nil)
    }

    @Test func theActivityListMaterializesTheBoardSheetViewportAndStillReachesTheLastEntry() throws {
        let entries = (0..<100).map(entry), entryIDs = Set(entries.map(\.id)), counter = RowBodyCounter()
        let run = OperatorUIFixtures.run(taskSettings: OperatorUIFixtures.taskSettings, goal: OperatorUIFixtures.goal)
        var state = AppState.empty
        state.runs = [run]
        let board = BroadcastBoard.make(run: run, state: state, acting: .none, requests: [])
        let sheet = BroadcastBoardSheet(board: board, reopenFailed: false, actions: BoardActions(), activity: nil)
            .seeded(tab: .activity, entries: entries)
        let host = testHost(sheet.environment(\.rowBodyCounter, counter).environment(\.footerClock, Snapshots.clock),
                            size: CGSize(width: Sheet.width, height: Sheet.height), appearance: NSAppearance(named: .darkAqua))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host, describing: "the board sheet's Activity rows") { !entryIDs.isDisjoint(with: counter.counts.keys) }
        let initial = entryIDs.intersection(counter.counts.keys).count
        print("Board sheet Activity initial materialized rows: \(initial) of 100")
        #expect(initial == 10, "baseline 100; final 10 Activity rows in the real board sheet")
        let scroll = try #require(host.firstDescendant(NSScrollView.self))
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host, describing: "the last Activity entry at the board sheet's bottom") {
            counter.counts[entries.last!.id] != nil && scroll.documentVisibleRect.minY > 0
                && abs((scroll.documentView?.bounds.maxY ?? 0) - scroll.documentVisibleRect.maxY) <= 32
        }
        #expect(counter.counts[entries.last!.id] != nil)
    }

    @Test func theShelfMaterializesItsViewportAndKeepsHighlightScrolling() throws {
        let project = Project.make()
        let rows: [ShelfRow] = (0..<100).map { index in
            let date = Snapshots.clock.now.addingTimeInterval(-Double(index) * 60)
            if index.isMultiple(of: 2) {
                return .broadcast(ShelvedBroadcast(runId: UUID(), name: "Run \(index)", asked: "Work", endedAt: date))
            }
            let task = TaskItem.make(project: project.id, title: "Task \(index)")
            return .task(.init(archived: ArchivedTask(task: task, archivedAt: date), projectName: project.name, provider: .git))
        }
        let model = ArchiveSheetModel(entries: { rows }, restore: { _ in }, open: { _ in }, remove: { _ in })
        model.now = { Snapshots.clock.now }
        let counter = RowBodyCounter()
        let host = testHost(ArchiveSheet(model: model).environment(\.rowBodyCounter, counter).environment(\.footerClock, Snapshots.clock),
                            size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host, describing: "the Shelf rows") { !counter.counts.isEmpty }
        let initial = counter.counts.count
        print("Shelf initial materialized rows: \(initial) of 100")
        #expect(initial == 8, "baseline 100; final 8 Shelf rows in its sheet viewport")
        #expect(model.projection.rows.map(\.id) == rows.map(\.id))
        let scroll = try #require(host.firstDescendant(NSScrollView.self))
        model.highlight(rows.last!.id)
        settle(host, describing: "the last highlighted Shelf row at the bottom") {
            counter.counts[rows.last!.id] != nil && scroll.documentVisibleRect.minY > 0
                && abs((scroll.documentView?.bounds.maxY ?? 0) - scroll.documentVisibleRect.maxY) <= 32
        }
        #expect(model.projection.highlighted?.id == rows.last?.id)
        #expect(counter.counts[rows.last!.id] != nil)
    }
}
