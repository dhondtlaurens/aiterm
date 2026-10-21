import Testing
@testable import AiTermUI

/// The Metrics members the Operator's greenfield design added (19 Oct 2026), held at the numbers the
/// picked design drew: the 12 pt mark beside a line of text — the Notice's, the Find a Fix button's —
/// and the board's column width (the Operator sheet, 21 Oct 2026).
struct MetricsTests {
    @Test func inlineMarkAndBoardColumn() {
        #expect(Size.inlineMark == 12)
        #expect(Sheet.boardColumn == 236)
    }
}
