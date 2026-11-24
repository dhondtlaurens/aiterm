import AppKit
import SwiftUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A task row's badges have no tooltip of their own: not the ticket's URL, the request's title, VS Code's diff nor the
/// branch. A checked or merged badge says its state on a `HoverChip` instead, at once; the row's own tooltip, when it has one,
/// is all a hover over the badge line can bring up.
@MainActor @Suite(.serialized) struct TaskRowTooltipTests {
    @Test func noBadgeInATaskRowHasATooltip() throws {
        let fixture = Fixture(), controller = fixture.controller(), project = fixture.project
        let gitLab = "https://gitlab.example/acme/storefront/-/"
        func review(_ title: String, _ number: Int, ticket: JiraRef? = nil) -> TaskItem {
            TaskItem(id: UUID(), projectId: project.id, title: title, branch: "review/\(number)",
                     worktreePath: "/r/.worktrees/review-\(number)", baseBranch: "main", jira: ticket, kind: .review,
                     mr: MergeRequestRef(iid: number, title: title, url: gitLab + "merge_requests/\(number)"), agent: .claude,
                     model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(),
                     windowId: "review-\(number)")
        }
        let rows = [review("Gift cards at the till", 95),
                    review("Loyalty points on receipts", 98),
                    review("Drop the unused CDN origin", 7,
                           ticket: JiraRef(key: "SHOP-1720", summary: "Drop the unused CDN origin", url: "https://example/SHOP-1720"))]
        controller.workspace.mutate { $0.tasks = rows }
        controller.reviewThreads.seedSnapshotThreads(.init(resolved: 6, total: 6, approved: true), of: rows[0].id)
        controller.reviewThreads.seedSnapshotThreads(.init(resolved: 3, total: 3, merged: true), of: rows[1].id)
        controller.ticketsDone.seedSnapshotDone(true, of: rows[2].id)
        let projection = controller.rows
        let (window, host) = testWindow(hosting: SnapshotColumn {
            SidebarView.taskRows(of: projection.sections[0], in: projection, controller: controller)
        })
        defer { window.orderOut(nil) }
        settle(host, for: 0.3)

        let shown = try Tooltips.shown(in: host)
        let badgeWords = ["Approved", "Merged", "Done", "https://", "Gift cards at the till", "Loyalty points on receipts",
                          "SHOP-1720", "VS Code", "review/95", "review/98", "review/7"]
        let leaked = shown.filter { tip in badgeWords.contains { tip.contains($0) } }
        #expect(leaked.isEmpty, "badge tooltips shown: \(leaked)")
    }

    /// The row's own tooltip stays: a row with something to say, here its worktree missing, still says it over its
    /// badge line, a merged request's included, and nothing else does.
    @Test func theRowsOwnTooltipStays() throws {
        let fixture = Fixture(), controller = fixture.controller(), project = fixture.project
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Loyalty points on receipts", branch: "review/98",
                            worktreePath: "/r/.worktrees/review-98", baseBranch: "main",
                            jira: JiraRef(key: "SHOP-1721", summary: "Loyalty points", url: "https://example/SHOP-1721"), kind: .review,
                            mr: MergeRequestRef(iid: 98, title: "Loyalty points on receipts",
                                                url: "https://gitlab.example/acme/storefront/-/merge_requests/98"),
                            agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(),
                            windowId: "review-98")
        controller.workspace.mutate { $0.tasks = [task] }
        controller.reviewThreads.seedSnapshotThreads(.init(resolved: 3, total: 3, merged: true), of: task.id)
        controller.checkouts.seedSnapshotFixture(WorkspaceScan(branchByCwd: [:], projectBranch: [:],
                                                               missingCheckouts: [task.id], removedTasks: [], remotes: [:]))
        let projection = controller.rows
        let row = try #require(projection.sections.first?.tasks.first)
        let help = TaskRowAccessibility(row: row, missing: true).help
        try #require(!help.isEmpty)
        let (window, host) = testWindow(hosting: SnapshotColumn {
            SidebarView.taskRows(of: projection.sections[0], in: projection, controller: controller)
        })
        defer { window.orderOut(nil) }
        settle(host, for: 0.3)

        #expect(try Tooltips.shown(in: host) == [help])
    }
}

/// The tooltips a SwiftUI host would show, read the way AppKit asks for them on hover: SwiftUI answers through the
/// host's dynamic tooltip manager, private API with no public way in. If an OS release renames it, `shown` throws
/// rather than finding nothing. The host makes its manager only once something in it has a tooltip, so a host
/// without one shows none; `theRowsOwnTooltipStays` keeps proving the reader still reads.
@MainActor enum Tooltips {
    struct Unreadable: Error {}

    static func shown(in host: NSView, step: CGFloat = 2) throws -> Set<String> {
        let managerGetter = NSSelectorFromString("_dynamicToolTipManager")
        let stringAt = NSSelectorFromString("dynamicToolTipStringAtPoint:trackingRect:")
        guard host.responds(to: managerGetter) else { throw Unreadable() }
        guard let manager = host.perform(managerGetter)?.takeUnretainedValue() as? NSObject else { return [] }
        guard manager.responds(to: stringAt) else { throw Unreadable() }
        typealias StringAt = @convention(c) (AnyObject, Selector, NSPoint, UnsafeMutablePointer<NSRect>) -> Unmanaged<NSString>?
        let call = unsafeBitCast(manager.method(for: stringAt), to: StringAt.self)
        var shown: Set<String> = []
        for y in stride(from: 0, through: host.bounds.height, by: step) {
            for x in stride(from: 0, through: host.bounds.width, by: step) {
                var rect = NSRect.zero
                if let text = call(manager, stringAt, NSPoint(x: x, y: y), &rect)?.takeUnretainedValue() { shown.insert(text as String) }
            }
        }
        return shown
    }
}
