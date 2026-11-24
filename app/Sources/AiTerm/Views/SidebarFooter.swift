import SwiftUI
import AiTermUI
import AiTermCore

/// The sidebar's foot, on the list's grid: System, then Usage, split by a rule. System is the
/// selected task's or terminal's context, under its active tab's mark, then the Mac under its
/// `macbook` mark. Usage is one row per vendor with its account windows. With nothing selected
/// System holds the Mac alone.
///
/// Every row is its mark and three columns of equal width, `Space.gap` apart (16 Nov 2026, after
/// "Equal halves" of 15 Nov), and every column is one reading built the same way: its label, its
/// ring, its number: `wk ◔ 61%`. The label sits in the width of the widest label and the number in
/// the width of `100%`, so the rings stand in three straight lines down the footer whatever the
/// digits. The weekly window is a vendor's first column, being the one every vendor has: Codex
/// reports nothing else, so a missing reading is always a later column, as on the context's row.
/// The Mac's row is `cpu | ram | bat`, the battery only while it is the Mac's power. It is read,
/// not clicked: ⌘B is Backpack Mode's one switch, and a right-click offers Mac Settings… (18 Nov 2026).
///
/// A group's heading may carry one status, joined to its words: `System · backpack mode`, in the
/// heading's face and the status's `SettingsTone` (proposal 1B and 2A, 18 Nov 2026). It is there
/// only while something is out of the ordinary, so it costs no row and the footer keeps one height
/// whatever it says. System's is Backpack Mode while it is on or switching. Usage has none yet; a
/// status about the whole group, never one vendor's reading, would go there.
///
/// Its labels keep their short lowercase forms (`ctx`, `wk`, `5h`, `cpu`, `ram`, `bat`), set with
/// tabular figures in the system face (`Typography.help.tabular`), on a ground of its own a step
/// darker than the window (`Palette.sidebarFooter`).
///
/// It sits on the list's grid rather than its own (proposal A, 23 Sep 2026): the headings are the
/// Projects header's treatment, the rows are ``Size/menuRow`` like the header and `DividerRow`,
/// and the ink runs from the header's leading edge to the status column's — the list's inset plus
/// `Space.base` on both sides. Each group has the footer's own padding, `Space.tight` above and
/// `Space.base` below, so the rule between them reads like the scroll-edge hairline above both.
///
/// When a window clears is shown under the pointer only, as a chip on the popover's ground just
/// above the reading, `resets Sat 12:00` (``ResetBadge``): at rest the row is the numbers alone, and
/// the chip stands in for a tooltip. A reading with no clock — `ctx` and the Mac's — raises nothing:
/// its ring and number already say all its tooltip did (18 Nov 2026).
///
/// Every ring and number is drawn in one of two inks, `Palette.text` or `Palette.amber` past the
/// warning threshold — for the Mac's readings, when macOS itself warns — whatever the agent is
/// doing: an idle vendor's last reading is still its reading, and a dimmed ring beside a bright one
/// reads as a different kind of mark. A heading's status is the one other colour.
struct SidebarFooter: View {
    let task: UsageTaskRow?
    let rows: [UsageVendorRow]
    /// The Mac's readings, in their order (`MachineMonitor`). Empty, the row draws its mark alone.
    var machine: [UsageLine] = []
    /// The Mac's mode, as one drawn line. The defaults draw a Mac at its desk.
    var mac: MacModeLine = MacModePresentation.line(mode: .desk, hotspot: nil, wifi: nil)
    /// A right-click on the Mac's rows opens Mac Settings.
    var openMacSettings: () -> Void = {}
    /// The snapshots' stand-in for the pointer: the first reading of this window draws its
    /// ``ResetBadge`` as if hovered. Nil in the app.
    var hovering: UsageLine.Window? = nil
    @Environment(\.interfaceScale) private var scale

    /// The first group's heading. It holds more than the context, so the context row names its
    /// gauge with `ctx`.
    static let systemHeading = "System"
    /// The Mac's mark on its readings row, as the Mac card draws it.
    static let macSymbol = "macbook"
    /// The widest a number gets: every number sits in this width, so its column's width is known.
    static let widestNumber = "100%"
    /// How many readings a row holds side by side.
    static let columns = 3

