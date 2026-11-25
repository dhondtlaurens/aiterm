import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermTestSupport
@testable import AiTermCore
@testable import AiTerm

/// The status line runs down the sidebar's trailing column from row to row, so each row's segment has
/// to meet its neighbour's across the gap the list leaves between two rows. Whether the table's row
/// or cell views clip a segment drawn past its pill is AppKit's business, not SwiftUI's: only the
/// pixels say whether the line is continuous.
///
/// What the probe found (Nov 2026): the gap is 8 pt at every interface size — the list's own row
/// inset, unscaled — and it belongs to the rows on either side. Each `ListTableCellView` spans its
/// whole row rect, 4 pt above and below the pill, and does not clip; the `NSTableRowView` does. So a
/// segment reaching `Space.tight` past its pill paints its own row's half of the gap and the
/// neighbour's paints the other half (`StatusLineReach.halfGap`). No segment can paint into its
/// neighbour's rect. Measured here on the real sidebar: the Operator's row, an open project's heading
/// and two tasks, a divider and a folded project's stop.
@MainActor
struct StatusLineSeamTests {
    private struct Capture {
        let bitmap: NSBitmapImageRep
        /// Pixels per point.
        let scale: CGFloat
        /// The list's rows, in the host's top-down points.
        let rows: [CGRect]
        let backdrop: NSColor

