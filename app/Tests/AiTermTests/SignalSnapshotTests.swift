import AppKit
import Testing
@testable import AiTerm

@MainActor struct SignalSnapshotTests {
    @Test func everySourceAndEventHasEveryStepAndTheDrawingsStayStill() throws {
        let snapshots = SignalSnapshots.all
        #expect(snapshots.count == 28)
        #expect(Set(snapshots.map(\.file)).count == snapshots.count)
        let registered = Set(Snapshots.regressionSet.map(\.file))
        for snapshot in snapshots {
            #expect(registered.contains(snapshot.file))
            let first = try #require(Snapshots.png(of: snapshot))
            let second = try #require(Snapshots.png(of: snapshot))
            let image = try #require(NSBitmapImageRep(data: first))
            #expect(image.pixelsWide == 1120 && image.pixelsHigh == 1120, "The five steps keep one sheet size.")
            #expect(OperatorSnapshotTests.sameDrawing(first, second), "\(snapshot.file) changed between renders.")
        }
    }
}
