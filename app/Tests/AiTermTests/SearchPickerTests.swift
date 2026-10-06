import Testing
import AppKit
import SwiftUI
@testable import AiTerm
@testable import AiTermTestSupport

@Suite struct SearchPickerTests {
    private func handle(_ sel: Selector, count: Int = 3, index: Int = 0, open: Bool = true) -> SearchPickerKeys.Outcome {
        SearchPickerKeys.handle(selector: sel, count: count, index: index, open: open)
    }

    @Test func testArrowsWrapAround() {
        #expect(handle(#selector(NSResponder.moveDown(_:)), index: 0) == .moved(1))
        #expect(handle(#selector(NSResponder.moveDown(_:)), index: 2) == .moved(0))
        #expect(handle(#selector(NSResponder.moveUp(_:)), index: 0) == .moved(2))
        #expect(handle(#selector(NSResponder.moveUp(_:)), index: 1) == .moved(0))
    }

    @Test func testReturnAcceptsAndEscapeClosesOnlyThePopup() {
        #expect(handle(#selector(NSResponder.insertNewline(_:)), index: 2) == .accepted(2))
        #expect(handle(#selector(NSResponder.cancelOperation(_:))) == .closed)
    }

    /// Returning `.unhandled` is what leaves a key with the field and the sheet — notably ⎋, which
    /// must close the sheet when no popup is open.
    @Test func testAClosedOrEmptyPopupHandlesNothing() {
        #expect(handle(#selector(NSResponder.cancelOperation(_:)), open: false) == .unhandled)
        #expect(handle(#selector(NSResponder.moveDown(_:)), count: 0) == .unhandled)
        #expect(handle(#selector(NSResponder.insertText(_:))) == .unhandled)
    }

    /// An index past the end cannot accept out of bounds — the list can shrink under a stale index
    /// while a search result lands.
    @Test func testAcceptClampsToTheLastRow() {
        #expect(handle(#selector(NSResponder.insertNewline(_:)), count: 2, index: 5) == .accepted(1))
    }
}

/// The picker's own state, driven through a hosted picker: the highlight and the field's focus are
/// the picker's, not its sheet's, so the rules that keep them honest are the picker's too.
@MainActor
@Suite(.serialized) struct SearchPickerStateTests {
    struct Choice: Identifiable, Equatable { let id: String }

    /// What a sheet keeps: the query, whether the list is open, the items and what was picked.
    final class Sheet: ObservableObject {
        @Published var query = ""
        @Published var open: Bool
        @Published var items: [Choice]
        @Published var picked: Choice?
        init(open: Bool, items: [Choice]) { self.open = open; self.items = items }
    }

    struct Harness: View {
        @ObservedObject var sheet: Sheet
        var body: some View {
            SearchPicker(placeholder: "Search", query: $sheet.query, open: $sheet.open,
                         items: sheet.items, selection: sheet.picked,
                         row: { choice, _ in Text(choice.id) }, selected: { Text($0.id) },
                         onPick: { sheet.picked = $0 }, toggleHelp: { _ in "" })
        }
    }

    private func host(_ sheet: Sheet) -> (NSHostingView<Harness>, NSWindow) {
        let host = NSHostingView(rootView: Harness(sheet: sheet))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host)
        return (host, window)
    }

    private func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "Search" { return field }
        return view.subviews.lazy.compactMap { field(in: $0) }.first
    }

    private func send(_ selector: Selector, to field: NSTextField) -> Bool {
        field.delegate?.control?(field, textView: NSTextView(), doCommandBy: selector) ?? false
    }

    /// A search that lands while a lower row is highlighted starts the new list at its first row,
    /// rather than leaving the highlight on whatever now sits there.
    @Test func newResultsStartTheHighlightAtTheFirstRow() throws {
        let sheet = Sheet(open: true, items: [Choice(id: "a"), Choice(id: "b"), Choice(id: "c")])
        let (host, window) = host(sheet)
        defer { window.orderOut(nil) }
        let field = try #require(field(in: host))
        #expect(send(#selector(NSResponder.moveDown(_:)), to: field))
        #expect(send(#selector(NSResponder.moveDown(_:)), to: field))

        sheet.items = [Choice(id: "x"), Choice(id: "y"), Choice(id: "z")]
        settle(host)
        #expect(send(#selector(NSResponder.insertNewline(_:)), to: field))
        #expect(sheet.picked == Choice(id: "x"))
    }

    /// Opening the list from outside — the sheet's chevron, or a cleared pick — gives the field
    /// the keyboard, so the arrows reach the list rather than the sheet's other controls.
    @Test func openingTheListFocusesItsField() throws {
        let sheet = Sheet(open: false, items: [Choice(id: "a")])
        let (host, window) = host(sheet)
        defer { window.orderOut(nil) }
        let field = try #require(field(in: host))
        // A window hands its first field the keyboard by itself; take it back, as a click elsewhere would.
        window.makeFirstResponder(nil)
        #expect(field.currentEditor() == nil)

        sheet.open = true
        #expect(settle(host) { field.currentEditor() != nil })
    }
}
