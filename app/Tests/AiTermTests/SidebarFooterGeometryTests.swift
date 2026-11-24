import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct SidebarFooterGeometryTests {
    private let context = UsageLine(window: .context, percent: 84, reset: nil, warning: true)
    private let fiveHour = UsageLine(window: .fiveHour, percent: 84, reset: "16:40", warning: true)
    private let week = UsageLine(window: .weekly, percent: 84, reset: "Wed 16:28", warning: true)

    /// Each ring and number is read as its words — the labels alone say "wk", a ring and "Wed".
    /// SwiftUI builds no accessibility tree for a test, so the words are checked here, and the footer
    /// hands them to `.accessibilityLabel` as they are.
    @Test func everyRingAndNumberIsReadInWords() {
        #expect(UsageLine(window: .weekly, percent: 61, reset: "Fri 23:33", warning: false, resetInFull: "Friday 23:33").help
                == "Weekly limit, 61 % used, resets Friday 23:33")
        #expect(fiveHour.help == "5-hour limit, 84 % used, resets 16:40")
        #expect(context.help == "Context 84 % full")
    }

    /// The Mac's readings row is read as its readings in words; before the first sample, as the Mac.
    @Test func theMacsReadingsAreReadInWords() {
        #expect(SidebarFooter.readingsLabel([]) == "Mac")
        #expect(SidebarFooter.readingsLabel([UsageLine(window: .cpu, percent: 23, warning: false),
                                             UsageLine(window: .ram, percent: 78, warning: true)])
                == "CPU 23 % busy, Memory 78 % used, under pressure")
    }

    /// A note's ink follows the row's `warning`, never its wording: the same words on a row that
    /// is not a warning stay muted.
    @Test func aNoteIsAmberOnlyWhenTheRowIsAWarning() {
        #expect(SidebarFooter.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected", warning: true)) == Palette.amber)
        #expect(SidebarFooter.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected")) == Palette.muted)
        #expect(SidebarFooter.noteInk(UsageVendorRow(vendor: .codex, lines: [], note: "Reconnecting", warning: true)) == Palette.amber)
    }

    /// The telemetry's face: words in the system face at the help size, with tabular figures.
    private static let telemetryFont = Typography.help.tabular.nsFont

    /// A string's width in the telemetry's face, at the standard size.
    private static func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: telemetryFont]).width
    }

    /// Every label sits in the width of the widest, so the ring after it starts at the same x.
    private static func labelBox() -> CGFloat {
        UsageLine.Window.allCases.map { width($0.shortLabel) }.max() ?? 0
    }

    /// From the footer's leading edge to a row's first column: the list's inset and `Space.base`, the
    /// mark, `Space.inset`.
    private static func firstColumn(scale: InterfaceScale = .standard) -> CGFloat {
        scale(Space.inset) + scale(Space.base) + scale(Size.vendorMark) + scale(Space.inset)
    }

    /// One column's width in a footer `width` wide: what is left after the edges, the mark, its
    /// inset and the gaps between the columns, shared equally.
    private static func column(_ width: CGFloat, scale: InterfaceScale = .standard) -> CGFloat {
        let gaps = CGFloat(SidebarFooter.columns - 1) * scale(Space.gap)
        return (width - 2 * (scale(Space.inset) + scale(Space.base)) - scale(Size.vendorMark) - scale(Space.inset) - gaps)
            / CGFloat(SidebarFooter.columns)
    }

    /// Where a reading's number ends when it starts at `x`: label box, `Space.tight`, ring, a space.
    private static func numberStart(_ x: CGFloat) -> CGFloat {
        x + labelBox() + Space.tight + Size.statusMark + width(" ")
    }

    private func host(_ rows: [UsageVendorRow], task: UsageTaskRow? = nil, machine: [UsageLine] = [], mode: MacMode = .desk,
                      width: CGFloat = Size.sidebarMinWidth, scale: InterfaceScale = .standard,
                      hovering: UsageLine.Window? = nil) -> NSHostingView<AnyView> {
        let mac = MacModePresentation.line(mode: mode, hotspot: "Laurens’s iPhone", wifi: "Office-WiFi")
        let view = AnyView(SidebarFooter(task: task, rows: rows, machine: machine, mac: mac, hovering: hovering)
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
        // SYSTEM's heading and the Mac's readings, the rule, then USAGE's heading and two providers.
        let expected = (Space.tight + Size.menuRow * 2 + Space.base) + 1 + (Space.tight + Size.menuRow * 3 + Space.base)
        #expect(abs(host(rows).fittingSize.height - expected) < 0.5)
    }

    /// With a task selected the context row adds one line to SYSTEM.
    @Test func theTaskRowAddsOneLineAndARule() {
        let rows = [
            UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil),
            UsageVendorRow(vendor: .codex, lines: [week], note: nil),
        ]
        let task = UsageTaskRow(agent: .claude, context: context)
        let usage = Space.tight + Size.menuRow * 3 + Space.base
        // SYSTEM's heading, the context row and the Mac's readings, then the rule.
        let expected = usage + Space.tight + Size.menuRow * 3 + Space.base + 1
        #expect(abs(host(rows, task: task).fittingSize.height - expected) < 0.5)
    }

    /// The context row is a vendor row with one window labelled `ctx`: mark, ring and number in its
    /// first column, exactly as a vendor's `wk` is, with no title or avatar group beside it.
    @Test func theTaskRowDrawsOnlyItsMarkAndContext() throws {
        let host = host([], task: UsageTaskRow(agent: .claude, context: context), width: 600)
        let expected = Self.numberStart(Self.firstColumn()) + Self.width("84%")
        // Below the SYSTEM heading, above the rule: the context row alone.
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
        // The row also carries the vendor mark and the footer's leading edge, then the label box.
        let text = Self.labelBox() + Space.tight + Self.width(" 84%")
        let ring = try paintedWidth(rows, width: 600) - Self.firstColumn() - text
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

    /// At rest a row is its numbers alone: a window's reset waits under the pointer, in its
    /// `ResetBadge`, so a dated reading paints exactly as wide as the same reading without one.
    @Test func theResetIsNotDrawnAtRest() throws {
        let bare = [UsageVendorRow(vendor: .claude, lines: [week.withoutReset, fiveHour.withoutReset], note: nil)]
        let dated = [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)]
        let grown = try paintedWidth(dated, width: 600) - paintedWidth(bare, width: 600)
        #expect(abs(grown) < 0.5, "the resets add \(grown) pt of row at rest")
    }

    /// The badge a reset rises in is a chip: `Size.chip` tall at every size, at its own width, its
    /// time whole.
    @Test(arguments: InterfaceScale.all)
    func theResetBadgeIsAChip(scale: InterfaceScale) {
        let host = NSHostingView(rootView: ResetBadge(reset: "Wed 16:28").interfaceScale(scale))
        #expect(abs(host.fittingSize.height - scale(Size.chip)) < 0.5)
        let words = (("resets Wed 16:28" as NSString).size(withAttributes: [.font: Self.telemetryFont]).width) * scale.factor
        #expect(host.fittingSize.width > words, "the chip is \(host.fittingSize.width) pt; its words alone are \(words) pt")
    }

    @Test(arguments: InterfaceScale.all, [5, 42, 100])
    func resetCentersOverTheDisplayedReading(scale: InterfaceScale, percent: Int) throws {
        let reading = UsageLine(window: .weekly, percent: percent, reset: "Sat 12:00", warning: false)
        let rows = [UsageVendorRow(vendor: .claude, lines: [reading], note: nil)]
        let width = scale(Size.sidebarMinWidth)
        let right = try paintedWidth(rows, width: width, scale: scale)
        let center = (Self.firstColumn(scale: scale) + right) / 2
        let resting = host(rows, width: width, scale: scale)
        let hovered = host(rows, width: width, scale: scale, hovering: .weekly)
        func capture(_ view: NSView) throws -> NSBitmapImageRep {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        let before = try capture(resting), after = try capture(hovered)
        let factor = CGFloat(after.pixelsWide) / width
        // The middle of the raised chip lies in the heading just above the only vendor row.
        let rowCenter = hovered.bounds.height - scale(Space.base) - scale(Size.menuRow) / 2
        let readingHeight = Typography.help.tabular.scaled(by: scale).nsFont
        let lineHeight = ceil(readingHeight.ascender - readingHeight.descender)
        let y = Int((rowCenter - lineHeight / 2 - scale(Space.hairline) - scale(Size.chip) / 2) * factor)
        let span = (0..<after.pixelsWide).filter { before.colorAt(x: $0, y: y) != after.colorAt(x: $0, y: y) }
        let left = try #require(span.first), last = try #require(span.last)
        #expect(abs(CGFloat(left + last + 1) / (2 * factor) - center) <= 1.5)
    }

    /// The sidebar minimum has to fit a column's widest reading: a window at 100 %. A row's first
    /// column starts at the same x whatever the width, so it paints the same at the minimum as
    /// unconstrained unless it truncates. At every interface size, against that size's own minimum.
    @Test(arguments: InterfaceScale.all)
    func theWidestColumnFitsTheMinimumSidebarWidth(scale: InterfaceScale) throws {
        let full = UsageLine(window: .weekly, percent: 100, reset: "Wed 16:28", warning: true)
        let rows = [UsageVendorRow(vendor: .claude, lines: [full], note: nil)]
        // Comparing the row against its own unconstrained rendering is the only honest test:
        // arithmetic on the string's width agrees to a fraction of a point and still truncates.
        let natural = try paintedWidth(rows, width: 900, scale: scale)
        let minimum = scale(Size.sidebarMinWidth)
        let atMinimum = try paintedWidth(rows, width: minimum, scale: scale)
        #expect(abs(atMinimum - natural) < 1,
                "at ×\(scale.factor) the column paints \(natural) pt unconstrained but only \(atMinimum) pt at the \(minimum) pt sidebar minimum, so it is truncating")
        #expect(natural - Self.firstColumn(scale: scale) <= Self.column(minimum, scale: scale),
                "at ×\(scale.factor) the reading needs \(natural - Self.firstColumn(scale: scale)) pt of a \(Self.column(minimum, scale: scale)) pt column")
    }

    /// Every row is three equal columns, so a reading starts at the same x in both groups: a
    /// vendor's 5-hour window and the Mac's RAM end where a second column's reading ends, and the
    /// battery where a third's does.
    @Test func everyColumnStartsAtTheSameXInEveryRow() throws {
        let width: CGFloat = 400
        let column = Self.column(width) + Space.gap
        let second = Self.numberStart(Self.firstColumn() + column) + Self.width("84%")
        let third = Self.numberStart(Self.firstColumn() + 2 * column) + Self.width("84%")
        let vendor = [UsageVendorRow(vendor: .claude, lines: [week.withoutReset, fiveHour.withoutReset], note: nil)]
        let ink = try paintedWidth(vendor, width: width)
        #expect(abs(ink - second) < 2, "the 5-hour window ends at \(ink) pt; a second column's ends at \(second) pt")
        let top = Int(Space.tight + Size.menuRow)
        let band = top..<(top + Int(Size.menuRow))
        let pair = [UsageLine(window: .cpu, percent: 84, warning: false), UsageLine(window: .ram, percent: 84, warning: false)]
        let ram = try paintedWidth(host([], machine: pair, width: width), band: band)
        #expect(abs(ram - ink) < 1, "the Mac's RAM ends at \(ram) pt, the vendor's 5-hour window at \(ink) pt")
        let battery = try paintedWidth(host([], machine: pair + [UsageLine(window: .battery, percent: 84, warning: false)], width: width),
                                       band: band)
        #expect(abs(battery - third) < 2, "the battery ends at \(battery) pt; a third column's ends at \(third) pt")
    }

    /// The widest context row — a full window — paints whole at the
    /// sidebar's narrowest, at every size.
    @Test(arguments: InterfaceScale.all)
    func theWidestContextRowFitsTheMinimumSidebarWidth(scale: InterfaceScale) throws {
        let task = UsageTaskRow(agent: .claude, context: UsageLine(window: .context, percent: 100, reset: nil, warning: true))
        let top = Int(scale(Space.tight) + scale(Size.menuRow))
        let band = top..<(top + Int(scale(Size.menuRow)))
        let natural = try paintedWidth(host([], task: task, width: 900, scale: scale), band: band)
        let atMinimum = try paintedWidth(host([], task: task, width: scale(Size.sidebarMinWidth), scale: scale), band: band)
        #expect(abs(atMinimum - natural) < 1,
                "at ×\(scale.factor) the ctx row paints \(natural) pt unconstrained but only \(atMinimum) pt at the minimum")
    }
}

