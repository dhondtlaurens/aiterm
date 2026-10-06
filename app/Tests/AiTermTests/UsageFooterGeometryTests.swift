import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct UsageFooterGeometryTests {
    private let context = UsageLine(window: .context, percent: 84, reset: nil, warning: true)
    private let fiveHour = UsageLine(window: .fiveHour, percent: 84, reset: "16:40", warning: true)
    private let week = UsageLine(window: .weekly, percent: 84, reset: "Wed 16:28", warning: true)

    /// Each ring and number is hovered and read as its words — the glyphs alone say "wk", a ring
    /// and "Wed". SwiftUI builds no accessibility tree for a test, so the words are checked here, and
    /// the footer hands them to `.help` and `.accessibilityLabel` as they are.
    @Test func everyRingAndNumberIsReadInWords() {
        #expect(UsageLine(window: .weekly, percent: 61, reset: "Fri 23:33", warning: false, resetInFull: "Friday 23:33").help
                == "Weekly limit, 61 % used, resets Friday 23:33")
        #expect(fiveHour.help == "5-hour limit, 84 % used, resets 16:40")
        #expect(context.help == "Context 84 % full")
    }

    /// A note's ink follows the row's `warning`, never its wording: the same words on a row that
    /// is not a warning stay muted.
    @Test func aNoteIsAmberOnlyWhenTheRowIsAWarning() {
        #expect(UsageFooter.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected", warning: true)) == Palette.amber)
        #expect(UsageFooter.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected")) == Palette.muted)
        #expect(UsageFooter.noteInk(UsageVendorRow(vendor: .codex, lines: [], note: "Reconnecting", warning: true)) == Palette.amber)
    }

    private func host(_ rows: [UsageVendorRow], task: UsageTaskRow? = nil,
                      width: CGFloat = Size.sidebarMinWidth, scale: InterfaceScale = .standard) -> NSHostingView<AnyView> {
        let view = AnyView(UsageFooter(task: task, rows: rows)
            .interfaceScale(scale)
            .frame(width: width, alignment: .leading)
            .background(Color.black))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The USAGE group: its heading and one `Size.menuRow` line per provider, even when a provider
    /// reports every segment, inside the group's `Space.tight` above and `Space.base` below — 84 pt
    /// for two providers. The ring is round ink inside the row, not a reason for it to grow.
    @Test func everyProviderUsesOneLine() {
        let rows = [
            UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil),
            UsageVendorRow(vendor: .codex, lines: [week, fiveHour], note: nil),
        ]
        let expected = Space.tight + Size.menuRow * 3 + Space.base
        #expect(abs(host(rows).fittingSize.height - expected) < 0.5)
    }

    /// The CONTEXT group is the same shape with one row, then the 1 pt rule that divides it from
    /// USAGE: 61 pt on top of the usage group.
    @Test func theTaskRowAddsOneLineAndARule() {
        let rows = [
            UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil),
            UsageVendorRow(vendor: .codex, lines: [week], note: nil),
        ]
        let task = UsageTaskRow(agent: .claude, context: context)
        let usage = Space.tight + Size.menuRow * 3 + Space.base
        let expected = usage + Space.tight + Size.menuRow * 2 + Space.base + 1
        #expect(abs(host(rows, task: task).fittingSize.height - expected) < 0.5)
    }

    /// The context row is a vendor row with one unlabelled window — its heading already says
    /// `ctx`: mark, ring and number, packed against the leading edge exactly as a vendor's `wk` is,
    /// not pushed to the trailing edge, and with no title or avatar group beside it.
    @Test func theTaskRowDrawsOnlyItsMarkAndContext() throws {
        let host = host([], task: UsageTaskRow(agent: .claude, context: context), width: 600)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = (" 84%" as NSString).size(withAttributes: [.font: font]).width
        let expected = Space.inset + Space.base + Size.vendorMark + Space.inset + Size.statusMark + text
        // Below the CONTEXT heading, above the rule: the context row alone.
        let top = Int(Space.tight + Size.menuRow)
        let right = try paintedWidth(host, band: top..<(top + Int(Size.menuRow)))
        #expect(abs(right - expected) < 2,
                "the task row's ink ends at \(right) pt; a mark and one ctx segment end at \(expected) pt")
    }

    /// The ring replaced a four-cell text bar, so nothing in the row's *text* proves it is there.
    /// Measure the gap between the painted row and the width of its text alone: what is left over
    /// is the ring, and it has to be a ring's worth.
    @Test func eachSegmentDrawsARingBesideItsNumber() throws {
        let rows = [UsageVendorRow(vendor: .claude, lines: [week.withoutReset], note: nil)]
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = ("wk  84%" as NSString).size(withAttributes: [.font: font]).width
        // The row also carries the vendor mark and the footer's leading edge: the list's inset
        // plus a row's `Space.base`.
        let leading = Space.inset + Space.base + Size.vendorMark + Space.inset
        let ring = try paintedWidth(rows, width: 600) - leading - text
        #expect(abs(ring - Size.statusMark) < 2,
                "the segment leaves \(ring) pt for its ring; a ring is \(Size.statusMark) pt")
    }

    /// Every telemetry segment constructs the same ring component at the shared status-mark
    /// diameter. Percent and warning state may change its fill and colour, never its size.
    @Test func everyTelemetryRingHasTheSameDiameter() {
        let sizes = [
            UsageRing(percent: 23, warning: false, size: Size.statusMark),
            UsageRing(percent: 84, warning: true, size: Size.statusMark),
            UsageRing(percent: 42, warning: false, size: Size.statusMark),
        ].map { NSHostingView(rootView: $0).fittingSize }
        #expect(sizes.allSatisfy { abs($0.width - Size.statusMark) < 0.5 })
        #expect(sizes.allSatisfy { abs($0.height - Size.statusMark) < 0.5 })
    }

    /// The reset time is the row's only source of "when does this clear?", so it has to be drawn,
    /// not merely carried on the line. Dropping it from the renderer narrows the row by exactly the
    /// width of the two reset strings.
    @Test func theRowDrawsEachWindowsResetTime() throws {
        let bare = [UsageVendorRow(vendor: .claude,
                                   lines: [fiveHour.withoutReset, week.withoutReset], note: nil)]
        let dated = [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)]
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let resets = (" \(fiveHour.reset!) \(week.reset!)" as NSString).size(withAttributes: [.font: font]).width
        let grown = try paintedWidth(dated, width: 600) - paintedWidth(bare, width: 600)
        #expect(abs(grown - resets) < 2,
                "reset times add \(grown) pt of row; the two strings measure \(resets) pt")
    }

    /// The sidebar minimum exists to fit this row. The common case — both windows under 100%, the
    /// 5-hour one resetting today and the weekly one on a later day — must paint inside
    /// ``Size/sidebarMinWidth`` rather than truncate.
    /// At every interface size, against that size's own minimum.
    @Test(arguments: InterfaceScale.all)
    func theTwoWindowTelemetryFitsTheMinimumSidebarWidth(scale: InterfaceScale) throws {
        let rows = [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)]
        // Comparing the row against its own unconstrained rendering is the only honest test:
        // arithmetic on the string's width agrees to a fraction of a point and still truncates.
        let natural = try paintedWidth(rows, width: 900, scale: scale)
        let minimum = scale(Size.sidebarMinWidth)
        let atMinimum = try paintedWidth(rows, width: minimum, scale: scale)
        #expect(abs(atMinimum - natural) < 1,
                "at ×\(scale.factor) the row paints \(natural) pt unconstrained but only \(atMinimum) pt at the \(minimum) pt sidebar minimum, so it is truncating")
    }
}

