import Foundation
import AiTermCore

/// A heading draws counts only while folded; child rows and their bookkeeping are absent.
struct SignalHeadingValue: Equatable, Identifiable {
    var id: UUID
    var name: String
    var source: SignalSource
    var enabled: Bool
    var collapsed: Bool
    var empty: Bool
    var removed: Bool
    var counts: [StatusCount]
    var help: String
    init(_ section: SignalSection) {
        let signal = section.signal
        id = signal.id; name = signal.name; source = signal.source; enabled = signal.enabled
        collapsed = section.collapsed; empty = section.tasks.isEmpty; removed = section.removed
        counts = collapsed ? SidebarModel.statusCounts(tasks: section.tasks) : []
        let conditions: String
        switch source {
        case .jira(let query): conditions = JQL.compile(query)
        case .gitLab(let query), .gitHub(let query):
            conditions = query.event == .reviewRequested ? "When you are asked to review" : "Your requests waiting on your reply or sent back to you"
        case .unknown: conditions = "This version cannot run this signal."
        }
        help = ([conditions] + (removed ? ["This signal was removed. Its existing tasks carry on with their saved instructions."] : [])
                + section.skipped + [section.failure].compactMap { $0 }).joined(separator: "\n")
    }
}
