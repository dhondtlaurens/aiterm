import SwiftUI
import AiTermUI
import AiTermCore

/// Compact provider telemetry in two named groups split by a rule. First CONTEXT, the selected task
/// or terminal: the mark of what runs in its active tab and that agent's context fill —
/// `Ⓒ ◔ 42%`, or the shell's mark alone. The heading says what the number is, so the row carries no
/// `ctx` label, and the room after the number is left for its note ("No context yet"). Then USAGE,
/// one row per vendor with its account windows: `Ⓒ wk ◔ 84% Mon 21:00 · 5h ◔ 23% 16:40`. With
/// nothing selected the CONTEXT group and its rule are absent.
///
/// It sits on the list's grid rather than its own (proposal A, 23 Sep 2026): the headings are the
/// `PROJECTS` header's treatment, the rows are ``Size/menuRow`` like the header and `DividerRow`,
/// and the ink runs from the header's leading edge to the status column's — the list's inset plus
/// `Space.base` on both sides. Each group has the footer's own padding, `Space.tight` above and
/// `Space.base` below, so the rule between them reads like the scroll-edge hairline above both.
///
/// Every window shows when it clears, so the row answers "how much is left, and until when?"
/// without being hovered. `ctx` is the exception and carries no clock: a conversation's context is
/// emptied by compaction, not by a reset time. Paying for the clock times in width rather than in a
/// wider fill keeps the numbers glanceable; ``Size/sidebarMinWidth`` is sized to the resulting common
/// case.
///
/// Every ring and number is drawn in one of two inks, `Palette.text` or `Palette.amber` past the
/// warning threshold, whatever the agent is doing: an idle vendor's last reading is still its
/// reading, and a dimmed ring beside a bright one reads as a different kind of mark.
struct UsageFooter: View {
    let task: UsageTaskRow?
    let rows: [UsageVendorRow]
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let task {
                group("Context") {
                    telemetryRow(task.agent) {
                        if let context = task.context {
                            usageWindows([context], labelled: false)
                        } else if task.agent != .shell {
                            // A shell has no context to wait for; an agent has not reported yet.
                            Text("No context yet").foregroundStyle(Palette.muted)
                        }
                    }
                }
                Hairline()
            }
            group("Usage") {
                ForEach(rows, id: \.vendor) { row in
                    telemetryRow(row.vendor.session) {
                        if let note = row.note {
                            Text(note).foregroundStyle(Self.noteInk(row))
                        } else {
                            usageWindows(row.lines)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }

    /// Amber, like the iTerm2 banner's warning, for a feed that is broken; a quiet one's note recedes.
    static func noteInk(_ row: UsageVendorRow) -> Color { row.warning ? Palette.amber : Palette.muted }

    /// The footer sits below the `List`, not in it, so it adds the list's own inset — the
    /// `Space.inset` the snapshot harness stands in for it with — to the rows' `Space.base`.
    private var edge: CGFloat { scale(Space.inset) + scale(Space.base) }

    /// A heading in the `PROJECTS` header's treatment, then its rows, in the footer's own padding.
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

    /// One footer line: a vendor mark, then its readings in the telemetry's mono face.
    private func telemetryRow(_ agent: SessionAgent, @ViewBuilder readings: () -> some View) -> some View {
        HStack(alignment: .center, spacing: scale(Space.inset)) {
            VendorMark(agent: agent, size: scale(Size.vendorMark))
            readings()
            Spacer(minLength: 0)
        }
        .font(Typography.mono)
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: scale(Size.menuRow), alignment: .leading)
    }

    /// A zero-spacing stack keeps punctuation and colour changes from adding invisible layout
    /// gaps; each segment's own spaces live inside its `Text`, so the ring sits in the gap the
    /// four-cell bar used to occupy. `usageVendorRows` supplies wk before 5h; this renderer
    /// preserves that order. `labelled: false` drops the window's label where a heading already
    /// names it — the CONTEXT row's `ctx`.
    private func usageWindows(_ lines: [UsageLine], labelled: Bool = true) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if index > 0 { Text(" · ").foregroundStyle(Palette.muted).accessibilityHidden(true) }
                // One element per window — label, ring, number and reset — read and hovered as its
                // words: the glyphs alone say "wk", a ring and "Sat".
                HStack(spacing: 0) {
                    if labelled { Text(line.label + " ").foregroundStyle(Palette.muted) }
                    UsageRing(percent: line.percent, warning: line.warning, size: scale(Size.statusMark))
                    Text(" \(line.percent)%")
                        .foregroundStyle(line.warning ? Palette.amber : Palette.text)
                    // The percentage is the number being watched; the reset recedes behind it.
                    if let reset = line.reset { Text(" " + reset).foregroundStyle(Palette.muted) }
                }
                .contentShape(Rectangle())
                .help(line.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.help)
            }
        }
    }
}
