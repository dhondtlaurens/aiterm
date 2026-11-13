import AppKit
import Testing
@testable import AiTermUI

/// Metrics members held at the numbers a picked design drew: the Operator's greenfield design's
/// (19 Oct 2026) 12 pt mark beside a line of text — the Notice's, the Find a Fix button's — and the
/// board's column width (the Operator sheet, 21 Oct 2026); the layered foundation's radii and
/// heading styles (13 Nov 2026).
struct MetricsTests {
    @Test func inlineMarkAndBoardColumn() {
        #expect(Size.inlineMark == 12)
        #expect(Sheet.boardColumn == 236)
    }

    /// The layered foundation (13 Nov 2026) draws every shape one step rounder than AppKit's 4, 6, 8
    /// and 10, and in that order: a chip inside a control inside a group, a panel the roundest.
    @Test func theRadiiAreAStepRounder() {
        #expect([Radius.chip, Radius.control, Radius.group, Radius.panel] == [5, 7, 10, 12])
    }

    /// The type steps the foundation picked: a sheet's title at 17 semibold heads the sheet, a group's
    /// heading is body-sized semibold, and a sidebar section's heading is 11 semibold.
    @Test func theHeadingStyles() {
        #expect(Typography.title == TypeStyle(size: 17, weight: .semibold))
        #expect(Typography.card == TypeStyle(size: 13, weight: .semibold))
        #expect(Typography.section == TypeStyle(size: 11, weight: .semibold))
        #expect(Typography.title.size > Typography.card.size && Typography.card.size > Typography.section.size)
    }

    /// The chip face is words, not code (13 Nov 2026): 10 pt medium in the system face. `.tabular` gives a
    /// style tabular figures and keeps them through a scale, and its `NSFont` sets every digit at one width
    /// — the monospaced face is for code alone, and keeps its own design.
    @Test func theChipFaceAndTabularFigures() {
        #expect(Typography.chip == TypeStyle(size: 10, weight: .medium))
        #expect(!Typography.chip.tabularFigures && Typography.chip.tabular.tabularFigures)
        #expect(Typography.chip.tabular.scaled(by: .large).tabularFigures)
        #expect(Typography.chip.tabular.scaled(by: .large).size == 10 * 1.15)
        func advance(_ text: String, _ font: NSFont) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        let tabular = Typography.help.tabular.nsFont
        #expect(abs(advance("1111", tabular) - advance("8888", tabular)) < 0.01, "tabular digits share one width")
        #expect(advance("ctx", tabular) != advance("ctx", Typography.mono.nsFont), "the labels are not in the mono face")
        #expect(Typography.mono.tabular.nsFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    /// A control that can't be used now is faded to the opacity `SegmentedControl` gives a segment it rejects.
    @Test func aDisabledControlsOpacity() {
        #expect(Opacity.disabled == 0.4)
    }
}
