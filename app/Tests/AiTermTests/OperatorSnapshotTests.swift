import Foundation
import Testing
@testable import AiTerm

/// Every operator image draws, and draws the same twice: the sidebar with none, at work and done, a
/// driven task row in each workflow state, the marks, the operator sheet three ways, New operation,
/// and the overview at each of its moments.
@MainActor
struct OperatorSnapshotTests {
    static let files = [
        "operators-none.png", "operators-working.png", "operators-paused.png", "operators-done.png",
        "operator-task-rows.png", "operator-marks.png",
        "operator-sheet-new.png", "operator-sheet-edit.png", "operator-sheet-no-self-doubt.png",
        "new-operation.png",
        "overview-plan.png", "overview-working.png", "overview-paused.png", "overview-done.png",
    ]

    @Test func everyOperatorStateHasItsImage() {
        #expect(OperatorSnapshots.all.map(\.file) == Self.files)
        // Every image drawn before Operators keeps its place, so none of their antialiasing moves; the
        // operators follow them, together. An image a later part adds goes after these, so this holds.
        let files = Snapshots.regressionSet.map(\.file)
        let before = (SidebarSnapshots.rows + SheetSnapshots.all + SettingsSnapshots.all + [SidebarSnapshots.marks]
                      + SidebarSnapshots.states).map(\.file)
        #expect(Array(files.prefix(before.count)) == before, "the images before Operators keep their places")
        #expect(Array(files.dropFirst(before.count).prefix(Self.files.count)) == Self.files, "the operators come next, together")
    }

    @Test func eachImageIsDrawnTheSameTwice() throws {
        for snapshot in OperatorSnapshots.all {
            let first = try #require(Snapshots.png(of: snapshot), "\(snapshot.file) drew nothing")
            let second = try #require(Snapshots.png(of: snapshot))
            #expect(first.count > 1_000, "\(snapshot.file) is empty")
            #expect(first == second, "\(snapshot.file) is not drawn the same twice")
        }
    }
}
