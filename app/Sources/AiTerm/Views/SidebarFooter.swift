import SwiftUI
import AiTermUI
import AiTermCore

/// The sidebar's foot, on the list's grid: SYSTEM, then USAGE, split by a rule. SYSTEM is the
/// selected task's or terminal's context — its active tab's mark, `ctx`, the ring and the fill — and
/// (spec 2026-10-05) the Mac's mode. USAGE is one row per vendor with its account windows:
/// `Ⓒ wk ◔ 84% Mon 21:00 · 5h ◔ 23% 16:40`. With nothing selected the context row is absent.
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
struct SidebarFooter: View {
    let task: UsageTaskRow?
    let rows: [UsageVendorRow]
    @Environment(\.interfaceScale) private var scale

    /// The first group's heading. It holds more than the context now, so the row names its gauge.
    static let systemHeading = "System"
    /// Whether the context row carries its `ctx` label: it does, since the heading no longer says it.
    static let labelsContext = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let task {
                group(Self.systemHeading) {
                    telemetryRow(task.agent) {
                        if let context = task.context {
                            usageWindows([context], labelled: Self.labelsContext)
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
            Circle().strokeBorder(Palette.spinnerTrack, lineWidth: size * 0.15)
            Circle()
                .trim(from: 0, to: Self.fill(percent))
                .stroke(warning ? Palette.amber : Palette.text,
                        style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                // `trim` starts at three o'clock; a fill reads as rising from the top.
                .rotationEffect(.degrees(-90))
                // `strokeBorder` insets by half its width, `stroke` straddles the path — inset the
                // fill to match, or it paints a hair outside the track it is supposed to fill.
                .padding(size * 0.15 / 2)
        }
        .frame(width: size, height: size)
    }
}
