import AiTermTestSupport
import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
@Suite(.serialized) struct SegmentedControlTests {
    /// The track takes the keyboard: ⇥ reaches it and → moves the selection. (The accent style, which
    /// took the keyboard without drawing a ring, went with the Settings tab bar it was drawn for: tabs are
    /// a `TabBar` now. A test window never becomes key, so the ring the track then wears cannot be
    /// drawn here; `houseFocusRingRemainsVisibleWhenRequested` draws it.)
    @Test func theTrackTakesTheKeyboard() throws {
        let state = SelectionState()
        let host = NSHostingView(rootView:
            SegmentedControl(values: [0, 1], selection: Binding(
                get: { state.selection }, set: { state.selection = $0 }
            )) { value, selected in
                Text("\(value)").foregroundStyle(selected ? Color.white : Color.gray)
            }
            .frame(width: 240)
            .padding(4)
        )
        host.frame = NSRect(x: 0, y: 0, width: 248, height: 36)
        let window = testWindow(hosting: host)
        defer { window.orderOut(nil) }
        settle(host)

        window.sendEvent(try keyEvent("\t", keyCode: 48, window: window))
        settle(host)
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

    /// The selected segment is a neutral fill, not a ground with an ink of its own: every segment's
    /// content keeps the ground the track sits on, selected or not.
    @Test func everySegmentKeepsTheGroundItSitsOn() {
        let log = EnvironmentLog()
        let host = NSHostingView(rootView:
            SegmentedControl(values: [0, 1], selection: .constant(0)) { value, _ in
                EnvironmentReader(id: value, log: log)
            }
            .frame(width: 240))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        host.layoutSubtreeIfNeeded()
        #expect(log.surface == [0: .sheet, 1: .sheet])
    }

    /// A segment's label is plain `Text`: the control inks it as its callers used to by hand — the
    /// selection in the ground's ink and the rest in the secondary ink.
    @Test func theControlInksAPlainLabelForItsGround() throws {
        func render(_ label: @escaping (Int, Bool) -> Text) throws -> Data {
            let host = NSHostingView(rootView:
                SegmentedControl(values: [0, 1], selection: .constant(0), content: label)
                    .frame(width: 240).padding(4))
            host.frame = NSRect(x: 0, y: 0, width: 248, height: 36)
            settle(host)
            return try pixels(in: host)
        }
        let selectedInk = Palette.text
        let plain = try render { value, _ in Text("Segment \(value)") }
        let byHand = try render { value, on in Text("Segment \(value)").foregroundStyle(on ? selectedInk : Palette.muted) }
        let unInked = try render { value, _ in Text("Segment \(value)").foregroundStyle(Palette.text) }
        #expect(plain == byHand)
        #expect(plain != unInked, "the test must tell inks apart")
    }

    private final class SelectionState: ObservableObject {
        @Published var selection = 0
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(keyDown(characters, code: keyCode, in: window))
    }

    private func focusRingSample(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Radius.group)
            .fill(Palette.surface)
            .frame(width: 240, height: Size.control)
            .focusRing(focused, cornerRadius: Radius.group)
            .padding(4)
    }

}
