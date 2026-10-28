import Foundation
import Testing
@testable import AiTerm

/// New Broadcast's Agents, Task and Done steps each have their image and draw it the same twice: the three steps, the Task
/// step with the Merge slice off, with closing left off and with a project that has no code host, and the Done step with the Oracle off. They are drawn after
/// every other image.
@MainActor
struct BroadcastSetupSnapshotTests {
    static let files = [
        "broadcast-setup-agents.png", "broadcast-setup-task.png", "broadcast-setup-done.png",
        "broadcast-setup-task-merge-off.png", "broadcast-setup-done-oracle-off.png", "broadcast-setup-task-closing-off.png",
        "broadcast-setup-task-no-code-host.png",
    ]

    @Test func everyStepHasItsImageDrawnLast() {
        #expect(BroadcastSetupSnapshots.all.map(\.file) == Self.files)
        #expect(Array(Snapshots.regressionSet.map(\.file).suffix(Self.files.count)) == Self.files)
    }

    @Test func eachImageIsDrawnTheSameTwice() throws {
        for snapshot in BroadcastSetupSnapshots.all {
            let first = try #require(Snapshots.png(of: snapshot), "\(snapshot.file) drew nothing")
            let second = try #require(Snapshots.png(of: snapshot))
            #expect(first.count > 1_000, "\(snapshot.file) is empty")
            #expect(first == second, "\(snapshot.file) is not drawn the same twice")
        }
    }
}
