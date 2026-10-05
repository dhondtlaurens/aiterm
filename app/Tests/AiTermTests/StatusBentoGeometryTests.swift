import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct StatusBentoGeometryTests {
    private let context = UsageLine(label: "ctx", percent: 42, reset: nil, warning: false)
    private let fiveHour = UsageLine(label: "5h", percent: 84, reset: "16:40", warning: true)
    private let week = UsageLine(label: "wk", percent: 84, reset: "Wed 16:28", warning: true)
    private var rows: [UsageVendorRow] {
        [UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil),
         UsageVendorRow(vendor: .codex, lines: [week, fiveHour], note: nil)]
    }

    private func host(_ view: some View, width: CGFloat, scale: InterfaceScale = .standard) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.interfaceScale(scale).surface(.sidebar)
            .frame(width: width, alignment: .leading).background(Color.black)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func bento(task: UsageTaskRow?, scale: InterfaceScale = .standard) -> NSHostingView<AnyView> {
        let backpack = BackpackController.inert()
        backpack.preview(state: .off, setup: BackpackSetup(sleepRule: true, location: true, network: "iPhone"))
        return host(StatusBento(task: task, rows: rows, backpack: backpack, openBackpackSettings: {}),
                    width: scale(Size.sidebarMinWidth), scale: scale)
    }

    private func bitmap(_ host: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Kept from the footer: each window is hovered and read as its words.
    @Test func everyRingAndNumberIsReadInWords() {
        #expect(UsageLine(label: "wk", percent: 61, reset: "Fri 23:33", warning: false, resetInFull: "Friday 23:33").help
                == "Weekly limit, 61 % used, resets Friday 23:33")
        #expect(fiveHour.help == "5-hour limit, 84 % used, resets 16:40")
        #expect(UsageLine(label: "ctx", percent: 84, reset: nil, warning: true).help == "Context 84 % full")
    }

    /// Kept from the footer: a note's ink follows the row's `warning`, never its wording.
    @Test func aNoteIsAmberOnlyWhenTheRowIsAWarning() {
        #expect(StatusBento.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected", warning: true)) == Palette.amber)
        #expect(StatusBento.noteInk(UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected")) == Palette.muted)
    }

    @Test func everyTelemetryRingHasTheSameDiameter() {
        let sizes = [UsageRing(percent: 23, warning: false, size: Size.statusMark),
                     UsageRing(percent: 84, warning: true, size: Size.statusMark)].map { NSHostingView(rootView: $0).fittingSize }
        #expect(sizes.allSatisfy { abs($0.width - Size.statusMark) < 0.5 && abs($0.height - Size.statusMark) < 0.5 })
    }

    /// Two rows of tiles, `Space.base` round and between: a one-line row (`Size.control`) and a
    /// two-line row (`Size.row`). 104 / 119 / 134 pt, with or without the Context tile.
    @Test(arguments: InterfaceScale.all)
    func theBentoIsTwoRowsOfTiles(scale: InterfaceScale) {
        let expected = 3 * scale(Space.base) + scale(Size.control) + scale(Size.row)
        #expect(StatusBento.height(scale) == expected)
        #expect(abs(bento(task: UsageTaskRow(agent: .claude, context: context), scale: scale).fittingSize.height - expected) < 0.5)
        #expect(abs(bento(task: nil, scale: scale).fittingSize.height - expected) < 0.5)
    }

    /// A tile never changes height: a vendor down to one window, or showing a note, is still a
    /// `Size.row` tile.
    @Test func everyTileKeepsItsHeight() {
        let one = host(UsageTile(row: UsageVendorRow(vendor: .claude, lines: [week], note: nil)), width: 166)
        let note = host(UsageTile(row: UsageVendorRow(vendor: .codex, lines: [], note: "No usage data yet")), width: 166)
        #expect(abs(one.fittingSize.height - Size.row) < 0.5)
        #expect(abs(note.fittingSize.height - Size.row) < 0.5)
    }

    /// Every line's words start on one column: the mark's `Size.vendorMark` column, `Space.snug`,
    /// then the words, whatever the mark is, and with none.
    @Test(arguments: InterfaceScale.all)
    func theWordsStartOnOneColumn(scale: InterfaceScale) throws {
        // A literal sRGB red, not `Color.red`: the system red resolves to #FF453A in dark, whose
        // green would miss the probe's threshold.
        let probe = Rectangle().fill(Color(.sRGB, red: 1, green: 0, blue: 0)).frame(width: 6, height: 6)
        let lines: [AnyView] = [
            AnyView(StatusLine { VendorMark(agent: .claude, size: scale(Size.vendorMark)) } words: { probe }),
            AnyView(StatusLine { BackpackMark(tile: .on, size: scale(Size.vendorMark)) } words: { probe }),
            AnyView(StatusLine { Color.clear } words: { probe }),
        ]
        let expected = scale(Size.vendorMark) + scale(Space.snug)
        for line in lines {
            let host = host(line, width: 200, scale: scale)
            let bitmap = try bitmap(host)
            let pxPerPt = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let y = bitmap.pixelsHigh / 2
            let x = (0..<bitmap.pixelsWide).first { px in
                guard let c = bitmap.colorAt(x: px, y: y)?.usingColorSpace(.sRGB) else { return false }
                return c.redComponent > 0.9 && c.greenComponent < 0.2 && c.blueComponent < 0.2
            }
            let start = try #require(x).cgFloat / pxPerPt
            #expect(abs(start - expected) < 1, "at ×\(scale.factor) words start at \(start) pt, not \(expected)")
        }
    }

    /// A usage tile's common case (both windows under 100 %, the weekly one on a later day) paints
    /// whole at each size's narrowest sidebar: the tile is half the width less the gutters.
    @Test(arguments: InterfaceScale.all)
    func aUsageTilesCommonCaseFitsAtTheMinimumWidth(scale: InterfaceScale) throws {
        let row = UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)
        let column = (scale(Size.sidebarMinWidth) - 2 * scale(Space.inset) - scale(Space.base)) / 2
        func painted(_ width: CGFloat) throws -> CGFloat {
            let host = host(UsageTile(row: row), width: width, scale: scale)
            let bitmap = try bitmap(host)
            let pxPerPt = CGFloat(bitmap.pixelsWide) / host.bounds.width
            // Between the rounded corners, against the tile's own fill at its trailing edge.
            let top = Int(scale(Radius.group) * pxPerPt), bottom = bitmap.pixelsHigh - top
            let fill = try #require(bitmap.colorAt(x: Int(column * pxPerPt) - 2, y: bitmap.pixelsHigh / 2))
            for px in stride(from: Int(column * pxPerPt) - 3, through: 0, by: -1) {
                for py in top..<bottom where bitmap.colorAt(x: px, y: py).map({
                    abs($0.redComponent - fill.redComponent) > 0.02 || abs($0.greenComponent - fill.greenComponent) > 0.02
                }) == true { return CGFloat(px) / pxPerPt }
            }
            return 0
        }
        // The tile is drawn at the column's width both times; only the second one is the real one.
        let atColumn = try painted(column)
        #expect(atColumn < column - scale(Space.base) + 1,
                "at ×\(scale.factor) the tile's ink reaches \(atColumn) pt of a \(column) pt tile: it overruns its padding")
        // The tile's own ideal width: hosted unframed, so nothing but its content decides it.
        let natural = NSHostingView(rootView: UsageTile(row: row).fixedSize().interfaceScale(scale)).fittingSize.width
        #expect(natural <= column + 0.5, "at ×\(scale.factor) the tile wants \(natural) pt but has \(column) pt, so it truncates")
    }

    /// Kept from the footer: the reset time is drawn, not just carried on the line.
    @Test func theTileDrawsEachWindowsResetTime() {
        let bare = UsageVendorRow(vendor: .claude, lines: [week.withoutReset, fiveHour.withoutReset], note: nil)
        let dated = UsageVendorRow(vendor: .claude, lines: [week, fiveHour], note: nil)
        let width = { (row: UsageVendorRow) in NSHostingView(rootView: UsageTile(row: row).fixedSize()).fittingSize.width }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let reset = (" \(week.reset!)" as NSString).size(withAttributes: [.font: font]).width
        #expect(abs(width(dated) - width(bare) - reset) < 2)
    }

    /// With nothing selected there is no Context tile and Backpack takes the whole row: the gap
    /// between the columns is tile, not ground.
    @Test func withNothingSelectedBackpackSpansTheRow() throws {
        func gapIsGround(_ task: UsageTaskRow?) throws -> Bool {
            let host = bento(task: task)
            let bitmap = try bitmap(host)
            let pxPerPt = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let gapX = (Size.sidebarMinWidth / 2) * pxPerPt
            let rowY = (Space.base + Size.control / 2) * pxPerPt
            let c = try #require(bitmap.colorAt(x: Int(gapX), y: Int(rowY))?.usingColorSpace(.sRGB))
            return c.redComponent < 0.02 && c.greenComponent < 0.02 && c.blueComponent < 0.02
        }
        #expect(try gapIsGround(UsageTaskRow(agent: .claude, context: context)))
        #expect(try !gapIsGround(nil))
    }
}

private extension Int { var cgFloat: CGFloat { CGFloat(self) } }

private extension UsageLine {
    var withoutReset: UsageLine { UsageLine(label: label, percent: percent, reset: nil, warning: warning) }
}
