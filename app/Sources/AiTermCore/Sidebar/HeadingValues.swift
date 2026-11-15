import Foundation

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
