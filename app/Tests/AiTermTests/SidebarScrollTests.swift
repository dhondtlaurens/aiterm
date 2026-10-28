import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTermTestSupport
@testable import AiTermCore
@testable import AiTerm

/// A selection made away from the list — Focus View, a notification bringing an iTerm2 window
/// forward — scrolls the sidebar to its row, which could otherwise sit below the fold.
@MainActor
struct SidebarScrollTests {
    /// The viewport itself must clear the native titlebar. A scrolling inset only clears its first
    /// row: once scrolled, selected rows can paint behind the window controls.
    @Test func scrollingContentStaysBelowTheTrafficLights() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        var first: UUID?
        for index in 0..<20 {
            let project = OperatorUIFixtures.project("Repo \(index)")
            first = first ?? project.id
            controller.workspace.mutate { $0.append(project: project) }
        }
        // The broadcast folded into OPERATOR, so the projects are open and the list scrolls.
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run]; $0.setFolded(run: run.id, true) }
        controller.focus.browse(.project(try #require(first)))
        let host = testHost(SidebarView(controller: controller), size: CGSize(width: Size.sidebarMinWidth, height: 400))
        let window = testWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        // OPERATOR, PROJECTS and the 20 projects.
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows == 22 }
        let table = try #require(host.firstDescendant(NSTableView.self))
        let scroll = try #require(table.enclosingScrollView)
        let controls = try #require(window.standardWindowButton(.closeButton)?.superview)
        let controlsRect = host.convert(controls.bounds, from: controls)
        let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
        #expect(viewport.minY >= controlsRect.maxY, "the scroll viewport \(viewport) must clear the traffic lights \(controlsRect)")
        table.scrollRowToVisible(table.numberOfRows - 1)
        settle(host, for: 0.1)
        #expect(host.convert(scroll.contentView.bounds, from: scroll.contentView).minY >= controlsRect.maxY)

        // Bring the selected first project right against the viewport's upper edge, then inspect the
        // band's pixels as well as its geometry: neither text nor the selection fill may reach it.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: table.rect(ofRow: 2).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host, for: 0.1)
        for active in [false, true] {
            if active { window.makeKeyAndOrderFront(nil) } else { window.resignKey() }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let pixelScale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            // Compare with this window's drawn sidebar ground. Resolving the dynamic NSColor
            // separately can use a different native emphasis/color-space than SwiftUI's bitmap.
            let sidebar = try #require(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            for y in 1..<Int(controlsRect.maxY * pixelScale) {
                let pixel = try #require(bitmap.colorAt(x: Int(host.bounds.midX * pixelScale), y: y)?.usingColorSpace(.deviceRGB))
                let difference = abs(pixel.redComponent - sidebar.redComponent) + abs(pixel.greenComponent - sidebar.greenComponent)
                    + abs(pixel.blueComponent - sidebar.blueComponent)
                #expect(difference < 0.02, "the fixed titlebar band is sidebar background (active: \(active), row \(y))")
            }
            if let directory = ProcessInfo.processInfo.environment["AITERM_UI_EVIDENCE_DIR"] {
                let output = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("sidebar-titlebar-\(active ? "active" : "inactive").png"))
            }
        }
    }

    /// The last project starts collapsed and opens in the same turn its row is selected, as Focus
    /// View does it: the row is scrolled to once the table has it.
    @Test func aSelectionMadeElsewhereScrollsItsRowIntoView() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        for index in 0..<20 {
            let project = Project(id: UUID(), name: "Repo \(index)", path: "/repo\(index)", provider: .git, remoteUrl: nil,
                                  addedAt: Date(), collapsed: index == 19)
            controller.workspace.mutate { state in
                state.append(project: project)
                state.terminals.append(TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: nil, createdAt: Date()))
            }
        }

        let host = testHost(SidebarView(controller: controller), size: CGSize(width: 340, height: 300))
        let window = testWindow(contentRect: host.frame, styleMask: [.titled])
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(host, describing: "the sidebar's table") { host.firstDescendant(NSTableView.self) != nil }
        let list = try #require(host.firstDescendant(NSTableView.self))
        let last = try #require(controller.state.terminals.last)
        controller.workspace.mutate { $0.updateProject(id: last.projectId) { $0.collapsed = false } }
        controller.focus.browse(.terminal(last.id))
        settle(host, describing: "the last terminal's row scrolled into view") {
            list.numberOfRows == 42 && list.visibleRect.contains(list.rect(ofRow: list.numberOfRows - 1))
        }

        // The last terminal is the last row. Not `selectedRow`: a selection set from the model
        // reaches the table's own `selectedRow` only later, if at all.
        #expect(list.numberOfRows == 42)
        #expect(list.visibleRect.contains(list.rect(ofRow: list.numberOfRows - 1)))
    }
}
