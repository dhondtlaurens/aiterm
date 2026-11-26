import SwiftUI
import AppKit
import AiTermUI

/// A list of rows in a sheet, the one way the app draws one (proposal “Three list sheets, one pattern”, 26 Nov 2026):
/// the title, a search field that keeps the keyboard, the rows under optional group headings, and `SheetFooter`'s
/// actions. The Operator's and the projects' signals sheets and the Archive are configurations of it.
///
/// The sheet owns how a list behaves, the model what it holds: ↑ ↓ move the model's highlight, ⌘⌫ asks the
/// highlighted row's Remove question, ⎋ clears a search and then closes, a click highlights a row and a double-click
/// runs its first command. The footer's primary answers ⌘↩. Nothing archived or listed yet is the `empty` content; a
/// search that matches nothing says so with the query.
struct ListSheet<Item: Identifiable, Row: View, Empty: View, Footer: View>: View where Item.ID == UUID {
    typealias Group = ListGroup<Item>

    let title: String
    let placeholder: String
    @Binding var query: String
    let groups: [Group]
    /// Whether the list holds anything before the search: false shows `empty`.
    let hasItems: Bool
    /// The line a search with no match shows, the query trimmed in it.
    let noMatch: (String) -> String
    let highlighted: UUID?
    let highlight: (UUID) -> Void
    /// A double-click: the row's first command.
    let activate: (UUID) -> Void
    /// The search field's commands, before the field sees them: the model's ↑ ↓, ⌘⌫ and ⎋.
    let command: (Selector) -> Bool
    let commands: (Item) -> [[RowCommand]]
    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let empty: () -> Empty
    @ViewBuilder let footer: () -> Footer
    @State private var focused = true
    @State private var hovered: UUID?

    var body: some View {
        let items = groups.flatMap(\.items)
        SheetLayout(title: title, height: .fixed(Sheet.height), contentVerticalPadding: items.isEmpty ? Space.margin : Space.base) {
            HStack(spacing: Space.base) {
                Image(systemName: "magnifyingglass").font(Typography.caption).foregroundStyle(Palette.muted)
                SearchField(placeholder: placeholder, text: $query, focused: $focused, onCommand: command)
            }
            .fieldChrome(focused: focused)
            // A field, not a line of the title: `Space.base` further from it than a subtitle.
            .padding(.top, Space.base)
        } content: {
            if !hasItems {
                empty()
            } else if items.isEmpty {
                Text(noMatch(query.trimmingCharacters(in: .whitespaces))).font(Typography.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollViewReader { scroller in
                    LazyVStack(alignment: .leading, spacing: Space.hairline) {
                        ForEach(groups) { group in
                            if let heading = group.heading { ListSheetGroupHeading(heading) }
                            ForEach(group.items) { item in
                                let groups = commands(item)
                                row(item)
                                    .modifier(RowPill(selected: item.id == highlighted, hovered: hovered == item.id, ground: .sheet))
                                    .onHover { inside in
                                        if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
                                    }
                                    .id(item.id)
                                    .onTapGesture(count: 2) { highlight(item.id); activate(item.id) }
                                    .onTapGesture { highlight(item.id) }
                                    .accessibilityAddTraits(item.id == highlighted ? .isSelected : [])
                                    .modifier(RowCommandContextMenu(groups: groups))
                            }
                        }
                    }
                    .onChange(of: highlighted) { _, id in if let id { scroller.scrollTo(id) } }
                }
            }
        } footer: {
            footer()
        }
    }
}

/// A run of a list sheet's rows under an optional heading: the Archive's dates, or one unheaded group.
struct ListGroup<Item> {
    var heading: String?
    var items: [Item]
}

extension ListGroup: Identifiable { var id: String { heading ?? "" } }
extension ListGroup: Equatable where Item: Equatable {}

/// A group's heading between a list sheet's rows: `SidebarHeading` on a `Size.menuRow` row, inset `Space.base` as a
/// row's content is, `Space.base` clear of the rows above it.
struct ListSheetGroupHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        SidebarHeading(text)
            .padding(.horizontal, Space.base)
            .frame(maxWidth: .infinity, minHeight: Size.menuRow, alignment: .leading)
            .padding(.top, Space.base)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a row's state column says: a glyph centred on the row, its words raised in a `HoverChip`, one line; `detail`,
/// when the whole of it would not fit that line, is the glyph's help and what VoiceOver says.
struct ListRowState: Equatable {
    var symbol: String
    var tint: Color
    var words: String
    var detail: String? = nil

    /// A source fails or an item is skipped: `Notice`'s mark.
    static func issue(_ words: String, detail: String? = nil) -> Self {
        Self(symbol: Notice<EmptyView>.symbol, tint: Palette.amber, words: words, detail: detail)
    }
    static func schedule(_ words: String) -> Self { Self(symbol: "clock", tint: Palette.tertiary, words: words) }
    static let switchedOff = Self(symbol: "pause.fill", tint: Palette.tertiary, words: "Switched off")
}

/// A list sheet's row, `Size.row` tall: the leading mark, the title over one `Size.chip` line, both cut at the end before
/// the columns; then, with `stateColumn`, a `Size.slot` column whose glyph raises its words; then the trailing column a
/// task row gives its status mark, with the row's menu behind `gearshape`, drawn as the headings' + (`AddMenu`).
/// `dimmed` fades the mark and the lines, as a switched-off signal is. Inked from the `Surface` its pill declares.
struct ListSheetRow<Mark: View, Detail: View>: View {
    let title: String
    var dimmed = false
    /// Whether the row keeps a state column, so every row of the list lines up whether or not it has a state.
    var stateColumn = false
    var state: ListRowState? = nil
    let commands: [[RowCommand]]
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let detail: () -> Detail
    @State private var stateHovered = false
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: Space.inset) {
            HStack(spacing: Space.inset) {
                mark()
                VStack(alignment: .leading, spacing: Space.tight) {
                    RowTitle(title).truncationMode(.tail)
                    detail().frame(height: Size.chip)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(dimmed ? Opacity.disabled : 1)
            if stateColumn {
                Group {
                    if let state {
                        Icon(.symbol(state.symbol), size: Size.inlineMark, tint: state.tint)
                            .frame(width: Size.slot, height: Size.slot)
                            .contentShape(Rectangle())
                            .onHover { stateHovered = $0 }
                            .raisingHoverChip(HoverChip(state.words), shown: stateHovered, alignment: .trailing)
                            .help(state.detail ?? "")
                            .accessibilityLabel(state.detail ?? state.words)
                    } else {
                        Color.clear.frame(width: Size.slot, height: Size.slot)
                    }
                }
            }
            AddMenu(help: "Actions for \(title)", enabled: commands.contains { $0.contains(where: \.enabled) }, symbol: "gearshape") {
                RowCommandMenu(groups: commands)
            }
            .accessibilityLabel("Actions for \(title)")
        }
        .padding(.leading, Space.base).padding(.vertical, Space.base)
        .padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .frame(minHeight: Size.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(dimmed ? "switched off" : (state.map { $0.detail ?? $0.words } ?? ""))
        .modifier(RowCommandActions(groups: commands))
    }
}
