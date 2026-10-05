import AppKit
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct InterfaceSizeTests {
    private func controller() throws -> AppController {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        return controller
    }

    /// The sidebar keeps its proportion to its content: at the minimum it moves to the new
    /// minimum, wider it grows by the same factor.
    @Test func theSidebarScalesWithItsContent() {
        #expect(SidebarTiling.sidebarWidth(360, from: .standard, to: .large, limit: 5000) == 414)
        #expect(SidebarTiling.sidebarWidth(414, from: .large, to: .standard, limit: 5000) == 360)
        #expect(SidebarTiling.sidebarWidth(500, from: .standard, to: .extraLarge, limit: 5000) == 650)
    }

    /// Never below the new minimum, even from a frame an older build saved narrower; never past the
    /// screen's edge — but the minimum wins over the edge, as `window.minSize` would.
    @Test func theSidebarWidthIsClamped() {
        #expect(SidebarTiling.sidebarWidth(300, from: .standard, to: .standard, limit: 5000) == 360)
        #expect(SidebarTiling.sidebarWidth(900, from: .standard, to: .extraLarge, limit: 1000) == 1000)
        #expect(SidebarTiling.sidebarWidth(360, from: .standard, to: .extraLarge, limit: 400) == 468)
    }

    @Test func settingASizeResizesTheSidebarWindow() throws {
        let controller = try controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 400)
        controller.tiling.sidebarWindow = window
        controller.tiling.setInterfaceSize(.extraLarge)
        #expect(controller.preferences.interfaceSize == .extraLarge)
        #expect(window.frame.width == 468)
        #expect(window.minSize.width == 468)
        #expect(controller.state.sidebarFrame?.width == 468)
        controller.tiling.setInterfaceSize(.standard)
        #expect(window.frame.width == 360)
        #expect(window.minSize.width == 360)
    }

    @Test func zoomItemsAreDisabledAtTheEnds() throws {
        let app = AiTermApp(controller: try controller())
        func enabled(_ action: Selector) -> Bool { app.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
        app.controller.preferences.interfaceSize = .standard
        #expect(enabled(#selector(AiTermApp.zoomIn)))
        #expect(!enabled(#selector(AiTermApp.zoomOut)))
        #expect(!enabled(#selector(AiTermApp.actualSize)))
        app.controller.preferences.interfaceSize = .extraLarge
        #expect(!enabled(#selector(AiTermApp.zoomIn)))
        #expect(enabled(#selector(AiTermApp.zoomOut)))
        #expect(enabled(#selector(AiTermApp.actualSize)))
    }

    /// With a sheet open the sheet does not scale, and Settings holds an unsaved size of its own:
    /// the menu must not change a size nobody can see change.
    @Test func zoomItemsAreDisabledWhileASheetIsOpen() throws {
        let app = AiTermApp(controller: try controller())
        app.controller.preferences.interfaceSize = .large
        app.controller.sheet = .newDivider
        for action in [#selector(AiTermApp.zoomIn), #selector(AiTermApp.zoomOut), #selector(AiTermApp.actualSize)] {
            #expect(!app.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
    }
}
