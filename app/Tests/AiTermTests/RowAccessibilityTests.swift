import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// VoiceOver offers a row's actions without a menu to grey them, so each one it offers must be one
/// the row's context menu would let the person choose now — and a row's label must read whole.
@Suite @MainActor struct RowAccessibilityTests {
    /// The row a task with or without a window draws: its title, saved branch and kind.
    private func row(windowId: String?, branch: String = "feat/work", kindName: String = "Task") -> TaskRow {
        TaskRow(id: UUID(), title: "Work", jiraKey: nil, jiraUrl: nil, mr: nil, branch: .none, avatars: AvatarGroup(marks: [], overflow: 0),
                status: .idle, kindName: kindName, worktreePath: "/wt", savedBranch: branch, windowOpen: windowId != nil)
    }

    /// Choosing the row is its reopen, so VoiceOver offers Archive and Remove alone, as the menu does.
    @Test func aTaskRowOffersRemoveAndNoReopen() {
        let open = TaskRowAccessibility(row: row(windowId: "w"), missing: false, canChangeWorkspace: true)
        #expect(open.actions == [.archive, .remove])
        let closed = TaskRowAccessibility(row: row(windowId: nil), missing: false, canChangeWorkspace: true)
        #expect(closed.actions == [.archive, .remove])
        let missing = TaskRowAccessibility(row: row(windowId: nil), missing: true, canChangeWorkspace: true)
        #expect(missing.actions == [.archive, .remove])
    }

    /// The hint and the tooltip say what choosing the row does: a row without a window opens one, and
    /// a row with one focuses it.
    @Test func aTaskRowsHintSaysWhatChoosingItDoes() {
        let closed = TaskRowAccessibility(row: row(windowId: nil), missing: false, canChangeWorkspace: true)
        #expect(closed.hint == "Press Return to open its window.")
        #expect(closed.help == "")
        let open = TaskRowAccessibility(row: row(windowId: "w"), missing: false, canChangeWorkspace: true)
        #expect(open.hint == "Press Return to focus the window.")
        #expect(open.help == "")
        let missing = TaskRowAccessibility(row: row(windowId: nil), missing: true, canChangeWorkspace: true)
        #expect(missing.hint == "Restore the worktree or use Remove Task.")
        #expect(missing.help == "Worktree missing. Restore it or use Remove Task.")
        let removing = TaskRowAccessibility(row: row(windowId: nil), missing: false, removing: true,
                                            canChangeWorkspace: true)
        #expect(removing.hint == "" && removing.help == "")
    }

    @Test func archiveIsOfferedBesideRemoveAndNamedWithoutAnEllipsis() {
        let a = TaskRowAccessibility(row: row(windowId: "w"), missing: false, canChangeWorkspace: true)
        #expect(a.actions == [.archive, .remove])
        #expect(a.title(of: .archive) == "Archive Task")
    }

    /// Nothing is offered on a row being removed: its menu has Remove disabled.
    @Test func aTaskRowBeingRemovedOffersNothing() {
        let removing = TaskRowAccessibility(row: row(windowId: nil), missing: false, removing: true,
                                            canChangeWorkspace: true)
        #expect(removing.actions.isEmpty)
    }

    /// While the workspace cannot change a row with a window still focuses it.
    @Test func aLockedWorkspacesRowWithAWindowStillSaysItFocusesIt() {
        let open = TaskRowAccessibility(row: row(windowId: "w"), missing: false, canChangeWorkspace: false)
        #expect(open.hint == "Press Return to focus the window.")
    }

    @Test func aLockedWorkspaceOffersNoTaskActions() {
        let locked = TaskRowAccessibility(row: row(windowId: nil), missing: false, canChangeWorkspace: false)
        #expect(locked.actions.isEmpty)
    }

    /// Remove names the row's kind, as its menu item does, without the menu's ellipsis.
    @Test func aRowsActionsAreItsMenuItemsTitles() {
        let task = TaskRowAccessibility(row: row(windowId: nil), missing: false, canChangeWorkspace: true)
        #expect(task.actions.map(task.title(of:)) == ["Archive Task", "Remove Task"])
        let review = TaskRowAccessibility(row: self.row(windowId: "w", kindName: "Review"), missing: false, canChangeWorkspace: true)
        #expect(review.actions.map(review.title(of:)) == ["Archive Review", "Remove Review"])
        #expect(TerminalRowAccessibility.Action.remove.rawValue == "Remove Terminal")
        #expect(DividerRow.Action.allCases.map(\.rawValue) == ["Rename", "Move Up", "Move Down", "Remove Divider"])
    }

    @Test func aTaskRowReadsItsBranchOnlyWhenItHasOne() {
        #expect(TaskRowAccessibility(row: row(windowId: "w"), missing: false, canChangeWorkspace: true).label
                == "Work, feat/work")
        #expect(TaskRowAccessibility(row: row(windowId: "w", branch: ""), missing: false,
                                     canChangeWorkspace: true).label == "Work")
    }

    /// A terminal's window comes back by itself, so its row offers no Reopen Window, with one or without.
    @Test func aTerminalRowOffersRenameAndRemoveWithOrWithoutItsWindow() {
        #expect(TerminalRowAccessibility(canChangeWorkspace: true).actions == [.rename, .remove])
        #expect(TerminalRowAccessibility(canChangeWorkspace: false).actions.isEmpty)
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

    @Test func aDividerOffersOnlyWhatItsMenuHasEnabled() {
        #expect(DividerRow.actions(enabled: true, canMove: { _ in true }) == [.rename, .moveUp, .moveDown, .delete])
        #expect(DividerRow.actions(enabled: true, canMove: { $0 == .down }) == [.rename, .moveDown, .delete],
                "the first item has no Move up")
        #expect(DividerRow.actions(enabled: false, canMove: { _ in false }).isEmpty)
    }
}
