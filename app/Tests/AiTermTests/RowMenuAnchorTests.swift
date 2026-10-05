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
}
