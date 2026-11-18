import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// VoiceOver offers a row's actions without a menu to grey them, so each one it offers must be one
/// the row's context menu would let the person choose now, and a row's label must read whole.
@Suite @MainActor struct RowAccessibilityTests {
    /// The row a task with or without a window draws: its title, saved branch and kind.
    private func row(windowId: String?, branch: String = "feat/work", kindName: String = "Task") -> TaskRow {
        TaskRow(id: UUID(), title: "Work", jiraKey: nil, jiraUrl: nil, mr: nil, branch: .none, avatars: AvatarGroup(marks: [], overflow: 0),
                status: .idle, kindName: kindName, worktreePath: "/wt", savedBranch: branch, windowOpen: windowId != nil)
    }

    /// The hint and the tooltip say what choosing the row does: a row without a window opens one, and
    /// a row with one focuses it.
    @Test func aTaskRowsHintSaysWhatChoosingItDoes() {
        let closed = TaskRowAccessibility(row: row(windowId: nil), missing: false)
        #expect(closed.hint == "Press Return to open its window.")
        #expect(closed.help == "")
        let open = TaskRowAccessibility(row: row(windowId: "w"), missing: false)
        #expect(open.hint == "Press Return to focus the window.")
        #expect(open.help == "")
        let missing = TaskRowAccessibility(row: row(windowId: nil), missing: true)
        #expect(missing.hint == "Restore the worktree or use Remove Task.")
        #expect(missing.help == "Worktree missing. Restore it or use Remove Task.")
        let removing = TaskRowAccessibility(row: row(windowId: nil), missing: false, removing: true)
        #expect(removing.hint == "" && removing.help == "")
    }


    /// While the workspace cannot change a row with a window still focuses it.
    @Test func aLockedWorkspacesRowWithAWindowStillSaysItFocusesIt() {
        let open = TaskRowAccessibility(row: row(windowId: "w"), missing: false)
        #expect(open.hint == "Press Return to focus the window.")
    }


