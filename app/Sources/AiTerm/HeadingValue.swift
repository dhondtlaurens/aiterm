import Foundation
import AiTermCore
import AiTermUI

/// A heading draws counts only while folded; child rows and their bookkeeping are absent.
struct HeadingValue: Equatable, Identifiable {
    enum Kind: Equatable {
        case project(Project, canMoveUp: Bool, canMoveDown: Bool)
        case signal(source: SignalSource, removed: Bool, paused: Bool)
    }
    var id: UUID
    var mark: IconSource
    var title: String
    var collapsed: Bool
    var empty: Bool
    var counts: [StatusCount]
    var help: String
    var kind: Kind

    init(_ section: ProjectSection) {
        let project = section.project
        id = project.id; mark = ProviderIcon.source(of: project.provider); title = project.name
        collapsed = section.collapsed; empty = section.isEmpty; help = ""
        counts = collapsed ? SidebarModel.statusCounts(tasks: section.tasks, terminals: section.terminals) : []
        kind = .project(project, canMoveUp: section.canMoveUp, canMoveDown: section.canMoveDown)
    }

    init(_ section: SignalSection) {
        let signal = section.signal
        let source = signal.source, removed = section.removed
        id = signal.id; mark = ProviderIcon.source(of: source); title = signal.name
        kind = .signal(source: source, removed: removed, paused: !removed && !signal.enabled)
        collapsed = section.collapsed; empty = section.tasks.isEmpty
        counts = collapsed ? SidebarModel.statusCounts(tasks: section.tasks) : []
        let conditions: String
        if !source.isSupported { conditions = "This version cannot run this signal." }
        else {
            switch source {
            case .jira(let query): conditions = JQL.compile(query)
            case .gitLab(let query), .gitHub(let query):
                conditions = query.event == .reviewRequested ? "When you are asked to review" : "Your requests waiting on your reply or sent back to you"
            case .unknown: conditions = "This version cannot run this signal."
            }
        }
        help = ([conditions] + (source.isSupported && !signal.finish.isValid(for: source) ? ["This version cannot run these finish settings."] : []) + (removed ? ["This signal was removed. Its existing tasks carry on with their saved instructions."] : [])
                + section.skipped + [section.failure].compactMap { $0 }).joined(separator: "\n")
    }
}
