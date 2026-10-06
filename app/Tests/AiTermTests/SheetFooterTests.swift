import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTerm
@testable import AiTermTestSupport

/// The footer every sheet shares, driven through a hosted window by the keys it answers: ⎋ closes
/// an open list before it cancels, ⌘↩ is the primary action and only when it is enabled.
@MainActor
@Suite(.serialized) struct SheetFooterTests {
    private final class Calls {
        var cancels = 0, submits = 0, closes = 0
        var listOpen: Bool
        init(listOpen: Bool) { self.listOpen = listOpen }
    }

    private struct Harness {
        let calls: Calls
        let host: NSHostingView<SheetFooter<EmptyView>>
        let window: NSWindow
    }

    private func harness(listOpen: Bool = false, canSubmit: Bool = true, canCancel: Bool = true,
                         secondary: String? = "Cancel", primary: String? = "Save") -> Harness {
        let calls = Calls(listOpen: listOpen)
        let footer = SheetFooter(secondary: secondary, primary: primary, canCancel: canCancel, canSubmit: canSubmit,
                                 closeList: { guard calls.listOpen else { return false }
                                              calls.listOpen = false; calls.closes += 1; return true },
                                 cancel: { calls.cancels += 1 }, submit: { calls.submits += 1 })
        let host = NSHostingView(rootView: footer)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        settle(host)
        return Harness(calls: calls, host: host, window: window)
    }

    private func press(_ keyCode: UInt16, _ character: String, _ modifiers: NSEvent.ModifierFlags = [], in h: Harness) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: character,
                                     charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host)
    }

    @Test func escapeClosesAnOpenListBeforeItCancels() {
        let h = harness(listOpen: true)
        defer { h.window.orderOut(nil) }
        press(53, "\u{1b}", in: h)
        #expect(h.calls.closes == 1 && h.calls.cancels == 0, "the first ⎋ goes to the list")
        press(53, "\u{1b}", in: h)
        #expect(h.calls.closes == 1 && h.calls.cancels == 1, "the second finds none, and cancels")
    }

    @Test func escapeWithNoListCancels() {
        let h = harness()
        defer { h.window.orderOut(nil) }
        press(53, "\u{1b}", in: h)
        #expect(h.calls.cancels == 1 && h.calls.submits == 0)
    }

    /// The key stays with the footer even when Back is disabled: the caller's `cancel` is what
    /// refuses, as New Task's does while a create is running.
    @Test func escapeStillReachesCancelWhileTheButtonIsDisabled() {
        let h = harness(canCancel: false)
        defer { h.window.orderOut(nil) }
        press(53, "\u{1b}", in: h)
        #expect(h.calls.cancels == 1)
    }

    @Test func commandReturnSubmitsOnlyWhileTheButtonIsEnabled() {
        let enabled = harness()
        defer { enabled.window.orderOut(nil) }
        press(36, "\r", [.command], in: enabled)
        #expect(enabled.calls.submits == 1 && enabled.calls.cancels == 0)

        let disabled = harness(canSubmit: false)
        defer { disabled.window.orderOut(nil) }
        press(36, "\r", [.command], in: disabled)
        #expect(disabled.calls.submits == 0)
        press(36, "\r", in: enabled)
        #expect(enabled.calls.submits == 1, "a plain ↩ is not the primary action")
    }

    /// An action the sheet does not offer is absent, and so is its key: the Backpack sheet's Done
    /// alone takes no ⎋, and its Cancel alone, while a connect runs, takes no ⌘↩.
    @Test func anAbsentActionTakesNoKey() {
        let done = harness(secondary: nil, primary: "Done")
        defer { done.window.orderOut(nil) }
        press(53, "\u{1b}", in: done)
        #expect(done.calls.cancels == 0 && done.calls.closes == 0, "no Cancel, so ⎋ does nothing")
        press(36, "\r", [.command], in: done)
        #expect(done.calls.submits == 1)

        let cancelOnly = harness(primary: nil)
        defer { cancelOnly.window.orderOut(nil) }
        press(36, "\r", [.command], in: cancelOnly)
        #expect(cancelOnly.calls.submits == 0, "no primary action, so ⌘↩ does nothing")
        press(53, "\u{1b}", in: cancelOnly)
        #expect(cancelOnly.calls.cancels == 1)
    }
}
