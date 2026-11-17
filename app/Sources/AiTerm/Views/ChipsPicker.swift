import SwiftUI
import AiTermUI
import AiTermCore

/// One pick in a `ChipsPicker`: the service's mark, its name in `Typography.caption`, and the ✕ that
/// removes it, on the badge wash at `Radius.chip`, `lineHeight` tall (the design's lane chip).
struct PickChip: View {
    let mark: IconSource
    let label: String
    let remove: () -> Void

    /// `Size.chip`, and room for the caption: the chip's height, and the search field's beside it.
    static var lineHeight: CGFloat { Size.chip + Space.tight }

    var body: some View {
        let removeHelp = "Remove \(label)"
        return HStack(spacing: Space.tight) {
            Icon(mark, size: Size.pickerRowLogo)
            // The label gives way when the chip is narrower than it wants to be: the mark and the ✕ keep their size.
            Text(label).font(Typography.caption).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
            PickerClearButton(help: removeHelp, accessibilityLabel: removeHelp, action: remove)
        }
        .padding(.horizontal, Space.snug).frame(height: Self.lineHeight)
        .chipChrome(fill: Palette.badge)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A field of several picks: each a `PickChip`, then a search field after them that adds one more,
/// its results hanging under the field in a `DropdownList`, with keyboard navigation through
/// `DropdownKeys.perform`. The field wraps onto more lines as the chips fill it (`ChipFlow`). A click on it, or
/// typing, opens the list — not focus alone, which a sheet's first field gets as the sheet appears, so the list
/// never covers the fields under it before the person asks for it. A pick joins the chips and the field stays
/// for the next one. The caller
/// keeps `open`, since the sheet closes the list from outside: ⎋, and a click past it.
///
/// `inlineResults` lays the list out under the field instead of over what follows: a popover is sized to its content
/// and clips anything hanging past its edge, so there the list must take room of its own.
struct ChipsPicker<Item: Identifiable, Row: View>: View {
    let placeholder: String
    let picks: [Item]
    @Binding var open: Bool
    let matches: (String) -> [Item]
    let mark: (Item) -> IconSource
    let label: (Item) -> String
    let row: (Item) -> Row
    let onPick: (Item) -> Void
    let onRemove: (Item) -> Void
    private let externalQuery: Binding<String>?
    private let selectionLimit: Int?
    private let inlineResults: Bool
    @State private var query: String = ""
    @State private var index: Int = 0
    @State private var focused: Bool = false

    /// At most six result rows.
    static var visibleLimit: Int { 6 }

    init(placeholder: String, picks: [Item], open: Binding<Bool>, matches: @escaping (String) -> [Item],
         mark: @escaping (Item) -> IconSource, label: @escaping (Item) -> String, @ViewBuilder row: @escaping (Item) -> Row,
         onPick: @escaping (Item) -> Void, onRemove: @escaping (Item) -> Void, query: Binding<String>? = nil, selectionLimit: Int? = nil,
         inlineResults: Bool = false) {
        self.placeholder = placeholder; self.picks = picks; self._open = open; self.matches = matches
        self.mark = mark; self.label = label; self.row = row; self.onPick = onPick; self.onRemove = onRemove
        self.externalQuery = query; self.selectionLimit = selectionLimit; self.inlineResults = inlineResults
    }

    private var text: Binding<String> { externalQuery ?? $query }
    private var canAdd: Bool { selectionLimit.map { picks.count < $0 } ?? true }
    private var visible: [Item] { Array(matches(text.wrappedValue).prefix(Self.visibleLimit)) }

    var body: some View {
        Group {
            if inlineResults {
                VStack(alignment: .leading, spacing: Space.tight) { field; results }
            } else {
                // Under the field, `Space.tight` below it, however many lines the chips take.
                field.overlay(alignment: .bottomLeading) {
                    results.alignmentGuide(.bottom) { $0[.top] - Space.tight }
                }
            }
        }
        .onChange(of: open, initial: true) { _, open in if open { index = 0 } }
    }

    private var field: some View {
        ChipFlow(spacing: Space.tight, hasField: canAdd) {
            ForEach(picks) { item in PickChip(mark: mark(item), label: label(item)) { onRemove(item) } }
            if canAdd { SearchField(placeholder: placeholder,
                        text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = $0; open = true; index = 0 }),
                        focused: $focused, onCommand: command, onClick: { open = true })
                .frame(height: PickChip.lineHeight) }
        }
        .padding(.horizontal, Space.inset).padding(.vertical, Space.tight)
        .frame(maxWidth: .infinity, minHeight: Size.control, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if canAdd { focused = true; open = true } }
        .fieldBox(focused: focused)
    }

