import SwiftUI

/// One command shared by a row's menu and its spoken actions.
struct RowCommand {
    enum Role { case normal, destructive }
    let title: String
    var role: Role = .normal
    var enabled = true
    let action: () -> Void

    var accessibilityTitle: String { title.hasSuffix("…") ? String(title.dropLast()) : title }

    /// Whether a menu of `groups` has anything to choose: without, its gear greys.
    static func anyEnabled(in groups: [[Self]]) -> Bool { groups.contains { $0.contains(where: \.enabled) } }

    static func accessible(in groups: [[Self]]) -> [Self] {
        groups.flatMap { $0 }.filter(\.enabled)
    }

    static func open(path: String) -> [Self] {
        var commands = [Self(title: "Open in Finder") { ExternalApps.openInFinder(path: path) }]
        if ExternalApps.vscode != nil {
            commands.append(Self(title: "Open in VS Code") { ExternalApps.openInVSCode(path: path) })
        }
        return commands
    }
}

/// Empty groups contribute neither buttons nor separators.
struct RowCommandMenu: View {
    let groups: [[RowCommand]]

    var body: some View {
        let groups = groups.filter { !$0.isEmpty }
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index].indices, id: \.self) { item in
                let command = groups[index][item]
                Button(command.title, role: command.role == .destructive ? .destructive : nil, action: command.action)
                    .disabled(!command.enabled)
            }
        }
    }
}

/// VoiceOver cannot grey actions, so it offers only enabled commands, in menu order.
struct RowCommandActions: ViewModifier {
    let groups: [[RowCommand]]

    func body(content: Content) -> some View {
        let commands = RowCommand.accessible(in: groups)
        content.accessibilityActions {
            ForEach(commands.indices, id: \.self) { index in
                let command = commands[index]
                Button(command.accessibilityTitle, action: command.action)
            }
        }
    }
}

/// A heading with no commands has no context menu.
struct RowCommandContextMenu: ViewModifier {
    let groups: [[RowCommand]]

    func body(content: Content) -> some View {
        if groups.contains(where: { !$0.isEmpty }) {
            content.contextMenu { RowCommandMenu(groups: groups) }
        } else {
            content
        }
    }
}
