import AppKit
import Testing
@testable import AiTerm

@MainActor struct SignalSnapshotTests {
    @Test func everyStepOfAJiraAndAGitLabSignalIsDrawnAndTheDrawingsStayStill() throws {
        let snapshots = SignalSnapshots.all
        #expect(snapshots.count == 14)
        #expect(Set(snapshots.map(\.file)).count == snapshots.count)
        let registered = Set(Snapshots.regressionSet.map(\.file))
        for snapshot in snapshots {
            #expect(registered.contains(snapshot.file))
            let first = try #require(Snapshots.png(of: snapshot))
            let second = try #require(Snapshots.png(of: snapshot))
            let image = try #require(NSBitmapImageRep(data: first))
            #expect(image.pixelsWide == 1120 && image.pixelsHigh == 1120, "The five steps keep one sheet size.")
            #expect(Self.sameDrawing(first, second), "\(snapshot.file) changed between renders.")
        }
    }
    /// A project signal's poses (and the projects' signals sheet) are drawn after the rest, at the same sheet size; only
    /// the error poses come after them, then the disc and its cards (step 11), then the status line's poses (step 12).
    @Test func aProjectSignalsStepsAreDrawnAtTheSheetsSize() throws {
        let snapshots = SignalSnapshots.project
        #expect(snapshots.map(\.file) == (1...5).map { "signal-project-gitLab-\($0).png" } + ["signal-project-schedule-5.png"])
        let registered = Snapshots.regressionSet.map(\.file), errors = SignalSidebarSnapshots.errors.map(\.file)
        let cards = SignalSidebarSnapshots.cards.map(\.file), line = SignalSidebarSnapshots.line.map(\.file)
        #expect(errors == ["signals-heading-issue.png", "signals-sheet-issues.png", "issue-signal-read.png"])
        #expect(cards == ["signals-disc.png", "signals-card-operator.png", "signals-card-project.png", "signals-card-chain.png"])
        #expect(line == ["rest", "acting", "waking", "asking", "stop", "stop-acting", "stop-asking"].map { "signals-line-\($0).png" })
        #expect(Array(registered.suffix(snapshots.count + 1 + errors.count + cards.count + line.count))
                == snapshots.map(\.file) + ["signals-sheet-projects.png"] + errors + cards + line)
        for snapshot in snapshots {
            let image = try #require(Snapshots.png(of: snapshot).flatMap(NSBitmapImageRep.init(data:)))
            #expect(image.pixelsWide == 1120 && image.pixelsHigh == 1120, "\(snapshot.file) keeps the sheet size.")
        }
    }
    static func sameDrawing(_ png: Data, _ repeated: Data) -> Bool {
        if png == repeated { return true }
        guard let a = NSBitmapImageRep(data: png), let b = NSBitmapImageRep(data: repeated),
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
              a.samplesPerPixel == b.samplesPerPixel, let left = a.bitmapData, let right = b.bitmapData else { return false }
        var moved = 0
        for pixel in 0..<(a.pixelsWide * a.pixelsHigh) {
            let row = pixel / a.pixelsWide, start = row * a.bytesPerRow + (pixel % a.pixelsWide) * a.samplesPerPixel
            var differs = false
            for sample in start..<(start + a.samplesPerPixel) where left[sample] != right[sample] {
                if abs(Int(left[sample]) - Int(right[sample])) > 1 { return false }
                differs = true
            }
            if differs { moved += 1 }
        }
        return moved * 1_000 <= a.pixelsWide * a.pixelsHigh
    }
}
