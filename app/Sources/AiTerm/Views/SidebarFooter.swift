import SwiftUI
import AiTermUI
import AiTermCore

/// The sidebar's foot, on the list's grid: System, then Usage, split by a rule. System is the
/// selected task's or terminal's context, under its active tab's mark, then the Mac under its
/// `macbook` mark. Usage is one row per vendor with its account windows. With nothing selected
/// System holds the Mac alone.
///
/// Every row is its mark and two halves of equal width, `Space.gap` apart (proposal "Equal halves",
/// 15 Nov 2026), and every half is one reading built the same way: its label, its ring, its number,
/// its reset: `wk ◔ 61% Sat 12:00`. The label sits in the width of the widest label and the number
/// in the width of `100%`, so the rings stand in two straight lines down the footer and the resets
/// line up too, whatever the digits. The weekly window is a vendor's left half, being the one every
/// vendor has: Codex reports nothing else, so a missing reading is always a right half, as on the
/// context's row. The Mac's first row is `cpu | ram`; on battery, or while Unplugged is on or
/// switching, a second row holds `bat` and the mode's line in its `SettingsTone`, `○ unplugged`,
/// filling from the left. A click on the Mac's rows is ⌘U.
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
/// Every window shows when it clears, so the row answers "how much is left, and until when?"
/// without being hovered. `ctx` and the Mac's readings are the exception and carry no clock: a
/// conversation's context is emptied by compaction, not by a reset time, and the Mac's are now.
///
/// Every ring and number is drawn in one of two inks, `Palette.text` or `Palette.amber` past the
/// warning threshold — for the Mac's readings, when macOS itself warns — whatever the agent is
/// doing: an idle vendor's last reading is still its reading, and a dimmed ring beside a bright one
/// reads as a different kind of mark. The Unplugged line is the one other colour.
struct SidebarFooter: View {
    let task: UsageTaskRow?
    let rows: [UsageVendorRow]
    /// The Mac's readings, in their order (`MachineMonitor`). Empty, the row draws its mark alone.
    var machine: [UsageLine] = []
    /// The Mac's mode, as one drawn line (spec 2026-10-05). The defaults draw a Mac at its desk.
    var mac: MacModeLine = MacModePresentation.line(mode: .desk, hotspot: nil, wifi: nil)
    /// A click on the Mac's rows.
    var toggleMac: () -> Void = {}
    /// A right-click on them opens Mac Settings.
    var openMacSettings: () -> Void = {}
    @Environment(\.interfaceScale) private var scale

    /// The first group's heading. It holds more than the context, so the context row names its
    /// gauge with `ctx`.
    static let systemHeading = "System"
    /// The Mac's mark on its readings row, as the Mac card draws it.
    static let macSymbol = "macbook"
    /// The widest a number gets: every number sits in this width, so the resets after it line up.
    static let widestNumber = "100%"

