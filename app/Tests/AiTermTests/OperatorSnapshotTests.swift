import Foundation
import Testing
@testable import AiTerm

/// Every Operator image draws, and draws the same twice: the OPERATOR heading with no broadcast, the
/// broadcast's header and Operator row in each state, driven task rows, the board at each moment, its Summary
/// and Activity tabs and its read-only form from the Shelf, New Broadcast's steps, Settings › Operator, Help with problems, Find a Fix's Notices, a Notice in a
/// sheet's footer, and the broadcast's group folded and just started.
@MainActor
struct OperatorSnapshotTests {
    static let files = [
        "operator-heading-empty.png", "broadcast-row-states.png",
        "driven-task-rows.png",
        "board-running.png", "board-planning.png", "board-paused.png", "board-reopen-failed.png",
        "board-summary.png", "board-summary-writing.png", "board-summary-left-for-you.png", "board-activity.png",
        "board-shelved.png",
        "new-broadcast-1.png", "new-broadcast-2.png",
        "settings-operator.png", "settings-operator-oracle-off.png",
        "settings-help-with-problems.png",
        "banner-find-a-fix-offered.png", "banner-find-a-fix-looking.png", "banner-find-a-fix-proposal.png",
        "banner-find-a-fix-failed.png",
        "notice-footer.png",
        "new-broadcast-not-ready.png",
        "broadcast-folded.png", "broadcast-queued.png",
        "board-summary-worked-around.png", "board-shelved-worked-around.png",
        "board-setup-cards.png", "board-setup-running.png", "board-setup-checking-goal.png", "board-setup-goal-not-met.png",
    ]

    @Test func everyOperatorStateHasItsImage() {
        #expect(OperatorSnapshots.all.map(\.file) == Self.files)
        // Every image drawn before the Operator's keeps its place, so none of their antialiasing moves; the
        // Operator's follow them, together. An image a later part adds goes after these, so this holds.
        let files = Snapshots.regressionSet.map(\.file)
        let before = (SidebarSnapshots.rows + SheetSnapshots.all + SettingsSnapshots.all + [SidebarSnapshots.marks]
                      + SidebarSnapshots.states).map(\.file)
        #expect(Array(files.prefix(before.count)) == before, "the images before the Operator's keep their places")
        #expect(Array(files.dropFirst(before.count).prefix(Self.files.count)) == Self.files, "the Operator's come next, together")
        #expect(Set(files).count == files.count, "no two images share a file")
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
