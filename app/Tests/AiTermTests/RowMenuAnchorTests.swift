import AppKit
import SwiftUI
import Testing
@testable import AiTerm

@MainActor
@Suite(.serialized) struct RowMenuAnchorTests {
    /// A row view the list reuses for another id: SwiftUI keeps the anchor's `NSView` and calls
    /// `updateNSView` with the new id.
    private struct Row: View {
        let id: UUID
        var body: some View { Color.clear.frame(width: 80, height: 20).background(RowMenuAnchor(id: id)) }
    }

    @Test func aReusedRowAnchorAnswersForItsNewIdOnly() throws {
        let old = UUID(), new = UUID()
        let host = NSHostingView(rootView: Row(id: old))
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 20)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let anchor = try #require(RowMenuAnchor.anchor(for: old))

        host.rootView = Row(id: new)
        host.layoutSubtreeIfNeeded()

        #expect(RowMenuAnchor.anchor(for: new) === anchor)
        #expect(RowMenuAnchor.anchor(for: old) == nil, "the old id must not open the menu of the row now showing another")
    }

    private struct TwoRows: View {
        let first: UUID, second: UUID
        var body: some View {
            VStack(spacing: 0) { Row(id: first); Row(id: second) }
        }
    }

    /// Two reused rows that trade ids: whichever is updated second must not drop the id the first
    /// has just taken over, which is still the one it was registered for before.
    @Test func twoReusedRowsThatSwapIdsEachAnswerForTheirNewId() throws {
        let a = UUID(), b = UUID()
        let host = NSHostingView(rootView: TwoRows(first: a, second: b))
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let first = try #require(RowMenuAnchor.anchor(for: a)), second = try #require(RowMenuAnchor.anchor(for: b))
        #expect(first !== second)

        host.rootView = TwoRows(first: b, second: a)
        host.layoutSubtreeIfNeeded()

        #expect(RowMenuAnchor.anchor(for: b) === first)
        #expect(RowMenuAnchor.anchor(for: a) === second)
    }
}