private extension UsageLine {
    var withoutReset: UsageLine { UsageLine(window: window, percent: percent, reset: nil, warning: warning) }
}

extension UsageFooterGeometryTests {
    /// The footer stretches to its container and its text leaves are not separate `NSView`s, so
    /// only the pixels say how wide the row's ink runs. Rasterise it over a backdrop far wider than
    /// the sidebar and find the rightmost painted column.
    private func paintedWidth(_ rows: [UsageVendorRow], width: CGFloat, scale: InterfaceScale = .standard) throws -> CGFloat {
        // The 1 pt top hairline runs the footer's full width; the band below it holds the USAGE
        // heading, which is narrower than any row, and the rows.
        let host = host(rows, width: width, scale: scale)
        return try paintedWidth(host, band: 4..<Int(host.bounds.height.rounded(.up)))
    }

    /// `band` is in points from the top; it has to leave out every full-width rule.
    private func paintedWidth(_ host: NSHostingView<AnyView>, band points: Range<Int>) throws -> CGFloat {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let backdrop = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: bitmap.pixelsHigh / 2))
        let band = Int(CGFloat(points.lowerBound) * scale)..<min(bitmap.pixelsHigh, Int(CGFloat(points.upperBound) * scale))
        for x in stride(from: bitmap.pixelsWide - 1, through: 0, by: -1) {
            for y in band where bitmap.colorAt(x: x, y: y).map({
                abs($0.redComponent - backdrop.redComponent) > 0.02
                    || abs($0.greenComponent - backdrop.greenComponent) > 0.02
                    || abs($0.blueComponent - backdrop.blueComponent) > 0.02
            }) == true {
                return CGFloat(x) / scale
            }
        }
        return 0
    }
}
