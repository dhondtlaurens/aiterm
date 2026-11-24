import AppKit
import SwiftUI
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A task row's badges keep their own tooltips: a `.help` on the row around them, even an empty one, wins over
/// theirs, so a row with nothing to say must put none on (`RowHelp`).
@MainActor @Suite(.serialized) struct TaskRowTooltipTests {
    @Test func aSettledBadgeSaysItsStateOnHover() throws {
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
        #expect(shown.contains("Approved · Gift cards at the till · 6 of 6 threads resolved"))
        #expect(shown.contains("Merged · Loyalty points on receipts"))
        #expect(shown.contains("Done · https://example/SHOP-1720"))
    }
}

/// The tooltips a SwiftUI host would show, read the way AppKit asks for them on hover: SwiftUI answers through the
/// host's dynamic tooltip manager, private API with no public way in. If an OS release renames it, `shown` throws
/// rather than finding nothing.
@MainActor enum Tooltips {
    struct Unreadable: Error {}

    static func shown(in host: NSView, step: CGFloat = 2) throws -> Set<String> {
        let managerGetter = NSSelectorFromString("_dynamicToolTipManager")
        let stringAt = NSSelectorFromString("dynamicToolTipStringAtPoint:trackingRect:")
        guard host.responds(to: managerGetter),
              let manager = host.perform(managerGetter)?.takeUnretainedValue() as? NSObject,
              manager.responds(to: stringAt) else { throw Unreadable() }
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
