import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTerm

/// New Broadcast's Agents, Task and Done steps each have their image and draw it the same twice: the three steps, the Task
/// step with the Merge slice off, with closing left off and with a project that has no code host, and the Done step with
/// the Oracle off, its goal's editor drawn dimmed.
@MainActor
struct BroadcastSetupSnapshotTests {
    static let files = [
        "broadcast-setup-agents.png", "broadcast-setup-task.png", "broadcast-setup-done.png",
        "broadcast-setup-task-merge-off.png", "broadcast-setup-done-oracle-off.png", "broadcast-setup-task-closing-off.png",
        "broadcast-setup-task-no-code-host.png",
    ]

    @Test func everyStepHasItsImageInTheRegressionSet() {
        #expect(BroadcastSetupSnapshots.all.map(\.file) == Self.files)
        let drawn = Set(Snapshots.regressionSet.map(\.file))
        #expect(Self.files.allSatisfy(drawn.contains))
    }

    /// With the Oracle off only the goal's editor is drawn dimmed, as 10A draws it: its label and help read as the same
    /// `PromptStep`'s, undimmed. Bands of the image ×2: the label's line, inside the editor, and the help's first line.
    @Test func withTheOracleOffOnlyTheGoalsEditorIsDrawnDimmed() throws {
        let off = NewBroadcastModel(projects: [], context: .installed(oracle: false)) { _ in UUID() }
        let step = try drawn(DoneStep(model: off))
        let plain = try drawn(PromptStep(text: .constant(""), agent: .claude, completions: off.completions,
                                         label: NewBroadcastModel.goalLabel, placeholder: NewBroadcastModel.goalPlaceholder,
                                         help: off.goalHelp))
        let label = 0..<28, editor = 80..<300, help = 350..<400
        for band in [label, help] {
            #expect(brightestInk(plain, rows: band) > 0.2, "the band holds the words")
            #expect(abs(brightestInk(step, rows: band) - brightestInk(plain, rows: band)) < 0.02)
        }
        #expect(brightestInk(step, rows: editor) < 0.6 * brightestInk(plain, rows: editor))
    }

    private func drawn(_ view: some View) throws -> NSBitmapImageRep {
        let png = try #require(Snapshots.png(of: Snapshot("probe.png") { view.frame(width: Sheet.width, alignment: .topLeading) }))
        return try #require(NSBitmapImageRep(data: png))
    }

    /// The brightest pixel in `rows`, as much as it covers.
    private func brightestInk(_ bitmap: NSBitmapImageRep, rows: Range<Int>) -> CGFloat {
        var most: CGFloat = 0
        for y in rows {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                most = max(most, (color.redComponent + color.greenComponent + color.blueComponent) / 3 * color.alphaComponent)
            }
        }
        return most
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