    @ViewBuilder private var results: some View {
        let shown = visible
        if canAdd, open, !shown.isEmpty {
            DropdownList(items: shown, index: $index, onPick: pick, row: row)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func command(_ selector: Selector) -> Bool {
        DropdownKeys.perform(selector, on: visible, index: $index, open: $open, listening: open, pick: pick)
    }

    private func pick(_ item: Item) {
        onPick(item)
        text.wrappedValue = ""
        open = false
        index = 0
    }
}

/// Lays chips out in lines `spacing` apart, wrapping as a line fills, a chip never wider than a line; the last subview, the search
/// field, takes the rest of its line, and starts a line of its own when less than `fieldMinWidth` is left.
struct ChipFlow: Layout {
    let spacing: CGFloat
    var hasField = true
    /// Room for the placeholder ("Add a Jira project") beside the chips before the field wraps.
    static let fieldMinWidth: CGFloat = 140

    private struct Placement { var origin: CGPoint, size: CGSize }

    private func arrange(_ subviews: Subviews, width proposed: CGFloat?) -> (placements: [Placement], size: CGSize) {
        let width = proposed ?? .infinity
        var placements: [Placement] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        var line: [Int] = []
        func endLine() {
            for i in line { placements[i].origin.y = y + (lineHeight - placements[i].size.height) / 2 }
            y += lineHeight + spacing; x = 0; lineHeight = 0; line = []
        }
        for (i, subview) in subviews.enumerated() {
            let isField = hasField && i == subviews.count - 1
            var size: CGSize
            if isField {
                if x > 0, x + Self.fieldMinWidth > width { endLine() }
                let rest = width.isFinite ? width - x : Self.fieldMinWidth
                size = subview.sizeThatFits(ProposedViewSize(width: max(rest, Self.fieldMinWidth), height: nil))
                size.width = max(rest, Self.fieldMinWidth)
            } else {
                // Never wider than the field: a long label truncates inside its chip, the ✕ stays in view.
                size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
                if x > 0, x + size.width > width { endLine() }
            }
            placements.append(Placement(origin: CGPoint(x: x, y: 0), size: size))
            line.append(i)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        if !line.isEmpty { endLine() }
        let height = placements.isEmpty ? 0 : y - spacing
        return (placements, CGSize(width: proposed ?? widest, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(subviews, width: bounds.width).placements
        for (subview, placement) in zip(subviews, placements) {
            subview.place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                          proposal: ProposedViewSize(placement.size))
        }
    }
}

/// A result row of the ticket, merge request and Jira project pickers: the service's mark, a key
/// in a column of `keyWidth` so the titles after it start on one line, the title, and a trailing
/// `detail` — a ticket's or merge request's lane. Inked for the ground its row declares: on the
/// accent everything turns white; off it — a highlighted dropdown row included, which is neutral —
/// the mark and the key keep the service's colours.
struct PickerResultRow: View {
    let mark: IconSource
    let key: String
    let keyWidth: CGFloat
    let title: String
    /// `nil` draws no detail column at all; an empty string keeps the column, and its spacing, empty.
    let detail: String?
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: Space.base) {
            Icon(mark, size: Size.pickerRowLogo, tint: Self.logoTint(on: surface))
            Text(key).font(Typography.caption.tabular).foregroundStyle(Self.keyInk(on: surface))
                .frame(width: keyWidth, alignment: .leading)
            Text(title).font(Typography.caption).foregroundStyle(surface.ink).lineLimit(1)
            Spacer(minLength: Space.snug)
            if let detail { HelpText(detail, fixedVerticalSize: false) }
        }
    }

    /// The mark's tint: white on the accent, else `nil`, its brand colour.
    static func logoTint(on surface: Surface) -> Color? { surface.isOnAccent ? surface.ink : nil }
    /// The key: white on the accent, else the link colour.
    static func keyInk(on surface: Surface) -> Color { surface.isOnAccent ? surface.ink : Palette.link }
}

/// The ticket field used by New Task and New Review. Their surrounding help and the
/// effects of picking or clearing remain the caller's.
struct TicketPickerField: View {
    let placeholder: String
    @Binding var query: String
    @Binding var open: Bool
    let items: [JiraTicket]
    let selection: JiraTicket?
    let onPick: (JiraTicket) -> Void
    let onClear: () -> Void

    var body: some View {
        ChipsPicker(placeholder: placeholder, picks: selection.map { [$0] } ?? [], open: $open,
                    matches: { _ in items }, mark: { .brand($0.brand) }, label: { $0.key + " · " + $0.summary },
                    row: { PickerResultRow(mark: .brand($0.brand), key: $0.key, keyWidth: Size.pickerTicketKey, title: $0.summary, detail: $0.status) },
                    onPick: onPick, onRemove: { _ in onClear() }, query: $query, selectionLimit: 1)
    }
}
