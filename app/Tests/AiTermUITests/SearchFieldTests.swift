import Testing
import AiTermTestSupport
import AppKit
import SwiftUI
@testable import AiTermUI

@Suite @MainActor struct SearchFieldTests {
    /// Focus may be requested before SwiftUI inserts the representable into a window. The field
    /// retries at window attachment, so the request is deterministic rather than dropped.
    @Test func testFocusIsRetriedWhenTheFieldReachesAWindow() {
        let field = FocusableTextField()
        field.wantsFocus = true
        field.focusIfNeeded()   // no window yet: must not crash, must not claim focus
        #expect(field.currentEditor() == nil)

        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled])
        window.contentView?.addSubview(field)
        field.viewDidMoveToWindow()
        #expect(window.firstResponder === field.currentEditor() || window.firstResponder === field)
    }

    @Test func testAFieldThatDoesNotWantFocusNeverTakesIt() {
        let field = FocusableTextField()
        let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled])
        window.contentView?.addSubview(field)
        field.viewDidMoveToWindow()
        #expect(field.currentEditor() == nil)
    }

    /// A click into the field is focus, and the house ring has to show then — not only once the
    /// first character is typed, which is when `controlTextDidBeginEditing` arrives.
    @Test func focusIsReportedWhenTheFieldIsClickedNotWhenItIsTypedIn() throws {
        let state = FieldState()
        let (window, host) = Self.host(StatefulField(state: state))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstDescendant( FocusableTextField.self))
        #expect(!state.focused)

        window.makeFirstResponder(field)
        settle(host)
        #expect(state.focused, "the field took the keyboard without reporting focus")

        window.makeFirstResponder(nil)
        settle(host)
        #expect(!state.focused, "the field lost the keyboard and still reports focus")
    }

    /// A ↩ that no popup takes ends the field's editing, but AppKit selects its text again and the
    /// field keeps the keyboard — so it still reports focus, and keeps its ring.
    @Test func returnLeavesTheFieldFocused() throws {
        let state = FieldState()
        let (window, host) = Self.host(StatefulField(state: state))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstDescendant( FocusableTextField.self))
        window.makeFirstResponder(field)
        settle(host)
        #expect(state.focused)

        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        settle(host)
        #expect(field.currentEditor() != nil, "↩ took the keyboard from the field")
        #expect(state.focused, "the field kept the keyboard and stopped reporting focus")
    }

    /// The placeholder follows the view: a picker reused for another list re-words its prompt.
    @Test func thePlaceholderFollowsTheView() throws {
        let state = FieldState()
        let (window, host) = Self.host(StatefulField(state: state))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstDescendant( FocusableTextField.self))
        #expect(field.placeholderString == "Search tickets")

        state.placeholder = "Search branches"
        settle(host)
        #expect(field.placeholderString == "Search branches")
    }

    @Test func undoAndRedoReachTheBinding() throws {
        let state = FieldState()
        let (window, host) = Self.host(StatefulField(state: state))
        defer { window.orderOut(nil) }
        let field = try #require(host.firstDescendant( FocusableTextField.self))
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        #expect(state.text == "abc")

        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        settle(host)
        #expect(editor.string == "")
        #expect(state.text == "", "undo must update the search query")
        undo.redo()
        settle(host)
        #expect(editor.string == "abc")
        #expect(state.text == "abc", "redo must update the search query")
    }

    private final class FieldState: ObservableObject {
        @Published var focused = false
        @Published var text = ""
        @Published var placeholder = "Search tickets"
    }

    private struct StatefulField: View {
        @ObservedObject var state: FieldState
        var body: some View {
            SearchField(placeholder: state.placeholder, text: Binding(get: { state.text }, set: { state.text = $0 }),
                        focused: Binding(get: { state.focused }, set: { state.focused = $0 }), onCommand: { _ in false })
                .frame(width: 200, height: 24)
        }
    }

    private static func host(_ view: some View) -> (NSWindow, NSView) {
        let (window, host) = testWindow(hosting: view, size: CGSize(width: 200, height: 24))
        settle(host)
        return (window, host)
    }
}
