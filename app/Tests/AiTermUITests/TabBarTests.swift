import AiTermTestSupport
import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
@Suite(.serialized) struct TabBarTests {
    private final class SelectionState: ObservableObject {
        @Published var selection = 0
    }

    /// A bar of three tabs on the sheet's ground, in a window that can take the keyboard.
    private func hosted(_ state: SelectionState, isSelectable: @escaping (Int) -> Bool = { _ in true })
        -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView:
            TabBar(values: [0, 1, 2], selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
                   isSelectable: isSelectable) { Text("Tab \($0)") }
                .frame(width: 300)
                .padding(8)
                .background(Palette.surface))
        host.frame = NSRect(x: 0, y: 0, width: 316, height: 60)
        let window = testWindow(hosting: host)
        settle(host)
        return (window, host)
    }

    private func press(_ characters: String, code: UInt16, in window: NSWindow, settling host: NSView) throws {
        window.sendEvent(try #require(keyDown(characters, code: code, in: window)))
        settle(host)
    }

    /// ⇥ reaches the bar; → and ← then move the selection one selectable tab at a time, stepping over the
    /// one that cannot be picked and stopping at either end.
    @Test func theArrowsMoveAmongTheSelectableTabs() throws {
        let state = SelectionState()
        let (window, host) = hosted(state, isSelectable: { $0 != 1 })
        defer { window.orderOut(nil) }

        try press("\t", code: 48, in: window, settling: host)
        try press("\u{F703}", code: 124, in: window, settling: host)
        #expect(state.selection == 2, "→ steps over the unselectable tab")
        try press("\u{F703}", code: 124, in: window, settling: host)
        #expect(state.selection == 2, "and stops at the end")
        try press("\u{F702}", code: 123, in: window, settling: host)
        #expect(state.selection == 0, "← steps back over it")
        try press("\u{F702}", code: 123, in: window, settling: host)
        #expect(state.selection == 0)
    }

    /// While the bar has the keyboard its selected tab wears the house focus ring. Drawn from the tab
    /// itself: a test window never becomes key, so `@FocusState` cannot be driven true here, and the
    /// arrows above are what prove the bar takes the keyboard.
    @Test func theSelectedTabIsRingedWhileTheBarHasTheKeyboard() throws {
        func render(ringed: Bool) throws -> Data {
            let host = NSHostingView(rootView:
                TabBarTab(on: true, selectable: true, ringed: ringed, select: {}) { Text("Agents") }
                    .padding(8).background(Palette.surface))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            settle(host)
            return try pixels(in: host)
        }
        #expect(try render(ringed: true) != render(ringed: false))
    }

    /// The ring is for focus the keyboard moved: ⇥ or ⇧⇥, not the ⌘, that opened Settings and handed the
    /// bar its focus, nor a click.
    @Test func onlyATabKeyCountsAsTheKeyboardBringingFocus() throws {
        func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        #expect(TabBar<Int, Text>.tabbedIn(key("\t", 48)))
        #expect(TabBar<Int, Text>.tabbedIn(key("\u{19}", 48, .shift)))
        #expect(!TabBar<Int, Text>.tabbedIn(key(",", 43, .command)))
        #expect(!TabBar<Int, Text>.tabbedIn(click))
        #expect(!TabBar<Int, Text>.tabbedIn(nil))
    }

    /// The step the arrows take, apart from any view: over what cannot be picked, nil past either end.
    @Test func aStepSkipsWhatCannotBePicked() {
        let values = [0, 1, 2, 3]
        #expect(SelectionStep.next(from: 0, by: 1, in: values, isSelectable: { $0 != 1 }) == 2)
        #expect(SelectionStep.next(from: 3, by: -1, in: values, isSelectable: { $0 < 2 }) == 1)
        #expect(SelectionStep.next(from: 3, by: 1, in: values, isSelectable: { _ in true }) == nil)
        #expect(SelectionStep.next(from: 0, by: 1, in: values, isSelectable: { $0 == 0 }) == nil)
    }

    /// One underline, under the selected tab alone: the bar's bottom rows are lit only within the
    /// selected tab's span, and move with the selection.
    @Test func theUnderlineIsUnderTheSelectedTabAlone() throws {
        func litColumns(selecting selected: Int) throws -> [Int] {
            let host = NSHostingView(rootView:
                TabBar(values: [0, 1, 2], selection: .constant(selected)) { Text("Tab \($0)") }
                    .frame(width: 300).background(Color.black))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            settle(host)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // The last row of pixels is the underline's, under no label.
            let row = bitmap.pixelsHigh - 1
            return (0..<bitmap.pixelsWide).filter { x in
                guard let pixel = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { return false }
                return pixel.redComponent + pixel.greenComponent + pixel.blueComponent > 1.5
            }
        }
        let first = try litColumns(selecting: 0), second = try litColumns(selecting: 1), third = try litColumns(selecting: 2)
        for lit in [first, second, third] {
            #expect(!lit.isEmpty)
            // One run: a single underline, not one per tab.
            #expect(lit.last! - lit.first! + 1 == lit.count)
        }
        #expect(first.last! < second.first!, "the second tab's underline lies after the first's")
        #expect(second.last! < third.first!)
    }

    /// A tab `isSelectable` rejects is disabled — VoiceOver reads it dimmed, a click does nothing — and
    /// faded; the others are enabled.
    @Test func anUnselectableTabIsDisabledAndFaded() throws {
        let log = EnvironmentLog()
        let host = NSHostingView(rootView:
            TabBar(values: [0, 1], selection: .constant(0), isSelectable: { $0 == 0 }) { EnvironmentReader(id: $0, log: log) }
                .frame(width: 240))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        host.layoutSubtreeIfNeeded()
        #expect(log.isEnabled == [0: true, 1: false])

        func render(rejecting: Bool) throws -> Data {
            let host = NSHostingView(rootView:
                TabBar(values: [0, 1], selection: .constant(0), isSelectable: { !rejecting || $0 == 0 }) { Text("Tab \($0)") }
                    .frame(width: 240).background(Palette.surface))
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
            settle(host)
            return try pixels(in: host)
        }
        #expect(try render(rejecting: true) != render(rejecting: false))
    }

    /// The bar sets its tabs' ink — the selected one's `text`, the rest `muted` — so a label is plain `Text`.
    @Test func theBarInksAPlainLabel() throws {
        func render(_ label: @escaping (Int) -> Text) throws -> Data {
            let host = NSHostingView(rootView:
                TabBar(values: [0, 1], selection: .constant(0), label: label).frame(width: 240).background(Palette.surface))
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
            settle(host)
            return try pixels(in: host)
        }
        let plain = try render { Text("Tab \($0)") }
        let byHand = try render { Text("Tab \($0)").foregroundStyle($0 == 0 ? Palette.text : Palette.muted) }
        let unInked = try render { Text("Tab \($0)").foregroundStyle(Palette.text) }
        #expect(plain == byHand)
        #expect(plain != unInked, "the test must tell inks apart")
    }
}
