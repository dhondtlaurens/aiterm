import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

/// Sheets keep Apple's sizes whatever the sidebar is drawn at: their pop-up and push buttons are
/// AppKit bezels that stop at 28 pt, and a sheet whose fields grew past them would be misaligned.
@MainActor
struct SidebarSheetScaleTests {
    /// The top band of a sheet (its title) rendered under a given sidebar scale.
    private func titleBand(under scale: InterfaceScale) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        let host = NSHostingView(rootView: SidebarSheet(kind: .newDivider, controller: controller).interfaceScale(scale))
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        // The title band only: below it sits a text field, whose caret would make two renders differ.
        let band = NSRect(x: 0, y: 0, width: host.bounds.width, height: 64)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: band))
        host.cacheDisplay(in: band, to: bitmap)
        return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    @Test func sheetsDrawAtAppleSizesUnderAScaledSidebar() throws {
        #expect(try titleBand(under: .extraLarge) == titleBand(under: .standard))
    }
}