    /// What one column of a row holds.
    private enum Column {
        case reading(UsageLine)
        /// Words in an ink of their own: "No context yet".
        case words(String, Color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group(systemHeading) {
                if let task {
                    columns(mark: vendorMark(task.agent), Self.contextColumns(task))
                }
                macRows
            }
            Hairline()
            group(SidebarHeading("Usage")) {
                ForEach(rows, id: \.vendor) { row in
                    if let note = row.note {
                        telemetryRow(mark: vendorMark(row.vendor.session)) {
                            Text(note).foregroundStyle(Self.noteInk(row))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        columns(mark: vendorMark(row.vendor.session), row.lines.map(Column.reading))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebarFooter)
        .overlay(alignment: .top) { Hairline() }
    }

    /// The context's column, "No context yet" while an agent has not reported, or nothing for a shell.
    private static func contextColumns(_ task: UsageTaskRow) -> [Column] {
        if let context = task.context { return [.reading(context)] }
        return task.agent == .shell ? [] : [.words("No context yet", Palette.muted)]
    }

    /// The Mac's row: its readings under its mark, read out as one element (before the first
    /// sample it says "Mac").
    private var macRows: some View {
        macMenu(
            columns(mark: SymbolMark(symbol: Self.macSymbol, size: scale(Size.vendorMark)), machine.map(Column.reading))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.readingsLabel(machine))
        )
    }

    /// System's heading, then while Backpack Mode is on or switching its status joined to it:
    /// `System · backpack mode`, read out as the mode's sentence.
    private var systemHeading: some View {
        HStack(spacing: 0) {
            SidebarHeading(Self.systemHeading)
            if let tone = mac.mode.tone, let words = mac.mode.words {
                macMenu(
                    Text(Self.headingStatus(words)).font(SidebarHeading.style).foregroundStyle(tone.color)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(mac.help)
                )
            }
        }
        .lineLimit(1)
    }

    /// A status's words as they follow a heading's own: `System · backpack mode`.
    static func headingStatus(_ words: String) -> String { " · \(words)" }

    /// The readings row's VoiceOver label: each reading's words, or "Mac" while there are none.
    static func readingsLabel(_ machine: [UsageLine]) -> String {
        machine.isEmpty ? "Mac" : machine.map(\.help).joined(separator: ", ")
    }

    /// What makes a row the Mac's: a right-click offers Mac Settings….
    private func macMenu(_ row: some View) -> some View {
        row
            .contentShape(Rectangle())
            .contextMenu { Button("Mac Settings…", action: openMacSettings) }
    }

    /// Amber, like the iTerm2 banner's warning, for a feed that is broken; a quiet one's note recedes.
    static func noteInk(_ row: UsageVendorRow) -> Color { row.warning ? Palette.amber : Palette.muted }

    /// The footer sits below the `List`, not in it, so it adds the list's own inset — the
    /// `Space.inset` the snapshot harness stands in for it with — to the rows' `Space.base`.
    private var edge: CGFloat { scale(Space.inset) + scale(Space.base) }

    /// A heading in the Projects header's treatment, with its status when it has one, then its
    /// rows, in the footer's own padding.
    private func group(_ heading: some View, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
                .frame(height: scale(Size.menuRow))
            rows()
        }
        .padding(.horizontal, edge)
        .padding(.top, scale(Space.tight))
        .padding(.bottom, scale(Space.base))
    }

    private func vendorMark(_ agent: SessionAgent) -> VendorMark { VendorMark(agent: agent, size: scale(Size.vendorMark)) }

    /// One footer line: a mark in the ``Size/vendorMark`` column, `Space.inset`, then what it holds,
    /// in the telemetry's face: the system's, with tabular figures so a changing number keeps its width.
    private func telemetryRow(mark: some View, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: scale(Space.inset)) {
            mark
            content()
        }
        .font(Typography.help.tabular)
        .lineLimit(1)
        .frame(height: scale(Size.menuRow), alignment: .leading)
    }