    @Test func aTaskRowReadsItsBranchOnlyWhenItHasOne() {
        #expect(TaskRowAccessibility(row: row(windowId: "w"), missing: false).label
                == "Work, feat/work")
        #expect(TaskRowAccessibility(row: row(windowId: "w", branch: ""), missing: false).label == "Work")
    }

    /// The header's click, VoiceOver default action and button trait follow one rule.
    @Test func aProjectHeaderCollapsesOnlyWithRowsInAnUnlockedWorkspace() throws {
        func section(withTerminal: Bool) -> ProjectSection? {
            var state = AppState.empty
            let project = Project.make(name: "Repo", path: "/repo", addedAt: Date())
            state.append(project: project)
            if withTerminal {
                state.terminals = [TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w", createdAt: Date())]
            }
            let entries = SidebarModel.entries(state: state, sessions: [], branchByCwd: [:], projectBranch: [:], diffByTask: [:])
            guard case .project(let section)? = entries.first else { return nil }
            return section
        }
        guard let full = section(withTerminal: true), let empty = section(withTerminal: false) else {
            Issue.record("expected project sections"); return
        }
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        let fullRow = HeadingRow(value: HeadingValue(full), controller: controller)
        let emptyRow = HeadingRow(value: HeadingValue(empty), controller: controller)
        #expect(!fullRow.collapses, "an unloaded workspace is locked")
        #expect(!emptyRow.collapses)
        try controller.workspace.load()
        #expect(fullRow.collapses)
        #expect(!emptyRow.collapses)
    }

    private var openTitles: [String] {
        ["Open in Finder"] + (ExternalApps.vscode == nil ? [] : ["Open in VS Code"])
    }

    private func expectCommands(_ groups: [[RowCommand]], titles: [[String]], disabled: [String] = [],
                                destructive: [String] = []) {
        #expect(groups.map { $0.map(\.title) } == titles)
        for command in groups.flatMap({ $0 }) {
            #expect(command.enabled == !disabled.contains(command.title))
            #expect(command.role == (destructive.contains(command.title) ? .destructive : .normal))
        }
        let spoken = titles.flatMap { $0 }.filter { !disabled.contains($0) }.map {
            $0.hasSuffix("…") ? String($0.dropLast()) : $0
        }
        #expect(RowCommand.accessible(in: groups).map(\.accessibilityTitle) == spoken)
    }

    @Test func taskCommandsKeepTheirGroupsKindsAndEnabledActions() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        for kind in ["Task", "Review"] {
            for driven in [false, true] {
                for window in [nil, "w"] as [String?] {
                    var value = row(windowId: window, kindName: kind)
                    value.underOperator = driven
                    value.jiraUrl = "https://jira.example/browse/TEST-1"
                    let view = TaskRowView(row: value, controller: controller)
                    let titles = (driven ? [["Take Over"]] : []) + [["Rename…"], openTitles + ["Open in Jira"],
                        ["Archive \(kind)", "Remove \(kind)…"]]
                    expectCommands(view.commands(removing: false), titles: titles, destructive: ["Remove \(kind)…"])
                    expectCommands(view.commands(removing: true), titles: titles,
                        disabled: ["Take Over", "Rename…", "Archive \(kind)", "Remove \(kind)…"],
                        destructive: ["Remove \(kind)…"])
                }
            }
        }
        var issue = row(windowId: nil)
        issue.ticketIsGitLabIssue = true
        issue.jiraUrl = "https://gitlab.example/repo/-/issues/1"
        expectCommands(TaskRowView(row: issue, controller: controller).commands(removing: false),
            titles: [["Rename…"], openTitles + ["Open in GitLab"], ["Archive Task", "Remove Task…"]],
            destructive: ["Remove Task…"])
    }

    @Test func lockedTaskAndTerminalKeepOpenCommands() {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        var value = row(windowId: nil)
        value.underOperator = true
        expectCommands(TaskRowView(row: value, controller: controller).commands(removing: false),
            titles: [["Take Over"], ["Rename…"], openTitles, ["Archive Task", "Remove Task…"]],
            disabled: ["Take Over", "Rename…", "Archive Task", "Remove Task…"], destructive: ["Remove Task…"])
        expectCommands(terminalView(controller).commands(), titles: [["Rename…"], openTitles, ["Remove Terminal"]],
            disabled: ["Rename…", "Remove Terminal"], destructive: ["Remove Terminal"])
    }

    private func terminalView(_ controller: AppController, window: String? = nil) -> TerminalRowView {
        let project = Project.make()
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: window, createdAt: Date())
        let value = TerminalRow(id: terminal.id, name: terminal.name, branch: .none,
                                avatars: AvatarGroup(marks: [], overflow: 0), status: .idle)
        return TerminalRowView(row: value, terminal: terminal, project: project, controller: controller)
    }

    @Test func terminalCommandsDoNotDependOnItsWindow() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        try controller.workspace.load()
        for window in [nil, "w"] as [String?] {
            expectCommands(terminalView(controller, window: window).commands(),
                titles: [["Rename…"], openTitles, ["Remove Terminal"]], destructive: ["Remove Terminal"])
        }
    }

    @Test func dividerCommandsAtBothEndsAndWhileLocked() {
        for enabled in [false, true] {
            for first in [false, true] {
                let entry = DividerEntry(divider: SidebarDivider(id: UUID(), name: "Work"),
                                         canMoveUp: !first, canMoveDown: first)
                let view = DividerRow(entry: entry, enabled: enabled, rename: {}, move: { _ in }, delete: {})
                expectCommands(view.commands(), titles: [["Rename…"], ["Move Up", "Move Down"], ["Remove Divider"]],
                    disabled: enabled ? [first ? "Move Up" : "Move Down"] : ["Rename…", "Move Up", "Move Down", "Remove Divider"],
                    destructive: ["Remove Divider"])
            }
        }
    }

    @Test func projectCommandsShareTheirAddGroupAndKeepPullAndEdges() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        for unlocked in [false, true] {
            if unlocked { try controller.workspace.load() }
            for provider in [Provider.gitlab, .github, .none] {
                let project = Project.make(provider: provider)
                let value = HeadingValue(ProjectSection(project: project, tasks: [], terminals: [], canMoveUp: false, canMoveDown: true))
                let view = HeadingRow(value: value, controller: controller)
                let git = provider != .none
                let titles = [["New Task…", "New Review…", "New Terminal…"], openTitles, ["Edit Project…"]]
                    + (git ? [["Pull Default Branch"]] : []) + [["Move Up", "Move Down"], ["Remove Project…"]]
                let disabled = unlocked ? ["Move Up"] + (git ? [] : ["New Task…", "New Review…"])
                    : ["New Task…", "New Review…", "New Terminal…", "Edit Project…", "Move Up", "Move Down", "Remove Project…"]
                expectCommands(view.commands(), titles: titles, disabled: disabled, destructive: ["Remove Project…"])
            }
        }
    }

    @Test func signalCommandsSwitchAndOmitRemovedSignals() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        for unlocked in [false, true] {
            if unlocked { try controller.workspace.load() }
            for enabled in [false, true] {
                var signal = Signal.make()
                signal.enabled = enabled
                let value = HeadingValue(SignalSection(signal: signal, tasks: []))
                let view = HeadingRow(value: value, controller: controller)
                let toggle = enabled ? "Switch Off" : "Switch On"
                expectCommands(view.commands(), titles: [["Edit Signal…", toggle], ["Remove Signal…"]],
                    disabled: unlocked ? [] : ["Edit Signal…", toggle, "Remove Signal…"], destructive: ["Remove Signal…"])
                var removed = value
                removed.kind = .signal(source: signal.start.source, removed: true, paused: false)
                expectCommands(HeadingRow(value: removed, controller: controller).commands(), titles: [])
            }
        }
    }

    @Test func operatorHeadingOwnsPauseEvenWithoutSignalsOrChatAndAddsOnlySignals() throws {
        let controller = AppController(preferences: .scratch())
        defer { controller.shutdown() }
        for unlocked in [false, true] {
            if unlocked { try controller.workspace.load() }
            for paused in [false, true] {
                let title = paused ? "Resume Operator" : "Pause Operator"
                expectCommands(SectionHeading.commands(kind: .operator, paused: paused, controller: controller),
                    titles: [[title]], disabled: unlocked ? [] : [title])
            }
            expectCommands(SectionHeading(controller: controller, kind: .operator).addCommands(),
                titles: [["New Signal…"]], disabled: unlocked ? [] : ["New Signal…"])
            expectCommands(SectionHeading.commands(kind: .projects, paused: false, controller: controller), titles: [])
        }
        expectCommands(SignalOperatorRow.commands, titles: [])
    }
}