    /// What one half of a row holds.
    private enum Half {
        case reading(UsageLine)
        /// Words in an ink of their own: "No context yet".
        case words(String, Color)
        /// The Mac's mode while Unplugged is on or switching.
        case mode(SettingsTone, String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group(Self.systemHeading) {
                if let task {
                    halves(mark: vendorMark(task.agent), Self.contextHalves(task))
                }
                macRows
            }
            Hairline()
            group("Usage") {
                ForEach(rows, id: \.vendor) { row in
                    if let note = row.note {
                        telemetryRow(mark: vendorMark(row.vendor.session)) {
                            Text(note).foregroundStyle(Self.noteInk(row))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        halves(mark: vendorMark(row.vendor.session), row.lines.map(Half.reading))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sidebarFooter)
        .overlay(alignment: .top) { Hairline() }
    }

    /// The context's half, "No context yet" while an agent has not reported, or nothing for a shell.
    private static func contextHalves(_ task: UsageTaskRow) -> [Half] {
        if let context = task.context { return [.reading(context)] }
        return task.agent == .shell ? [] : [.words("No context yet", Palette.muted)]
    }

    /// The Mac's rows: its readings under its mark, read out as one element (before the first
    /// sample it is still the Mac's button, so it says "Mac"); then, on battery or while Unplugged
    /// is on or switching, the battery and the mode's line on a row of their own.
    @ViewBuilder private var macRows: some View {
        let parts = Self.macParts(machine)
        macControl(
            halves(mark: SymbolMark(symbol: Self.macSymbol, size: scale(Size.vendorMark)), parts.readings.map(Half.reading))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.readingsLabel(parts.readings))
                .accessibilityHint(mac.help)
        )
        let mode: [Half] = if let tone = mac.mode.tone, let words = mac.mode.words { [.mode(tone, words)] } else { [] }
        if !parts.battery.isEmpty || !mode.isEmpty {
            macControl(
                halves(mark: Color.clear.frame(width: scale(Size.vendorMark)), parts.battery.map(Half.reading) + mode)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel((parts.battery.map(\.help) + (mode.isEmpty ? [] : [mac.help])).joined(separator: ", "))
            )
        }
    }

    /// The Mac's readings split into its first row's and the battery, which goes on the second.
    static func macParts(_ machine: [UsageLine]) -> (readings: [UsageLine], battery: [UsageLine]) {
        (machine.filter { $0.window != .battery }, machine.filter { $0.window == .battery })
    }

    /// The readings row's VoiceOver label: each reading's words, or "Mac" while there are none.
    static func readingsLabel(_ machine: [UsageLine]) -> String {
        machine.isEmpty ? "Mac" : machine.map(\.help).joined(separator: ", ")
    }

    /// What makes a row the Mac's: a click is ⌘U, a right-click offers Mac Settings…, and the mode's
    /// sentence is its tooltip wherever a reading's own does not cover it.
    private func macControl(_ row: some View) -> some View {
        row
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleMac)
            .contextMenu { Button("Mac Settings…", action: openMacSettings) }
            .help(mac.help)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggleMac)
    }

    /// Amber, like the iTerm2 banner's warning, for a feed that is broken; a quiet one's note recedes.
    static func noteInk(_ row: UsageVendorRow) -> Color { row.warning ? Palette.amber : Palette.muted }

    /// The footer sits below the `List`, not in it, so it adds the list's own inset — the
    /// `Space.inset` the snapshot harness stands in for it with — to the rows' `Space.base`.
    private var edge: CGFloat { scale(Space.inset) + scale(Space.base) }

    /// A heading in the Projects header's treatment, then its rows, in the footer's own padding.
    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeading(title)
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

    /// A row's two halves, equal because both take all they are offered; a missing half is empty.
    private func halves(mark: some View, _ parts: [Half]) -> some View {
        telemetryRow(mark: mark) {
            HStack(spacing: scale(Space.gap)) {
                half(parts.first)
                half(parts.dropFirst().first)
            }
        }
    }

    @ViewBuilder private func half(_ part: Half?) -> some View {
        Group {
            switch part {
            case .reading(let line): reading(line)
            case .words(let words, let ink): Text(words).foregroundStyle(ink)
            case .mode(let tone, let words):
                HStack(spacing: scale(Space.tight)) {
                    ToneRing(tone: tone, size: scale(Size.statusMarkSmall))
                    Text(words).foregroundStyle(tone.color)
                }
            case nil: Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One reading — label, ring, number and reset — hovered and read as its words: the glyphs
    /// alone say "wk", a ring and "Sat". A zero-spacing stack keeps colour changes from adding
    /// invisible gaps; the spaces live inside the `Text`s.
    private func reading(_ line: UsageLine) -> some View {
        HStack(spacing: 0) {
            Self.widest(line.window.shortLabel, among: UsageLine.Window.allCases.map(\.shortLabel))
                .foregroundStyle(Palette.muted)
                .padding(.trailing, scale(Space.tight))
            UsageRing(percent: line.percent, warning: line.warning, size: scale(Size.statusMark))
            Text(" ")
            // The percentage is the number being watched; the reset recedes behind it.
            Self.widest("\(line.percent)%", among: [Self.widestNumber])
                .foregroundStyle(line.warning ? Palette.amber : Palette.text)
            if let reset = line.reset { Text(" " + reset).foregroundStyle(Palette.muted) }
        }
        .contentShape(Rectangle())
        .help(line.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.help)
    }

    /// `text`, leading, in the width of the widest of `among`, so what follows it starts at the
    /// same x on every row.
    private static func widest(_ text: String, among: [String]) -> some View {
        ZStack(alignment: .leading) {
            ForEach(among, id: \.self) { Text($0).hidden() }
            Text(text)
        }
        .accessibilityHidden(true)
    }
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
