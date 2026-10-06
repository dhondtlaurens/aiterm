import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A workspace that cannot be saved locks what would change it, and nothing else: following a
/// link changes nothing, so a locked project row's Jira badge still opens its project.
@MainActor
struct LockedSidebarTests {
    /// The project row as drawn with the workspace unlocked and locked, up to its "+" menu — which
    /// is disabled when locked, as it should be. Rendered, because `.disabled` shows only in pixels.
    private func projectRow(locked: Bool) throws -> NSBitmapImageRep {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        // Never loaded: locked, with no save-error banner to move the rows.
        if !locked { try controller.loadWorkspace() }
        let jira = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: URL(string: "https://example.atlassian.net")!)
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                              addedAt: Date(), collapsed: false, jiraProjects: [jira])
        controller.state.projects = [project]
        controller.state.terminals = [TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w", createdAt: Date())]
        #expect(controller.canChangeWorkspace == !locked)

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self).map { $0.numberOfRows > 0 } ?? false }

        let list = try #require(host.firstDescendant(NSTableView.self))
        var row = list.convert(list.rect(ofRow: 1), to: host)
        row.size.width = 340 - SidebarRowLayout.trailingInset(.standard) - SidebarRowLayout.trailingSlot(.standard) - 4
        // Rows exist before their SwiftUI content has drawn: wait for ink, a pixel that is not the row's ground.
        var bitmap: NSBitmapImageRep?
        settle(host) {
            guard let drawn = host.bitmapImageRepForCachingDisplay(in: row) else { return false }
            host.cacheDisplay(in: row, to: drawn)
            bitmap = drawn
            return Self.hasInk(drawn)
        }
        let drawn = try #require(bitmap)
        #expect(Self.hasInk(drawn), "the row drew nothing")
        return drawn
    }

    private static func hasInk(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let ground = bitmap.colorAt(x: 0, y: 0) else { return false }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where bitmap.colorAt(x: x, y: y) != ground { return true }
        }
        return false
    }

    /// Scoping the lock to the collapse gesture must leave the gesture working, and still locked:
    /// a click on the header's icon collapses it only while the workspace can change. The header is
    /// hosted alone, not in the sidebar's list — a click the row does not take falls to the table,
    /// whose own tracking loop would wait for events the test host never delivers — in a
    /// non-activating panel, because a window in the test host never becomes key and SwiftUI takes
    /// the first click in an inactive window as activation only.
    @Test(.serialized, arguments: [false, true]) func aClickOnTheHeaderCollapsesItOnlyWhileUnlocked(locked: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        if !locked { try controller.loadWorkspace() }
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.state.projects = [project]
        controller.state.terminals = [TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w", createdAt: Date())]
        let entries = SidebarModel.entries(state: controller.state, sessions: [], branchByCwd: [:], projectBranch: [:], diffByTask: [:])
        guard case .project(let section)? = entries.first else { Issue.record("expected a project section"); return }
        let host = NSHostingView(rootView: ProjectHeaderRow(section: section, controller: controller).frame(width: 300))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = host; panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        settle(host) { panel.isKeyWindow }
        try #require(panel.isKeyWindow)
        // On the provider icon: left of the name, clear of the Jira badge and the "+".
        let point = host.convert(NSPoint(x: 30, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                                            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        if locked {
            settle(host, for: 0.3) // Absence: a locked workspace must not collapse, however long it is given.
        } else {
            settle(host) { controller.state.projects[0].collapsed }
        }
        #expect(controller.state.projects[0].collapsed == !locked)
    }

    @Test func aLockedProjectRowDrawsItsJiraBadgeAsAnUnlockedOneDoes() throws {
        let unlocked = try projectRow(locked: false), locked = try projectRow(locked: true)
        #expect(unlocked.pixelsWide == locked.pixelsWide && unlocked.pixelsHigh == locked.pixelsHigh)
        var differing = 0
        for y in 0..<min(unlocked.pixelsHigh, locked.pixelsHigh) {
            for x in 0..<min(unlocked.pixelsWide, locked.pixelsWide) where unlocked.colorAt(x: x, y: y) != locked.colorAt(x: x, y: y) {
                differing += 1
            }
        }
        #expect(differing == 0)
    }
}
