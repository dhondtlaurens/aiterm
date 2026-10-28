import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTerm

/// New Broadcast's Agents, Task and Done steps each have their image and draw it the same twice: the three steps, the Task
/// step with the Merge slice off, with closing left off and with a project that has no code host, and the Done step with
/// the Oracle off, its goal drawn dimmed.
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

    /// With the Oracle off the Done step's goal is drawn dimmed, not only disabled: its label is fainter than the same
    /// `PromptStep`'s undimmed.
    @Test func withTheOracleOffTheGoalIsDrawnDimmed() throws {
        let off = NewBroadcastModel(projects: [], context: .installed(oracle: false)) { _ in UUID() }
        let step = try drawn(DoneStep(model: off))
        let plain = try drawn(PromptStep(text: .constant(""), agent: .claude, completions: off.completions,
                                         label: NewBroadcastModel.goalLabel, placeholder: NewBroadcastModel.goalPlaceholder,
                                         help: off.goalHelp))
        #expect(brightestInk(step) < 0.6 * brightestInk(plain))
    }

    private func drawn(_ view: some View) throws -> NSBitmapImageRep {
        let png = try #require(Snapshots.png(of: Snapshot("probe.png") { view.frame(width: Sheet.width, alignment: .topLeading) }))
        return try #require(NSBitmapImageRep(data: png))
    }

    /// The brightest pixel, as much as it covers, along the label's line: the image's top 16 pt, drawn ×2.
    private func brightestInk(_ bitmap: NSBitmapImageRep) -> CGFloat {
        var most: CGFloat = 0
        for y in 0..<32 {
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