private extension UsageLine {
    var withoutReset: UsageLine { UsageLine(window: window, percent: percent, reset: nil, warning: warning) }
}

extension SidebarFooterGeometryTests {
    /// The footer stretches to its container and its text leaves are not separate `NSView`s, so
    /// only the pixels say how wide the row's ink runs. Rasterise it over a backdrop far wider than
    /// the sidebar and find the rightmost painted column.
    private func paintedWidth(_ rows: [UsageVendorRow], width: CGFloat, scale: InterfaceScale = .standard) throws -> CGFloat {
        // Two 1 pt rules run the footer's full width: the top one, and the one between SYSTEM and
        // USAGE. The band below the second holds the USAGE heading, which is narrower than any row,
        // and the rows.
        let host = host(rows, width: width, scale: scale)
        let system = scale(Space.tight) + scale(Size.menuRow) * 2 + scale(Space.base)
        return try paintedWidth(host, band: Int((system + 2).rounded(.up))..<Int(host.bounds.height.rounded(.up)))
    }

    /// `band` is in points from the top; it has to leave out every full-width rule.
    private func paintedWidth(_ host: NSHostingView<AnyView>, band points: Range<Int>) throws -> CGFloat {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let band = Int(CGFloat(points.lowerBound) * scale)..<min(bitmap.pixelsHigh, Int(CGFloat(points.upperBound) * scale))
        // Sampled inside the band, past the rows' ink: the footer's middle can land on a rule.
        let backdrop = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: (band.lowerBound + band.upperBound) / 2))
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

    /// The footer sits on a ground of its own, a step darker than the window (`Palette.sidebarFooter`),
    /// across its whole width: here over a black backdrop, past every reading's ink.
    @Test func theFooterSitsOnItsOwnGround() throws {
        let host = host([], width: 400)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        // Inside the System heading's band, at the trailing edge, where nothing is drawn but the ground.
        let y = Int((Space.tight + Size.menuRow / 2) * scale)
        let drawn = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: y)?.usingColorSpace(.sRGB))
        let ground = try #require(NSColor(Palette.sidebarFooter).usingColorSpace(.sRGB))
        for (a, b) in [(drawn.redComponent, ground.redComponent), (drawn.greenComponent, ground.greenComponent),
                       (drawn.blueComponent, ground.blueComponent)] {
            #expect(abs(a - b) < 0.02, "the footer's ground is \(drawn), not \(ground)")
        }
    }

    /// The first group is System: with the Mac's row beside it, the heading no
    /// longer says what the context number is, so its row carries `ctx` (measured in
    /// `theTaskRowDrawsOnlyItsMarkAndContext`).
    @Test func theFirstGroupIsSystem() {
        #expect(SidebarFooter.systemHeading == "System")
        #expect(SidebarFooter.headingStatus("backpack mode") == " · backpack mode")
    }

    /// SYSTEM is always there: with nothing selected it still holds the Mac's readings, one
    /// `Size.menuRow` line in the group's padding, then the rule and USAGE. At the desk that is all
    /// the Mac draws (proposal 3A).
    @Test func withNothingSelectedSystemHoldsTheMacsReadings() {
        let rows = [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)]
        let usage = Space.tight + Size.menuRow * 2 + Space.base
        let system = Space.tight + Size.menuRow * 2 + Space.base
        #expect(abs(host(rows).fittingSize.height - (system + 1 + usage)) < 0.5)
    }

    /// Backpack Mode is said on the System heading's own line (proposal 1B, 18 Nov 2026), so the
    /// footer is the desk's height in every mode: turning the mode on or off moves nothing above it.
    @Test(arguments: [MacMode.desk, .turningOn, .on, .needsYou(.lostHotspot), .needsYou(.lowBattery(level: 13)), .turningOff])
    func everyModeKeepsTheDesksHeight(mode: MacMode) {
        let usage = Space.tight + Size.menuRow + Space.base
        let system = Space.tight + Size.menuRow * 2 + Space.base
        #expect(abs(host([], mode: mode).fittingSize.height - (system + 1 + usage)) < 0.5)
    }

    /// On battery the battery is the readings row's third column, so it adds no row: in every mode
    /// the Mac is one row under the heading.
    @Test(arguments: [MacMode.desk, .on])
    func theBatteryJoinsTheReadingsRow(mode: MacMode) {
        let machine = [UsageLine(window: .cpu, percent: 23, warning: false), UsageLine(window: .ram, percent: 61, warning: false),
                       UsageLine(window: .battery, percent: 74, warning: false)]
        let usage = Space.tight + Size.menuRow + Space.base
        let system = Space.tight + Size.menuRow * 2 + Space.base
        #expect(abs(host([], machine: machine, mode: mode).fittingSize.height - (system + 1 + usage)) < 0.5)
    }
}
