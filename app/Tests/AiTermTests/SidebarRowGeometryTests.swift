import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermTestSupport
@testable import AiTermCore
@testable import AiTerm

/// The sidebar paints three row backgrounds — clear, the hover wash, the selection fill — and the
/// canvas ("Task row · Size.row, indented Space.section, Radius.control") asks all three to be the
/// same pill: the indent sits *outside* it, so the fill stops `Space.section` from the sidebar's
/// edge. That only holds while one painter owns every state; when `List`'s own row highlight drew
/// the selected one it ran 26 pt further left and 6 pt further right than the hover pill.
///
/// Rendered rather than asserted on the view tree, because the pill is a `.background` modifier:
/// pixels are the only place the two rectangles can be compared.
@MainActor
struct SidebarRowGeometryTests {
    /// The bounding box, in points relative to `row`, of everything a row paints over the sidebar's
    /// own backdrop. A filled row's outermost ink is its pill, so this box is the pill.
    private func paintedBox(bitmap: NSBitmapImageRep, scale: CGFloat, row: CGRect, backdrop: NSColor) -> CGRect? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in Int(row.minY * scale)..<Int(row.maxY * scale) {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                let delta = abs(c.redComponent - backdrop.redComponent) + abs(c.greenComponent - backdrop.greenComponent)
                    + abs(c.blueComponent - backdrop.blueComponent)
                guard delta > 0.01 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale - row.minY,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// The selected and hovered rows' pills, rendered with the sidebar at `size`.
    private func pills(size: InterfaceSize) throws -> (selected: CGRect, hovered: CGRect) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let project = Project.make(name: "Repo", path: "/repo", addedAt: Date())
        // Three identical rows so the pills can only differ by the state that is drawn on them.
        let tasks = ["Selected row", "Hovered row", "Resting row"].map { title in
            TaskItem.make(project: project.id, title: title, worktreePath: "/wt", model: "sonnet", createdAt: Date(),
                windowId: "w-" + title)
        }
        controller.workspace.mutate { $0.items = [.project(project)] }; controller.workspace.mutate { $0.tasks = tasks }
        controller.focus.browse(.task(tasks[0].id))
        controller.preferences.interfaceSize = size

        let host = testHost(SidebarView(controller: controller).environment(\.seededHover, SeededHover(row: tasks[1].id)), size: CGSize(width: size.scale(340), height: 800))
        let window = testWindow(contentRect: host.frame, styleMask: [.titled])
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows ?? 0 > 0 }

        let list = try #require(host.firstDescendant(NSTableView.self))
        // The OPERATOR heading, the PROJECTS heading and the project row come first; the three task rows follow in order.
        #expect(list.numberOfRows == 6)
        let selectedRow = host.convert(list.rect(ofRow: 3), from: list)
        let hoveredRow = host.convert(list.rect(ofRow: 4), from: list)
        #expect(list.selectedRow == 3)
        #expect(selectedRow.size == hoveredRow.size)

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        // Empty list, below the last row: the backdrop every pill is measured against.
        let backdrop = try #require(bitmap.colorAt(x: 1, y: Int((host.convert(list.rect(ofRow: 5), from: list).maxY + 20) * scale)))
        let selected = try #require(paintedBox(bitmap: bitmap, scale: scale, row: selectedRow, backdrop: backdrop))
        let hovered = try #require(paintedBox(bitmap: bitmap, scale: scale, row: hoveredRow, backdrop: backdrop))
        return (selected, hovered)
    }

    /// The signals disc lies over the avatar column without widening it: the title column starts at the same x with
    /// and without it, at every interface size, and the disc paints inside the row.
    @Test(arguments: InterfaceScale.all)
    func theTitleStartsWhereItDidWithADisc(scale: InterfaceScale) throws {
        func render(disc: Bool) throws -> NSBitmapImageRep {
            let content = SidebarRowContent(avatars: AvatarGroup(marks: [.claude, .codex], overflow: 0), signalDisc: disc) {
                Rectangle().fill(Palette.amber).frame(height: scale(Size.chip))
            } mark: { EmptyView() }
            let renderer = ImageRenderer(content: content.frame(width: 300).padding(scale(Space.base))
                .background(Palette.sidebar).surface(.sidebar).interfaceScale(scale))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        func firstAmber(_ bitmap: NSBitmapImageRep) throws -> Int? {
            // The column's middle is the rectangle's: its colour as drawn.
            let y = bitmap.pixelsHigh / 2
            let amber = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
            return (0..<bitmap.pixelsWide).first { x in
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(c.redComponent - amber.redComponent) + abs(c.greenComponent - amber.greenComponent)
                    + abs(c.blueComponent - amber.blueComponent) < 0.05
            }
        }
        let plain = try render(disc: false), disc = try render(disc: true)
        #expect(plain.pixelsWide == disc.pixelsWide && plain.pixelsHigh == disc.pixelsHigh, "the row keeps its size")
        let title = try #require(try firstAmber(plain))
        #expect(try firstAmber(disc) == title, "the title column starts at the same x")
        var differs = false
        for y in 0..<plain.pixelsHigh where !differs {
            for x in 0..<title where plain.colorAt(x: x, y: y) != disc.colorAt(x: x, y: y) { differs = true; break }
        }
        #expect(differs, "the disc is drawn, left of the title")
    }

    @Test func selectionAndHoverPaintTheSamePill() throws {
        let (selected, hovered) = try pills(size: .standard)
        #expect(selected == hovered, "selection pill \(selected) and hover pill \(hovered) must be the same rectangle")
        // Both stop short of the sidebar's leading edge: the indent is outside the pill.
        #expect(selected.minX > Space.section)
        #expect(abs(selected.height - Size.row) < 0.5)
    }

    /// At every larger step the pill is one `Size.row` tall at that step's scale: the row's two
    /// lines and their padding grow together, and nothing inside it outgrows the minimum height.
    /// Default is `selectionAndHoverPaintTheSamePill`'s, and every render here is seconds of main
    /// actor, so it is not drawn twice.
    @Test(arguments: [InterfaceSize.large, .extraLarge])
    func theRowPillIsARowAtEveryScale(size: InterfaceSize) throws {
        let (selected, hovered) = try pills(size: size)
        #expect(abs(selected.height - size.scale(Size.row)) < 0.5, "at \(size): \(selected) vs \(hovered)")
        #expect(selected == hovered, "at \(size)")
    }
}

