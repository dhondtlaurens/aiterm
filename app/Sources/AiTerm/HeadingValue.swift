import Foundation
import AiTermCore
import AiTermUI

/// A heading draws counts only while folded; child rows and their bookkeeping are absent.
struct HeadingValue: Equatable, Identifiable {
    enum Kind: Equatable {
        case project(Project, canMoveUp: Bool, canMoveDown: Bool)
        /// A project's heading in the Operator's section: a label over the tasks the Operator runs there, with no menu.
        case operatorProject(Project)
    }
    var id: UUID
    var mark: IconSource
    var title: String
    var collapsed: Bool
    var empty: Bool
    var counts: [StatusCount]
    /// A folded Operator project's finished tasks, counted apart from the statuses in the green chip; none on a project.
    var finished = 0
    var help: String
    var kind: Kind
    /// Whether it heads a project in the Operator's section, whose trailing slot carries the status line.
    var isOperatorProject: Bool { if case .operatorProject = kind { true } else { false } }

    init(_ section: ProjectSection) {
        let project = section.project
        id = project.id; mark = ProviderIcon.source(of: project.provider); title = project.name
        collapsed = section.collapsed; empty = section.isEmpty; help = ""
        counts = collapsed ? SidebarModel.statusCounts(tasks: section.tasks, terminals: section.terminals) : []
        kind = .project(project, canMoveUp: section.canMoveUp, canMoveDown: section.canMoveDown)
    }

    /// A project in the Operator's section (`SignalSidebar.operatorEntries`): its mark and name, under its own id
    /// (`OperatorSession.projectRowID`), its fold the Operator section's (`AppState.operatorFolded`). Folded, it counts
    /// its unfinished tasks by status and its finished ones apart.
    init(operatorSection section: ProjectSection) {
        let project = section.project
        id = OperatorSession.projectRowID(project.id); mark = ProviderIcon.source(of: project.provider); title = project.name
        collapsed = section.collapsed; empty = section.tasks.isEmpty; help = ""
        counts = collapsed ? SidebarModel.statusCounts(tasks: section.tasks.filter { !$0.countsAsFinished }) : []
        finished = collapsed ? section.tasks.filter(\.countsAsFinished).count : 0
        kind = .operatorProject(project)
    }
}
