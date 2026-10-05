import SwiftUI
import AiTermUI
import AiTermCore

/// The sidebar's foot: live status as an always-open bento (spec 2026-10-05). Two equal columns
/// `Space.base` apart, `Space.base` above and below, the list's `Space.inset` either side so the
/// tiles' edges line up with the rows' pills. Row one: the selected task's context and Backpack Mode,
/// one line each; with nothing selected Backpack spans it. Row two: Claude and Codex, two lines each.
/// The scroll-edge hairline overlays its top, as it did the usage footer's. Nothing here resizes,
/// reflows or animates on a reading; a reading at 80 % or more only turns amber.
struct StatusBento: View {
    let task: UsageTaskRow?
    let rows: [UsageVendorRow]
    let backpack: BackpackController
    let openBackpackSettings: () -> Void
    @Environment(\.interfaceScale) private var scale

    /// The bento's height at `scale`: a one-line row, a two-line row, and the three gaps.
    static func height(_ scale: InterfaceScale) -> CGFloat {
        3 * scale(Space.base) + scale(Size.control) + scale(Size.row)
    }

    /// Amber for a feed that is broken; a quiet one's note recedes. As the usage footer had it.
    static func noteInk(_ row: UsageVendorRow) -> Color { row.warning ? Palette.amber : Palette.muted }

    var body: some View {
        let gap = scale(Space.base)
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                if let task { ContextTile(task: task) }
                BackpackTile(backpack: backpack, openSettings: openBackpackSettings)
            }
            HStack(spacing: gap) {
                ForEach(rows, id: \.vendor) { UsageTile(row: $0) }
            }
        }
        .padding(.vertical, gap)
        .padding(.horizontal, scale(Space.inset))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// A bento tile's box: `Palette.badge` at `Radius.group`, `Space.base` across, one line tall
/// (`Size.control`) or two (`Size.row`, a task row's two lines). It takes its column's width and never
/// its content's height.
struct StatusTile<Content: View>: View {
    let lines: Int
    let content: Content
    @Environment(\.interfaceScale) private var scale

    init(lines: Int, @ViewBuilder content: () -> Content) {
        self.lines = lines
        self.content = content()
    }

    var body: some View {
        let height = scale(lines == 1 ? Size.control : Size.row)
        VStack(alignment: .leading, spacing: scale(Space.tight)) { content }
            .padding(.horizontal, scale(Space.base))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: scale(Radius.group)).fill(Palette.badge))
    }
}

/// One line of a tile: its mark in a `Size.vendorMark` column, `Space.snug`, then the words, so every
/// tile's words start on one column. A line with no mark passes `Color.clear` and keeps the column.
struct StatusLine<Mark: View, Words: View>: View {
    let mark: Mark
    let words: Words
    @Environment(\.interfaceScale) private var scale

    init(@ViewBuilder mark: () -> Mark, @ViewBuilder words: () -> Words) {
        self.mark = mark()
        self.words = words()
    }

    var body: some View {
        HStack(spacing: scale(Space.snug)) {
            mark.frame(width: scale(Size.vendorMark), height: scale(Size.vendorMark))
            words
            Spacer(minLength: 0)
        }
        .font(Typography.mono)
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// One rate-limit window, or the context: label, ring, number and reset in `Typography.mono`, read
/// and hovered as its words (`UsageLine.help`).
struct UsageWindow: View {
    let line: UsageLine
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            Text(line.label + " ").foregroundStyle(Palette.muted)
            UsageRing(percent: line.percent, warning: line.warning, size: scale(Size.statusMark))
            Text(" \(line.percent)%").foregroundStyle(line.warning ? Palette.amber : Palette.text)
            // The percentage is the number being watched; the reset recedes behind it.
            if let reset = line.reset { Text(" " + reset).foregroundStyle(Palette.muted) }
        }
        .contentShape(Rectangle())
        .help(line.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.help)
    }
}

/// The selected task's or terminal's context, one line: the active tab's mark, then `ctx`. A shell
/// has no context and draws its mark alone; an agent that has not reported says so.
struct ContextTile: View {
    let task: UsageTaskRow
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        StatusTile(lines: 1) {
            StatusLine { VendorMark(agent: task.agent, size: scale(Size.vendorMark)) } words: {
                if let context = task.context {
                    UsageWindow(line: context)
                } else if task.agent != .shell {
                    Text("No context yet").font(Typography.help).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}

/// A vendor's account windows, two lines: its mark and first window, then its second on the text
/// column. One window left draws one line; a note draws in its ink. Either way the tile keeps its
/// height.
struct UsageTile: View {
    let row: UsageVendorRow
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        StatusTile(lines: 2) {
            if let note = row.note {
                StatusLine { VendorMark(agent: row.vendor.session, size: scale(Size.vendorMark)) } words: {
                    Text(note).font(Typography.help).foregroundStyle(StatusBento.noteInk(row))
                }
            } else {
                ForEach(Array(row.lines.enumerated()), id: \.offset) { index, line in
                    StatusLine {
                        if index == 0 { VendorMark(agent: row.vendor.session, size: scale(Size.vendorMark)) } else { Color.clear }
                    } words: {
                        UsageWindow(line: line)
                    }
                }
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
