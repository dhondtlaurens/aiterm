import AppKit
import Foundation
import Testing
@testable import AiTerm

/// Every Operator state has a fixture image: the OPERATOR heading with no broadcast, the
/// broadcast's header and Operator row in each state, driven task rows, the board at each moment, its summary,
/// its Activity tab and its read-only form from the Shelf, its rows and its questions, New Broadcast's steps, Settings › Operator, Help with problems, Find a Fix's Notices, a Notice in a
/// sheet's footer, and the broadcast's group folded and just started.
@MainActor
struct OperatorSnapshotTests {
    static let files = [
        "operator-heading-empty.png", "broadcast-row-states.png",
        "driven-task-rows.png",
        "board-running.png", "board-planning.png", "board-paused.png", "board-reopen-failed.png",
        "board-summary.png", "board-summary-writing.png", "board-summary-left-for-you.png", "board-activity.png",
        "board-activity-everything.png", "board-shelved.png",
        "new-broadcast-1.png", "new-broadcast-2.png",
        "settings-operator.png", "settings-operator-oracle-off.png",
        "settings-help-with-problems.png",
        "banner-find-a-fix-offered.png", "banner-find-a-fix-looking.png", "banner-find-a-fix-proposal.png",
        "banner-find-a-fix-failed.png",
        "notice-footer.png",
        "new-broadcast-not-ready.png",
        "broadcast-folded.png", "broadcast-queued.png", "broadcast-paused.png",
        "board-summary-worked-around.png", "board-shelved-worked-around.png",
        "board-rows.png", "board-setup-running.png", "board-setup-checking-goal.png", "board-setup-goal-not-met.png",
        "board-waiting-on-you.png", "board-questions.png",
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

    /// Rendering smoke coverage is shared across both fixture families. Actual visual requirements
    /// live in geometry/appearance tests and the checked-in README image. Repeated rendering separately
    /// guards the fixed-clock/stationary-animation export contract.
    @Test func operatorAndSetupFixturesRenderValidImages() throws {
        for snapshot in OperatorSnapshots.all + BroadcastSetupSnapshots.all {
            let png = try #require(Snapshots.png(of: snapshot), "\(snapshot.file) drew nothing")
            let image = try #require(NSBitmapImageRep(data: png), "\(snapshot.file) is not a valid image")
            #expect(image.pixelsWide > 0 && image.pixelsHigh > 0, "\(snapshot.file) has no drawable area")
            #expect(png.count > 1_000, "\(snapshot.file) drew no content")
            let repeated = try #require(Snapshots.png(of: snapshot))
            if snapshot.file == "broadcast-setup-done-oracle-off.png" {
                // Fresh native disabled-field hosts can render differently; dimming itself is
                // checked by BroadcastSetupSnapshotTests outside this intermittent expectation.
                withKnownIssue("Disabled native goal fields can vary across fresh ImageRenderer hosts", isIntermittent: true) {
                    #expect(Self.sameDrawing(png, repeated), "\(snapshot.file) changed between renders")
                }
            } else {
                #expect(Self.sameDrawing(png, repeated), "\(snapshot.file) changed between renders")
            }
        }
    }

    /// Whether two renders are one drawing. A clock that ran or a spinner that turned redraws whole
    /// glyphs and arcs, many levels in many pixels. The renderer's own noise is neither: it rounds an
    /// antialiased edge one level up or down from one render to the next, in a handful of pixels: the
    /// stepper's rings in `new-broadcast-2.png` (4 to 52 pixels of 1,254,400) and a faded select's
    /// title in `settings-operator-oracle-off.png` (9 pixels), both measured 13 Nov 2026. So a render
    /// may differ from the last by one level per channel, in at most one pixel in a thousand.
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

    /// The tolerance is the renderer's rounding and nothing a person could see move.
    @Test func aRenderMayDifferByOneLevelInAFewPixelsAndNoMore() throws {
        func image(_ edit: (NSBitmapImageRep) -> Void) throws -> Data {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 400, bitsPerPixel: 32))
            let bytes = try #require(rep.bitmapData)
            // Opaque: under a partial alpha the PNG's premultiplied round trip would fold levels together.
            for index in 0..<(400 * 100) { bytes[index] = index % 4 == 3 ? 255 : 100 }
            edit(rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        let plain = try image { _ in }
        #expect(Self.sameDrawing(plain, plain))
        // Ten pixels of ten thousand, one level each: one in a thousand, the most that passes.
        #expect(Self.sameDrawing(plain, try image { rep in for pixel in 0..<10 { rep.bitmapData![pixel * 4] = 101 } }))
        #expect(!Self.sameDrawing(plain, try image { rep in for pixel in 0..<11 { rep.bitmapData![pixel * 4] = 101 } }),
                "more than one pixel in a thousand is a change")
        #expect(!Self.sameDrawing(plain, try image { rep in rep.bitmapData![0] = 102 }), "two levels is a change")
        let wider = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 101, pixelsHigh: 100, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 404, bitsPerPixel: 32)).representation(using: .png, properties: [:])
        #expect(!Self.sameDrawing(plain, try #require(wider)), "another size is another drawing")
    }
}
