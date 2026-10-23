import AppKit
import SwiftUI
import AiTermUI

/// The key contract every dropdown in this app shares, as a pure function so it can be tested
/// without rendering: arrows wrap, Return accepts, Escape closes the popup *only*, and anything
/// else is left to the field and the sheet. `SearchPicker` and the prompt's completion popup both
/// answer their keys through it.
enum DropdownKeys {
    enum Outcome: Equatable { case moved(Int), accepted(Int), closed, unhandled }

    static func handle(selector: Selector, count: Int, index: Int, open: Bool) -> Outcome {
        guard open, count > 0 else { return .unhandled }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): return .moved((index + 1) % count)
        case #selector(NSResponder.moveUp(_:)): return .moved((index - 1 + count) % count)
        case #selector(NSResponder.insertNewline(_:)): return .accepted(min(index, count - 1))
        case #selector(NSResponder.cancelOperation(_:)): return .closed
        default: return .unhandled
        }
    }

    /// `handle` carried out for a picker whose list shows `shown`, open or not: an arrow moves `index`, ↩ picks the row
    /// (`pick`), ⎋ closes the list and starts the highlight over. Whether the key was the list's. `SearchPicker` and
    /// `ChipsPicker` answer their keys through it.
    static func perform<Item>(_ selector: Selector, on shown: [Item], index: Binding<Int>, open: Binding<Bool>, listening: Bool,
                              pick: (Item) -> Void) -> Bool {
        switch handle(selector: selector, count: shown.count, index: index.wrappedValue, open: listening) {
        case .moved(let i): index.wrappedValue = i; return true
        case .accepted(let i): pick(shown[i]); return true
        case .closed: open.wrappedValue = false; index.wrappedValue = 0; return true
        case .unhandled: return false
        }
    }
}

/// The panel every dropdown hangs in: a menu-shaped list of rows, `Size.menuRow` tall, with the
/// accent behind the row `index` names — the keyboard's or the pointer's, which moves it by
/// hovering — and dimmed while a row is held down. The ticket, merge request and branch pickers
/// draw their results in it, and so does the prompt's completion popup.
///
/// It owns the panel and the rows' frame, not the row: `row` draws one item's content, which reads
/// the ground its highlight declares (`menuRowHighlight`) rather than being told it is highlighted.
/// Where it hangs, and the keys that move `index`, are the caller's (`DropdownKeys`).
struct DropdownList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var index: Int
    let onPick: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { onPick(item) } label: {
                    row(item)
                        .padding(.horizontal, Space.base).frame(height: Size.menuRow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DropdownRowStyle(selected: i == index))
                .onHover { if $0 { index = i } }
            }
        }
        .padding(Space.tight)
        .menuChrome()
    }
}

/// A dropdown row: no button chrome, and a highlight that follows the pointer.
private struct DropdownRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.menuRowHighlight(selected, pressed: configuration.isPressed)
    }
}