/// AppKit paints a *second* row decoration that `selectionHighlightStyle = .none` does not reach:
/// the ring it draws around a row whose context menu is open. It covers the whole row rect, so
/// right-clicking a task summoned a third state, larger than both hover and selection, over the
/// pill the canvas asks for — the same two-painter split ``SidebarRowGeometryTests`` exists to stop,
/// arriving through a different door.
@MainActor
struct SidebarContextMenuHighlightTests {
    /// Hands back the sidebar's table, hosted and laid out, plus the host it is drawn in.
    private func hostedSidebar() throws -> (host: NSHostingView<SidebarView>, table: NSTableView, window: NSWindow) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let project = Project.make(name: "Repo", path: "/repo", addedAt: Date())
        let task = TaskItem.make(project: project.id, title: "Right-clicked row", worktreePath: "/wt", model: "sonnet",
            createdAt: Date(), windowId: "w-1")
        controller.workspace.mutate { $0.items = [.project(project)] }; controller.workspace.mutate { $0.tasks = [task] }
        controller.focus.browse(.task(task.id))

        let host = testHost(SidebarView(controller: controller), size: CGSize(width: 340, height: 300))
        let window = testWindow(contentRect: host.frame, styleMask: [.titled])
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows ?? 0 > 0 }

        return (host, try #require(host.firstDescendant(NSTableView.self)), window)
    }

    /// The ink a row lays down over the sidebar's backdrop, as a box relative to the row.
    private func paintedBox(host: NSView, table: NSTableView, row: Int) throws -> CGRect {
        let rowRect = host.convert(table.rect(ofRow: row), from: table)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let backdrop = try #require(bitmap.colorAt(x: 1, y: Int((rowRect.maxY + 30) * scale)))
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in Int(rowRect.minY * scale)..<Int(rowRect.maxY * scale) {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                let delta = abs(c.redComponent - backdrop.redComponent) + abs(c.greenComponent - backdrop.greenComponent)
                    + abs(c.blueComponent - backdrop.blueComponent)
                guard delta > 0.01 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { throw TestFailure.nothingPainted }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale - rowRect.minY,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private enum TestFailure: Error { case nothingPainted }

    @Test func aRowsContextMenuPaintsNothingOutsideItsPill() throws {
        let (host, table, window) = try hostedSidebar()
        defer { window.orderOut(nil) }
        // OPERATOR, PROJECTS, the project row, then the one task.
        #expect(table.numberOfRows == 4)
        let pill = try paintedBox(host: host, table: table, row: 3)

        // What AppKit does when the row's context menu opens.
        #expect(ContextMenuHighlight.silence(),
                "AppKit renamed drawContextMenuHighlightForRow: — the ring has no off switch any more")
        let setUp = NSSelectorFromString("_setupContextMenuHighlightingForRow:column:")
        #expect(table.responds(to: setUp), "AppKit no longer highlights the clicked row this way — recheck the fix")
        typealias SetUpFn = @convention(c) (AnyObject, Selector, Int, Int) -> Void
        unsafeBitCast(table.method(for: setUp)!, to: SetUpFn.self)(table, setUp, 4, 0)
        host.display()

        let highlighted = try paintedBox(host: host, table: table, row: 3)
        #expect(highlighted == pill, "the context menu ring \(highlighted) grew the row past its pill \(pill)")
    }
}
