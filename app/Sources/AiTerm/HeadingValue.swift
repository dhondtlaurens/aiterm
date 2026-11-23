import Foundation
import AiTermCore
import AiTermUI

/// A heading draws counts only while folded; child rows and their bookkeeping are absent.
struct HeadingValue: Equatable, Identifiable {
    enum Kind: Equatable {
        case project(Project, canMoveUp: Bool, canMoveDown: Bool)
        case signal(source: SignalTrigger.Source, removed: Bool, paused: Bool, canMoveUp: Bool, canMoveDown: Bool)
    }
    var id: UUID
    var mark: IconSource
    var title: String
    var collapsed: Bool
    var empty: Bool
    var counts: [StatusCount]
    /// A folded signal's finished tasks, counted apart from the statuses in the green chip; none on a project.
    var finished = 0
    var help: String
    var kind: Kind

    init(_ section: ProjectSection) {
        let project = section.project
        id = project.id; mark = ProviderIcon.source(of: project.provider); title = project.name
        collapsed = section.collapsed; empty = section.isEmpty; help = ""
        counts = collapsed ? SidebarModel.statusCounts(tasks: section.tasks, terminals: section.terminals) : []
        kind = .project(project, canMoveUp: section.canMoveUp, canMoveDown: section.canMoveDown)
    }

    /// A signal heading's first tooltip lines: when it starts (a schedule in words, its cron and next run) and when
    /// it is done (a query, or the Operator with its guidance).
    static func triggers(_ signal: Signal, nextRun: Date?, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        var lines: [String]
        if signal.isScheduled {
            let reading = signal.start.cron.map { $0.reading + " (" + $0.expression + ")" } ?? signal.start.query
            lines = ["Starts: " + reading]
            if let nextRun { lines.append("Next run: " + ScheduleDecision.runTime(nextRun, calendar: calendar)) }
        } else {
            lines = ["Starts: " + signal.start.query]
        }
        let guidance = signal.done.description.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(signal.done.source == .operator ? "Done: The Operator decides" + (guidance.isEmpty ? "" : " (" + guidance + ")")
                                                       : "Done: " + signal.done.query)
        return lines
    }

    init(_ section: SignalSection) {
        let signal = section.signal
        let source = signal.start.source, removed = section.removed
        id = signal.id; mark = ProviderIcon.source(of: source); title = signal.name
        kind = .signal(source: source, removed: removed, paused: !removed && !signal.enabled,
                       canMoveUp: section.canMoveUp, canMoveDown: section.canMoveDown)
        collapsed = section.collapsed; empty = section.tasks.isEmpty
        counts = collapsed ? SidebarModel.statusCounts(tasks: section.tasks.filter { !$0.countsAsFinished }) : []
        finished = collapsed ? section.tasks.filter(\.countsAsFinished).count : 0
        let triggers = Self.triggers(signal, nextRun: section.nextRun) + (signal.isValid ? [] : ["This version cannot run this signal."])
        help = (triggers + (removed ? ["This signal was removed. Its existing tasks carry on with their saved instructions."] : [])
                + section.skipped + [section.failure].compactMap { $0 }).joined(separator: "\n")
    }
}
