import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
@Suite(.serialized) struct SegmentedControlTests {
    /// The accent style draws no focus ring — its selected segment is already the accent — but the
    /// track still takes the keyboard.
    @Test func theAccentStyleKeepsKeyboardNavigationWithoutARing() throws {
        let state = SelectionState()
        let host = NSHostingView(rootView:
            SegmentedControl(values: [0, 1], selection: Binding(
                get: { state.selection }, set: { state.selection = $0 }
            ), style: .accent) { value, selected in
                Text("\(value)").foregroundStyle(selected ? Color.white : Color.gray)
            }
            .frame(width: 240)
            .padding(4)
        )
        host.frame = NSRect(x: 0, y: 0, width: 248, height: 36)
        let window = window(hosting: host)
        defer { window.orderOut(nil) }
        settle(host)

        let unfocused = try pixels(in: host)
        window.sendEvent(try keyEvent("\t", keyCode: 48, window: window))
        settle(host)
        let focused = try pixels(in: host)

        #expect(focused == unfocused)

        window.sendEvent(try keyEvent("\u{F703}", keyCode: 124, window: window))
        settle(host)
        #expect(state.selection == 1)
    }

    @Test func houseFocusRingRemainsVisibleWhenRequested() throws {
        let idle = NSHostingView(rootView: focusRingSample(focused: false))
        let focused = NSHostingView(rootView: focusRingSample(focused: true))
        for host in [idle, focused] {
            host.frame = NSRect(x: 0, y: 0, width: 248, height: 36)
            settle(host)
        }

        #expect(try pixels(in: focused) != pixels(in: idle))
    }

    /// A segment that cannot be picked is disabled, not merely dimmed: SwiftUI's disabled state is
    /// what VoiceOver reads as "dimmed", and what keeps a click from selecting it.
    @Test func anUnselectableSegmentIsDisabled() {
        let log = EnvironmentLog()
        let host = NSHostingView(rootView:
            SegmentedControl(values: [0, 1], selection: .constant(0), isSelectable: { $0 == 0 }) { value, _ in
                EnvironmentReader(id: value, log: log)
            }
            .frame(width: 240))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        host.layoutSubtreeIfNeeded()
        #expect(log.isEnabled == [0: true, 1: false])
    }

    /// On the accent style the selected segment is drawn on the accent, so what it carries reads
    /// `.surface(.accent)` and inks white by itself; the others keep the ground they sit on.
    @Test func theAccentStyleDeclaresTheAccentUnderItsSelection() {
        let log = EnvironmentLog()
        let host = NSHostingView(rootView:
            SegmentedControl(values: [0, 1], selection: .constant(0), style: .accent) { value, _ in
                EnvironmentReader(id: value, log: log)
            }
            .frame(width: 240))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        host.layoutSubtreeIfNeeded()
        #expect(log.surface == [0: .accent, 1: .sheet])
    }

    private final class SelectionState: ObservableObject {
        @Published var selection = 0
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func focusRingSample(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Radius.group)
            .fill(Palette.surface)
            .frame(width: 240, height: Size.control)
            .focusRing(focused, cornerRadius: Radius.group)
            .padding(4)
    }

}
