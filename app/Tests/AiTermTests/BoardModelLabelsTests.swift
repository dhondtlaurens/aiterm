import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The board's cards name a model as Settings › Agents lists it (broadcast setup v2, 14A): the rows read the agents' labels
/// off the main actor each time the board's sheet opens, and the board is derived again with them.
@MainActor
struct BoardModelLabelsTests {
    /// Whether the board's sheet shows, as a test flips it.
    private final class Shown { var value = false }

    @Test func theLabelsAreReadAsTheBoardOpensAndNameTheModel() async throws {
        let scene = OperatorScene.setUpRunning()
        let rows = scene.controller.rows, shown = Shown()
        rows.modelLabels = [:]
        rows.boardShown = { shown.value }
        rows.modelLabelSource = { [.claude: ["claude-opus-5-5": "Opus 5.5"]] }
        rows.refresh()
        #expect(rows.board == nil && rows.labelLoad == nil, "nothing is read while the board is closed")

        shown.value = true
        rows.refresh()
        await rows.labelLoad?.value
        let drawer = try #require(rows.board?.columns.flatMap(\.cards).first { $0.id == scene.drawer })
        #expect(drawer.combination == "Opus 5.5 · High")
        let provider = try #require(rows.board?.columns.flatMap(\.cards).first { $0.id == scene.provider })
        #expect(provider.combination == "gpt-6-astra · Medium", "no Codex label read: its id")
    }
}
