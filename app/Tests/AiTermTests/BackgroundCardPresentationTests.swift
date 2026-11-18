import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor struct BackgroundCardPresentationTests {
    private func fixture(jobs: Int = 3) throws -> (AppController, TaskItem, SessionInfo) {
        let controller = AppController(preferences: .scratch(), activateIterm: {})
        try controller.workspace.load()
        let project = Project.make(name: "Repo")
        let task = TaskItem.make(project: project.id, title: "Source", windowId: "w")
        controller.workspace.mutate { state in
            state.append(project: project)
            state.tasks = [task] + (0..<6).map { TaskItem.make(project: project.id, title: "Neighbour \($0)") }
        }
        var tab = SessionInfo.make("worker", window: "w", task: task.id, state: .working)
        tab.work = (0..<jobs).map { WorkItem(kind: .shell, text: "command-\($0)", holdsTurn: false,
                                           displayLabel: "Validate checkout \($0)") }
        controller.live.handle(.sessionOpened(tab))
        return (controller, task, tab)
    }

    /// Use the state installed by the real row modifier, including its production open delay
    /// and the NSViewRepresentable observation that hands it to the sidebar presenter.
    @discardableResult private func open(_ anchor: BackgroundCardAnchor.Probe, in host: NSView) async throws -> BackgroundCardHover {
        let hover = try #require(anchor.hover)
        let previous = anchor.presenter?.panel, alreadyOpen = hover.isOpen
        hover.mark(true)
        await eventually(describing: "the row hover opening its native card") {
            anchor.presenter?.panel != nil && hover.isOpen
                && (alreadyOpen || anchor.presenter?.panel !== previous)
        }
        settle(host)
        return hover
    }

    private func isSeparateChild(_ card: NSView, above anchor: NSView) -> Bool {
        guard let cardWindow = card.window, let sourceWindow = anchor.window else { return false }
        return cardWindow !== sourceWindow && cardWindow.parent === sourceWindow
            && sourceWindow.childWindows?.contains { $0 === cardWindow } == true
    }

    @Test func aSameWindowSwiftUIOverlayFailsTheArchitectureControl() throws {
        let host = testHost(Text("Row").overlay { Text("Card") }, size: CGSize(width: 300, height: 100))
        let window = testWindow(hosting: host, orderFront: false)
        window.orderFront(nil)
        defer { window.close() }
        settle(host)
        let overlay = try #require(host.subviews.first)
        #expect(overlay.window === host.window)
        #expect(!isSeparateChild(overlay, above: host), "a plain same-window overlay must fail the same predicate as the real card")
    }

    @Test func aRealListUsesANonactivatingChildWindowAndTracksLiveLabels() async throws {
        let (controller, task, original) = try fixture()
        defer { controller.shutdown() }
        let (host, window) = HostedSidebar.make(controller)
        defer { window.close() }
        settle(host) { !host.descendants(BackgroundCardAnchor.Probe.self).isEmpty }
        let anchor = try #require(host.descendants(BackgroundCardAnchor.Probe.self).first { $0.source == .task(task.id) })
        let presenter = try #require(anchor.presenter)
        let hover = try await open(anchor, in: host)
        let panel = try #require(presenter.panel)
        #expect(panel.parent === window)
        #expect(window.childWindows?.contains { $0 === panel } == true)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.frame.height > Size.row, "three jobs grow below their source row")
        let content = try #require(panel.contentView as? BackgroundCardHostingView)
        content.layoutSubtreeIfNeeded()
        #expect(isSeparateChild(content, above: anchor))
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let covered = NSPoint(x: panel.frame.midX, y: row.midY)
        let uncovered = NSPoint(x: row.maxX - SidebarRowLayout.trailingSlot(.standard) / 2, y: row.midY)
        #expect(panel.frame.contains(covered))
        #expect(!panel.frame.contains(uncovered))
        let coveredContent = content.superview?.convert(panel.convertPoint(fromScreen: covered), from: nil)
            ?? panel.convertPoint(fromScreen: covered)
        #expect(content.hitTest(coveredContent) != nil)
        #expect(content.hitTest(NSPoint(x: content.bounds.midX, y: content.bounds.midY)) != nil)
        content.updateTrackingAreas()
        #expect(content.trackingAreas.contains { $0.options.contains(.activeAlways) })
        var changed = original
        changed.work[0].displayLabel = "Review the validation results"
        controller.live.handle(.sessionChanged(changed))
        settle(host) { presenter.card?.jobs.first?.label == "Review the validation results" }
        #expect(presenter.panel === panel, "a label refresh keeps the open native card")
        let table = try #require(host.firstDescendant(NSTableView.self))
        let sourceIndex = table.row(for: anchor)
        hover.mark(false)
        await eventually { !hover.isOpen }
        settle(host) { presenter.panel == nil }
        let root = try #require(window.contentView)
        // NSView.hitTest takes a point in its superview's coordinates, even when the
        // receiver is a flipped hosting view. Feeding it root-local coordinates flips twice.
        let contentPoint = root.superview?.convert(window.convertPoint(fromScreen: covered), from: nil)
            ?? window.convertPoint(fromScreen: covered)
        let underlying = try #require(root.hitTest(contentPoint))
        #expect(table.row(for: underlying) == sourceIndex, "closing restores the covered coordinates to the original row")
        try await open(anchor, in: host)
        let reopened = try #require(presenter.panel?.contentView as? BackgroundCardHostingView)
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        reopened.mouseEntered(with: entered)
        hover.mark(false)
        controller.teardown.seedSnapshotState(.removing, of: task.id)
        settle(host) { presenter.panel == nil }
        #expect(!hover.isOpen, "teardown closes even while the pointer is on the card")
        #expect(controller.rows.sections.flatMap(\.tasks).first { $0.id == task.id }?.background.isEmpty == false)
        settle(host, timeout: 1) { !host.descendants(BackgroundCardAnchor.Probe.self).contains { $0.source == .task(task.id) } }
    }

    @Test(arguments: [false, true])
    func aClickOnTheCardChoosesItsSourceOnTheFirstClick(terminal: Bool) async throws {
        let (controller, task, original) = try fixture()
        defer { controller.shutdown() }
        var tab = original
        let source: RowSelection
        if terminal {
            let item = TerminalItem(id: UUID(), projectId: task.projectId, name: "Terminal", windowId: "w", createdAt: Date())
            controller.workspace.mutate { $0.terminals = [item] }
            tab.taskId = nil; tab.terminalId = item.id.uuidString
            source = .terminal(item.id)
        } else { source = .task(task.id) }
        let server = RecordingDaemon()
        controller.helper.setDaemonClient(server)
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
            sessions: [tab], usage: .empty)))
        let (host, window) = HostedSidebar.make(controller)
        defer { window.close() }
        settle(host) { !host.descendants(BackgroundCardAnchor.Probe.self).isEmpty }
        let anchor = try #require(host.descendants(BackgroundCardAnchor.Probe.self).first { $0.source == source })
        try await open(anchor, in: host)
        let panel = try #require(anchor.presenter?.panel)
        let content = try #require(panel.contentView)
        let point = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        settle(host, timeout: 1) { controller.focus.selection == source }
        #expect(controller.focus.selection == source)
    }

    @Test func innerTrackingHoldsTheCardAndListScrollingClosesIt() async throws {
        let (controller, task, _) = try fixture(jobs: 7)
        defer { controller.shutdown() }
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 400, height: 320))
        defer { window.close() }
        settle(host) { !host.descendants(BackgroundCardAnchor.Probe.self).isEmpty }
        let table = try #require(host.firstDescendant(NSTableView.self))
        let initialAnchor = try #require(host.descendants(BackgroundCardAnchor.Probe.self).first { $0.source == .task(task.id) })
        let index = table.row(for: initialAnchor)
        #expect(index >= 0)
        let viewport = try #require(host.firstDescendant(BackgroundCardViewport.Probe.self))
        let target = BackgroundCardView.height(jobs: 2, scale: .standard)
        let contentHeight = try #require(window.contentView).bounds.height
        window.setContentSize(NSSize(width: 400, height: contentHeight - viewport.bounds.height + target))
        settle(host)
        let listScroll = try #require(table.enclosingScrollView)
        // This deliberately short viewport initially clips the source mark. Scroll the actual
        // row into view before asking for a card; a clipped mark must not open a floating card.
        listScroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: index).minY))
        listScroll.reflectScrolledClipView(listScroll.contentView)
        settle(host)
        let anchor = try #require(host.descendants(BackgroundCardAnchor.Probe.self).first { $0.source == .task(task.id) })
        let presenter = try #require(anchor.presenter)
        let hover = try await open(anchor, in: host)
        let content = try #require(presenter.panel?.contentView as? BackgroundCardHostingView)
        #expect(try #require(presenter.panel).frame.height < BackgroundCardView.height(jobs: 5, scale: .standard))
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        // Direct native tracking delivery is meaningful even though the test hook hides windows.
        content.mouseEntered(with: event)
        hover.mark(false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(hover.isOpen)
        content.mouseExited(with: event)
        await eventually { !hover.isOpen }
        settle(host) { presenter.panel == nil }
        #expect(!hover.isOpen, "positive native exit control: the handler must reach the hover owner")
        try await open(anchor, in: host)
        table.scrollRowToVisible(table.numberOfRows - 1)
        settle(host) { presenter.panel == nil }
    }

    @Test func switchingSourcesEmptyJobsAndRemovalReleaseTheOldCard() async throws {
        let (controller, task, tab) = try fixture()
        defer { controller.shutdown() }
        let other = try #require(controller.state.tasks.dropFirst().first)
        controller.workspace.mutate { state in state.tasks[1].windowId = "other-window" }
        var otherTab = SessionInfo.make("other", window: "other-window", task: other.id, state: .working)
        otherTab.work = tab.work
        controller.live.handle(.sessionOpened(otherTab))
        let (host, window) = HostedSidebar.make(controller)
        defer { window.close() }
        settle(host) { host.descendants(BackgroundCardAnchor.Probe.self).count >= 2 }
        let anchors = host.descendants(BackgroundCardAnchor.Probe.self)
        let first = try #require(anchors.first { $0.source == .task(task.id) })
        let second = try #require(anchors.first { $0.source == .task(other.id) })
        let presenter = try #require(first.presenter)
        let oldHover = try await open(first, in: host)
        let oldPanel = try #require(presenter.panel)
        let oldContent = try #require(oldPanel.contentView as? BackgroundCardHostingView)
        let nextHover = try await open(second, in: host)
        #expect(!oldHover.isOpen && oldPanel.parent == nil && oldPanel.contentView == nil)
        #expect(presenter.panel !== oldPanel)
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let nextContent = try #require(presenter.panel?.contentView as? BackgroundCardHostingView)
        nextContent.mouseEntered(with: exit)
        nextHover.mark(false)
        oldContent.mouseExited(with: exit)
        try await Task.sleep(for: .milliseconds(200))
        #expect(nextHover.isOpen, "a queued event from the retired panel cannot close the new card")
        otherTab.work = []
        controller.live.handle(.sessionChanged(otherTab))
        settle(host) { presenter.panel == nil }
        try await open(first, in: host)
        controller.workspace.mutate { $0.tasks.removeAll { $0.id == task.id } }
        settle(host) { presenter.panel == nil }
    }

    @Test(arguments: InterfaceSize.allCases)
    func thePanelFitsItsViewportAndOnlyItsJobsScroll(size: InterfaceSize) async throws {
        let (controller, task, _) = try fixture(jobs: 7)
        defer { controller.shutdown() }
        controller.preferences.interfaceSize = size
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 500, height: 600))
        defer { window.close() }
        settle(host) { !host.descendants(BackgroundCardAnchor.Probe.self).isEmpty }
        let anchor = try #require(host.descendants(BackgroundCardAnchor.Probe.self).first { $0.source == .task(task.id) })
        let presenter = try #require(anchor.presenter)
        try await open(anchor, in: host)
        let panel = try #require(presenter.panel)
        let viewport = try #require(host.firstDescendant(BackgroundCardViewport.Probe.self))
        func available() -> NSRect { window.convertToScreen(viewport.convert(viewport.bounds, to: nil)) }
        #expect(available().contains(panel.frame))
        let scale = size.scale
        #expect(panel.frame.height <= BackgroundCardView.height(jobs: 5, scale: scale))
        let content = try #require(panel.contentView)
        settle(content) { content.firstDescendant(NSScrollView.self)?.documentView != nil }
        let scroll = try #require(content.firstDescendant(NSScrollView.self))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        if let directory = ProcessInfo.processInfo.environment["AITERM_UI_EVIDENCE_DIR"] {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: output.appendingPathComponent("background-card-\(size.rawValue).png"))
        }
        // The native scrolling area starts below the fixed heading. Geometry is in the panel's
        // own views; no window-server lookup or real cursor is involved.
        let scrollRect = content.convert(scroll.bounds, from: scroll)
        let header = content.isFlipped ? content.bounds.minY : content.bounds.maxY
        let edge = content.isFlipped ? scrollRect.minY : scrollRect.maxY
        #expect(abs(header - edge) >= scale(Space.base) + scale(Size.chip))
        let beforeScroll = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin != beforeScroll, "the native clip view must actually scroll")
        #expect(presenter.panel === panel, "inner scrolling leaves the source card open")
        // Keep the source itself eligible across scales; the short-viewport test above scrolls
        // its source into view separately before testing the reduced visible-job count.
        window.setContentSize(NSSize(width: 500, height: 480))
        settle(host)
        let smaller = try #require(presenter.panel)
        #expect(available().contains(smaller.frame))
        controller.preferences.interfaceSize = .extraLarge
        settle(host)
        #expect(presenter.panel != nil, "changing interface size repositions an eligible open card")
        window.close()
        #expect(presenter.panel == nil)
    }

    @Test func aBottomSourceMovesTheCardUpWithoutCoveringItsMark() async throws {
        let (controller, _, original) = try fixture(jobs: 7)
        defer { controller.shutdown() }
        let task = try #require(controller.state.tasks.last)
        controller.workspace.mutate { $0.tasks[$0.tasks.count - 1].windowId = "bottom" }
        var tab = SessionInfo.make("bottom-worker", window: "bottom", task: task.id, state: .working)
        tab.work = original.work
        controller.live.handle(.sessionOpened(tab))
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 400, height: 420))
        defer { window.close() }
        settle(host) { host.firstDescendant(NSTableView.self) != nil }
        let table = try #require(host.firstDescendant(NSTableView.self))
        table.scrollRowToVisible(table.numberOfRows - 1)
        settle(host) { host.descendants(BackgroundCardAnchor.Probe.self).contains { $0.source == .task(task.id) } }
        let anchor = try #require(host.descendants(BackgroundCardAnchor.Probe.self).first { $0.source == .task(task.id) })
        let presenter = try #require(anchor.presenter)
        try await open(anchor, in: host)
        let panel = try #require(presenter.panel)
        let viewport = try #require(host.firstDescendant(BackgroundCardViewport.Probe.self))
        let available = window.convertToScreen(viewport.convert(viewport.bounds, to: nil))
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        #expect(available.contains(panel.frame))
        #expect(panel.frame.maxX <= row.maxX - SidebarRowLayout.trailingSlot(.standard) - Space.tight)
        #expect(panel.frame.maxY > row.maxY)
        window.setContentSize(NSSize(width: 400, height: 450))
        settle(host)
        let resized = try #require(presenter.panel, "layout-induced clip movement must not dismiss the card")
        let resizedAvailable = window.convertToScreen(viewport.convert(viewport.bounds, to: nil))
        #expect(resizedAvailable.contains(resized.frame))
    }
}