        func inked(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y) else { return false }
            return abs(c.redComponent - backdrop.redComponent) + abs(c.greenComponent - backdrop.greenComponent)
                + abs(c.blueComponent - backdrop.blueComponent) > 0.03
        }
        /// Whether the line paints pixel row `y` within a pixel of column `x`.
        func line(_ x: Int, _ y: Int) -> Bool { (x - 1...x + 1).contains { inked($0, y) } }
        /// Whether pixel row `y` within a pixel of column `x` differs from the ground a few points beside it: inside a
        /// washed pill, where the sidebar's own backdrop is not the ground.
        func standsOut(_ x: Int, _ y: Int) -> Bool {
            guard let ground = bitmap.colorAt(x: x - Int(Space.tight * scale), y: y) else { return false }
            return (x - 1...x + 1).contains { x in
                guard let c = bitmap.colorAt(x: x, y: y) else { return false }
                return abs(c.redComponent - ground.redComponent) + abs(c.greenComponent - ground.greenComponent)
                    + abs(c.blueComponent - ground.blueComponent) > 0.03
            }
        }
    }

    /// The sidebar at `size`, with the Operator's section open on: OPERATOR, its row, shop's heading, two tasks it runs,
    /// the "Later" divider, docs' heading folded on a third task, PROJECTS.
    private func capture(size: InterfaceSize) throws -> (Capture, NSWindow) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.workspace.load()
        let shop = Project.make(name: "shop", path: "/shop", addedAt: Date()), docs = Project.make(name: "docs", path: "/docs", addedAt: Date())
        let signal = Signal(name: "Tickets", createdAt: Date(), start: SignalTrigger(source: .jira, query: "labels = operator"),
                            done: SignalTrigger(source: .jira, query: "status = Done"), work: SignalWork(prompt: "Work"),
                            agents: [.init(agent: .claude, model: "opus", reasoning: nil)], finish: SignalFinish(then: .keep))
        let tasks = [(shop, "One"), (shop, "Two"), (docs, "Three")].enumerated().map { index, pair in
            var task = TaskItem.make(project: pair.0.id, title: pair.1, worktreePath: "/wt\(index)", model: "sonnet", createdAt: Date())
            var record = SignalTask.make(signal: signal, item: .ticket(site: "https://jira.example", key: "PAY-\(index)"), startedAt: Date())
            record.phase = .working
            task.signalTask = record
            return task
        }
        controller.workspace.mutate { state in
            state.items = [.project(shop), .divider(SidebarDivider(id: UUID(), name: "Later")), .project(docs)]
            state.tasks = tasks; state.signals = [signal]
            state.operatorSession = OperatorSession(createdAt: Date())
            state.operatorOpen = true; state.operatorFolded = [docs.id]
        }
        controller.focus.browse(nil)
        controller.preferences.interfaceSize = size

        let host = testHost(SidebarView(controller: controller), size: CGSize(width: size.scale(340), height: size.scale(700)))
        let window = testWindow(contentRect: host.frame, styleMask: [.titled])
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host) { host.firstDescendant(NSTableView.self)?.numberOfRows ?? 0 == 8 }
        settle(host, for: 0.1)

        let table = try #require(host.firstDescendant(NSTableView.self))
        #expect(table.numberOfRows == 8)
        let rows = (0..<table.numberOfRows).map { host.convert(table.rect(ofRow: $0), from: table) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let backdrop = try #require(bitmap.colorAt(x: 1, y: Int(rows[1].maxY * scale)))
        return (Capture(bitmap: bitmap, scale: scale, rows: rows, backdrop: backdrop), window)
    }

    /// The seam guard: the line is continuous across every gap between two rows it runs through, from the Operator's
    /// row to the folded project's stop, and nothing past the stop; at every size.
    @Test(arguments: [InterfaceSize.standard, .large, .extraLarge])
    func theLineCrossesEveryGapBetweenItsRows(size: InterfaceSize) throws {
        let (c, window) = try capture(size: size); defer { window.orderOut(nil) }
        // The column: what paints across the first seam, where only the line can.
        let seam = Int(c.rows[1].maxY * c.scale)
        let xs = (0..<c.bitmap.pixelsWide).filter { c.inked($0, seam) }
        let x = try #require(xs.isEmpty ? nil : (xs.first! + xs.last!) / 2, "at \(size) nothing paints the first seam")
        #expect(CGFloat(xs.count) <= 3 * c.scale, "at \(size) only the line paints the seam: \(xs.count) pixels")
        for row in 1...5 {
            let boundary = c.rows[row].maxY
            let band = Int((boundary - Space.tight) * c.scale) + 1..<Int((boundary + Space.tight) * c.scale)
            let gaps = band.filter { !c.line(x, $0) }
            #expect(gaps.isEmpty, "at \(size) the line leaves \(gaps.count) of \(band.count) pixel rows unpainted below row \(row)")
        }
        let past = Int((c.rows[6].maxY + Space.tight) * c.scale)
        #expect(!c.line(x, past), "at \(size) the line ends at the stop")
    }

    /// The line stops `Space.base` from the Operator's mark's centre, 3 pt clear of its ring, and meets its stop.
    @Test(arguments: [InterfaceSize.standard, .large, .extraLarge])
    func theLineStandsClearOfTheMark(size: InterfaceSize) throws {
        let (c, window) = try capture(size: size); defer { window.orderOut(nil) }
        let seam = Int(c.rows[1].maxY * c.scale)
        let xs = (0..<c.bitmap.pixelsWide).filter { c.inked($0, seam) }
        let x = try #require(xs.isEmpty ? nil : (xs.first! + xs.last!) / 2)
        let scale = size.scale, centre = c.rows[1].midY
        let ring = scale(Size.trailingGlyph) / 2, gap = scale(Space.base)
        // Clear between the ring's edge and the line's end, inset half a point for antialiasing.
        let clear = Int((centre + ring + 0.5) * c.scale)..<Int((centre + gap - 0.5) * c.scale)
        #expect(!clear.isEmpty && clear.allSatisfy { !c.standsOut(x, $0) }, "at \(size) something paints between the ring and the line")
        #expect(c.standsOut(x, Int((centre + gap + 1) * c.scale)), "at \(size) the line starts \(gap) pt below the mark's centre")
        #expect(c.line(x, Int(c.rows[6].midY * c.scale)), "at \(size) the stop sits on the folded heading's row")
    }
}
