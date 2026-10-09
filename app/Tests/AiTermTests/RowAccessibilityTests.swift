import Foundation
import Testing
import AiTermCore
@testable import AiTerm

/// VoiceOver offers a row's actions without a menu to grey them, so each one it offers must be one
/// the row's context menu would let the person choose now — and a row's label must read whole.
@Suite @MainActor struct RowAccessibilityTests {
    private func task(windowId: String?, branch: String = "feat/work") -> TaskItem {
        TaskItem(id: UUID(), projectId: UUID(), title: "Work", branch: branch, worktreePath: "/wt", baseBranch: "main",
                 jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false,
                 createdAt: Date(), windowId: windowId)
    }

    /// Choosing the row is its reopen, so VoiceOver offers Remove alone, as the menu does.
    @Test func aTaskRowOffersRemoveAndNoReopen() {
        let open = TaskRowAccessibility(title: "Work", task: task(windowId: "w"), missing: false, canChangeWorkspace: true)
        #expect(open.actions == [.remove])
        let closed = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, canChangeWorkspace: true)
        #expect(closed.actions == [.remove])
        let missing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: true, canChangeWorkspace: true)
        #expect(missing.actions == [.remove])
    }

    /// The hint and the tooltip say what choosing the row does: a closed window reopens.
    @Test func aTaskRowsHintSaysWhatChoosingItDoes() {
        let closed = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, canChangeWorkspace: true)
        #expect(closed.hint == "Press Return to reopen its window.")
        #expect(closed.help == "Window closed. Click to reopen it.")
        let open = TaskRowAccessibility(title: "Work", task: task(windowId: "w"), missing: false, canChangeWorkspace: true)
        #expect(open.hint == "Press Return to focus the window.")
        #expect(open.help == "")
        let missing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: true, canChangeWorkspace: true)
        #expect(missing.hint == "Restore the worktree or use Remove Task.")
        #expect(missing.help == "Worktree missing. Restore it or use Remove Task.")
        let removing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, removing: true,
                                            canChangeWorkspace: true)
        #expect(removing.hint == "" && removing.help == "")
    }

    /// Nothing is offered on a row being removed: its menu has Remove disabled.
    @Test func aTaskRowBeingRemovedOffersNothing() {
        let removing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, removing: true,
                                            canChangeWorkspace: true)
        #expect(removing.actions.isEmpty)
    }

    @Test func aLockedWorkspaceOffersNoTaskActions() {
        let locked = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, canChangeWorkspace: false)
        #expect(locked.actions.isEmpty)
        #expect(TaskRowAccessibility(title: "Work", task: nil, missing: false, canChangeWorkspace: true).actions.isEmpty)
    }

    /// Remove names the row's kind, as its menu item does, without the menu's ellipsis.
    @Test func aRowsActionsAreItsMenuItemsTitles() {
        let task = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, canChangeWorkspace: true)
        #expect(task.actions.map(task.title(of:)) == ["Remove Task"])
        var reviewItem = self.task(windowId: "w")
        reviewItem.kind = .review
        let review = TaskRowAccessibility(title: "Work", task: reviewItem, missing: false, canChangeWorkspace: true)
        #expect(review.actions.map(review.title(of:)) == ["Remove Review"])
        #expect(TerminalRowAccessibility.Action.remove.rawValue == "Remove Terminal")
        #expect(DividerRow.Action.allCases.map(\.rawValue) == ["Rename", "Move Up", "Move Down", "Remove Divider"])
    }

    @Test func aTaskRowReadsItsBranchOnlyWhenItHasOne() {
        #expect(TaskRowAccessibility(title: "Work", task: task(windowId: "w"), missing: false, canChangeWorkspace: true).label
                == "Work, feat/work")
        #expect(TaskRowAccessibility(title: "Work", task: nil, missing: false, canChangeWorkspace: true).label == "Work")
        #expect(TaskRowAccessibility(title: "Work", task: task(windowId: "w", branch: ""), missing: false,
                                     canChangeWorkspace: true).label == "Work")
    }

    @Test func aTerminalRowOffersReopenWhenItsMenuDoes() {
        let open = TerminalItem(id: UUID(), projectId: UUID(), name: "Shell", windowId: "w", createdAt: Date())
        var closed = open
        closed.windowId = nil
        #expect(TerminalRowAccessibility(terminal: open, canChangeWorkspace: true).actions == [.rename, .remove])
        #expect(TerminalRowAccessibility(terminal: closed, canChangeWorkspace: true).actions == [.rename, .reopenWindow, .remove])
        #expect(TerminalRowAccessibility(terminal: closed, canChangeWorkspace: false).actions.isEmpty)
    }

    /// The header's click, VoiceOver default action and button trait follow one rule.
    @Test func aProjectHeaderCollapsesOnlyWithRowsInAnUnlockedWorkspace() {
        func section(withTerminal: Bool) -> ProjectSection? {
            var state = AppState.empty
            let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
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
        #expect(ProjectHeaderRow.collapses(full, canChangeWorkspace: true))
        #expect(!ProjectHeaderRow.collapses(full, canChangeWorkspace: false))
        #expect(!ProjectHeaderRow.collapses(empty, canChangeWorkspace: true))
    }

    @Test func aDividerOffersOnlyWhatItsMenuHasEnabled() {
        #expect(DividerRow.actions(enabled: true, canMove: { _ in true }) == [.rename, .moveUp, .moveDown, .delete])
        #expect(DividerRow.actions(enabled: true, canMove: { $0 == .down }) == [.rename, .moveDown, .delete],
                "the first item has no Move up")
        #expect(DividerRow.actions(enabled: false, canMove: { _ in false }).isEmpty)
    }
}
