import Foundation

/// The project heading's own inputs. Expanded rows do not contribute their statuses.
public struct ProjectHeadingValue: Equatable, Sendable {
    public let project: Project
    public let isEmpty: Bool
    public let collapsed: Bool
    public let canMoveUp: Bool
    public let canMoveDown: Bool
    public let counts: [StatusCount]

    public init(_ section: ProjectSection) {
        project = section.project; isEmpty = section.isEmpty; collapsed = section.collapsed
        canMoveUp = section.canMoveUp; canMoveDown = section.canMoveDown
        counts = section.collapsed ? SidebarModel.statusCounts(tasks: section.tasks, terminals: section.terminals) : []
    }
}

/// OPERATOR's inputs, without the task rows its section contains. Open attention
/// still controls decoding; only a folded section draws or speaks the count.
public struct OperatorHeadingValue: Equatable, Sendable {
    public let header: BroadcastRow
    public let operatorLine: OperatorLine
    public let needsAttention: Bool
    public let folded: Bool
    public let attention: [StatusCount]
    public var id: UUID { header.id }

    public init(_ section: BroadcastSection) {
        header = section.header; operatorLine = section.operatorRow.line
        let counts = section.attention
        needsAttention = !counts.isEmpty; folded = section.folded
        attention = section.folded ? counts : []
    }
}

/// PROJECTS' fold and, while folded, its amber count. A worker's other status
/// changes neither and therefore does not redraw this heading.
public struct ProjectsHeadingValue: Equatable, Sendable {
    public let runID: UUID?
    public let folded: Bool
    public let attention: Int

    public init(sections: [ProjectSection] = [], broadcast: BroadcastSection? = nil) {
        runID = broadcast?.id; folded = broadcast.map { !$0.folded } ?? false
        attention = folded ? sections.reduce(0) { count, section in
            count + section.tasks.filter { $0.status == .needsInput }.count
                + section.terminals.filter { $0.status == .needsInput }.count
        } : 0
    }
}