    /// A row's columns, equal because each takes all it is offered; a missing column is empty, and
    /// a reading past the last column is not drawn.
    private func columns(mark: some View, _ parts: [Column]) -> some View {
        telemetryRow(mark: mark) {
            HStack(spacing: scale(Space.gap)) {
                ForEach(0..<Self.columns, id: \.self) { index in
                    column(parts.indices.contains(index) ? parts[index] : nil)
                }
            }
        }
    }

    @ViewBuilder private func column(_ part: Column?) -> some View {
        Group {
            switch part {
            case .reading(let line): Reading(line: line, hovered: line.window == hovering)
            case .words(let words, let ink): Text(words).foregroundStyle(ink)
            case nil: Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `text`, leading, in the width of the widest of `among`, so what follows it starts at the
    /// same x on every row.
    static func widest(_ text: String, among: [String]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(among, id: \.self) { Text($0).hidden() }
            Text(text)
        }
        .accessibilityHidden(true)
    }
}

/// One reading — label, ring and number — read as its words: the glyphs alone say "wk" and a ring.
/// A zero-spacing stack keeps colour changes from adding invisible gaps; the space lives inside a
/// `Text`. Under the pointer, a window that clears raises its ``ResetBadge`` above it at once; a
/// reading with no clock raises nothing.
private struct Reading: View {
    let line: UsageLine
    @Environment(\.interfaceScale) private var scale
    @State private var hovered: Bool

    init(line: UsageLine, hovered: Bool = false) {
        self.line = line
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Reserve the full hit area. Only the visible reading anchors the raised chip.
            reading(SidebarFooter.widestNumber).hidden()
            reading("\(line.percent)%")
                .raisingHoverChip(line.reset.map(ResetBadge.chip), shown: hovered)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.help)
    }

    private func reading(_ number: String) -> some View {
        HStack(spacing: 0) {
            SidebarFooter.widest(line.window.shortLabel, among: UsageLine.Window.allCases.map(\.shortLabel))
                .foregroundStyle(Palette.muted)
                .padding(.trailing, scale(Space.tight))
            UsageRing(percent: line.percent, warning: line.warning, size: scale(Size.statusMark))
            Text(" ")
            Text(number)
                .foregroundStyle(line.warning ? Palette.amber : Palette.text)
        }
    }
}

/// When a window clears, `resets Sat 12:00`, on a `HoverChip`. The time is the news, in `text`; the
/// word before it recedes.
struct ResetBadge: View {
    let reset: String

    static func chip(_ reset: String) -> HoverChip {
        HoverChip(Text("\(Text("resets ").foregroundStyle(Palette.muted))\(reset)"))
    }

    var body: some View { Self.chip(reset) }
}

/// The fill beside a telemetry number: a ring that closes clockwise as the window fills.
///
/// Deliberately not a primitive — the reuse ladder in `AiTermUI/README.md` promotes a pattern only
/// once a second file needs it, and this is the footer's alone. It is drawn to `StatusMark`'s
/// recipe (same diameter, same `size * 0.15` stroke, same round cap) so the two round marks in the
/// sidebar read as one family rather than as two people's circles.
struct UsageRing: View {
    let percent: Int
    let warning: Bool
    /// The ring's diameter in points; the caller scales ``Size/statusMark``.
    let size: CGFloat

    /// How much of the circle to close. Clamped, because the percentage is another process's
    /// arithmetic and `trim(from:to:)` past 1 wraps back over the ring's own start.
    static func fill(_ percent: Int) -> CGFloat { min(1, max(0, CGFloat(percent) / 100)) }

    var body: some View {
        ZStack {
            Circle().strokeBorder(Palette.spinnerTrack, lineWidth: RingGeometry.strokeWidth(size))
            Circle()
                .trim(from: 0, to: Self.fill(percent))
                .stroke(warning ? Palette.amber : Palette.text,
                        style: StrokeStyle(lineWidth: RingGeometry.strokeWidth(size), lineCap: .round))
                // `trim` starts at three o'clock; a fill reads as rising from the top.
                .rotationEffect(.degrees(-90))
                // `strokeBorder` insets by half its width, `stroke` straddles the path — inset the
                // fill to match, or it paints a hair outside the track it is supposed to fill.
                .padding(RingGeometry.inset(size))
        }
        .frame(width: size, height: size)
    }
}
