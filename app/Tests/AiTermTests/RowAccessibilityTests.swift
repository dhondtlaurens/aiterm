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

    /// Choosing the row is its reopen, so VoiceOver offers Archive and Remove alone, as the menu does.
    @Test func aTaskRowOffersRemoveAndNoReopen() {
        let open = TaskRowAccessibility(title: "Work", task: task(windowId: "w"), missing: false, failed: false, canChangeWorkspace: true)
        #expect(open.actions == [.archive, .remove])
        let closed = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: false, canChangeWorkspace: true)
        #expect(closed.actions == [.archive, .remove])
        let missing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: true, failed: false, canChangeWorkspace: true)
        #expect(missing.actions == [.archive, .remove])
    }

    /// The hint and the tooltip say what choosing the row does: a failed reopen is tried again, and an
    /// owed window coming back is focused like any other.
    @Test func aTaskRowsHintSaysWhatChoosingItDoes() {
        let failed = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: true, canChangeWorkspace: true)
        #expect(failed.hint == "Press Return to try again.")
        #expect(failed.help == "Couldn’t reopen its window. Click to try again.")
        let owed = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: false, canChangeWorkspace: true)
        #expect(owed.hint == "Press Return to focus the window.")
        #expect(owed.help == "")
        let missing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: true, failed: true, canChangeWorkspace: true)
        #expect(missing.hint == "Restore the worktree or use Remove Task.")
        #expect(missing.help == "Worktree missing. Restore it or use Remove Task.")
        let removing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: false, removing: true,
                                            canChangeWorkspace: true)
        #expect(removing.hint == "" && removing.help == "")
    }

    @Test func archiveIsOfferedBesideRemoveAndNamedWithoutAnEllipsis() {
        let a = TaskRowAccessibility(title: "Work", task: task(windowId: "w"), missing: false, failed: false, canChangeWorkspace: true)
        #expect(a.actions == [.archive, .remove])
        #expect(a.title(of: .archive) == "Archive")
    }

    /// A row whose Remove stopped after its worktree went waits on that retry, which the archiver
    /// refuses to cut short: its menu greys Archive, so VoiceOver offers Remove alone.
    @Test func aRowAwaitingItsRemovalsRetryOffersRemoveAlone() {
        let held = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: false, awaitsRetry: true,
                                        canChangeWorkspace: true)
        #expect(held.actions == [.remove])
    }

    /// Nothing is offered on a row being removed: its menu has Remove disabled.
    @Test func aTaskRowBeingRemovedOffersNothing() {
        let removing = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: false, removing: true,
                                            canChangeWorkspace: true)
        #expect(removing.actions.isEmpty)
    }

    /// While the workspace cannot change nothing is tried again: the row says only that it failed.
    @Test func aLockedWorkspacesFailedRowSaysNothingAboutTryingAgain() {
        let locked = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: true, canChangeWorkspace: false)
        #expect(locked.hint == "")
        #expect(locked.help == "Couldn’t reopen its window.")
        let open = TaskRowAccessibility(title: "Work", task: task(windowId: "w"), missing: false, failed: false, canChangeWorkspace: false)
        #expect(open.hint == "Press Return to focus the window.")
    }

    @Test func aLockedWorkspaceOffersNoTaskActions() {
        let locked = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: false, canChangeWorkspace: false)
        #expect(locked.actions.isEmpty)
        #expect(TaskRowAccessibility(title: "Work", task: nil, missing: false, failed: false, canChangeWorkspace: true).actions.isEmpty)
    }

    /// Remove names the row's kind, as its menu item does, without the menu's ellipsis.
    @Test func aRowsActionsAreItsMenuItemsTitles() {
        let task = TaskRowAccessibility(title: "Work", task: task(windowId: nil), missing: false, failed: false, canChangeWorkspace: true)
        #expect(task.actions.map(task.title(of:)) == ["Archive", "Remove Task"])
        var reviewItem = self.task(windowId: "w")
        reviewItem.kind = .review
        let review = TaskRowAccessibility(title: "Work", task: reviewItem, missing: false, failed: false, canChangeWorkspace: true)
        #expect(review.actions.map(review.title(of:)) == ["Archive", "Remove Review"])
        #expect(TerminalRowAccessibility.Action.remove.rawValue == "Remove Terminal")
        #expect(DividerRow.Action.allCases.map(\.rawValue) == ["Rename", "Move Up", "Move Down", "Remove Divider"])
    }

    @Test func aTaskRowReadsItsBranchOnlyWhenItHasOne() {
        #expect(TaskRowAccessibility(title: "Work", task: task(windowId: "w"), missing: false, failed: false, canChangeWorkspace: true).label
                == "Work, feat/work")
        #expect(TaskRowAccessibility(title: "Work", task: nil, missing: false, failed: false, canChangeWorkspace: true).label == "Work")
        #expect(TaskRowAccessibility(title: "Work", task: task(windowId: "w", branch: ""), missing: false,
                                     failed: false, canChangeWorkspace: true).label == "Work")
    }

    /// A terminal's window comes back by itself, so its row offers no Reopen Window, with one or without.
    @Test func aTerminalRowOffersRenameAndRemoveWithOrWithoutItsWindow() {
        let open = TerminalItem(id: UUID(), projectId: UUID(), name: "Shell", windowId: "w", createdAt: Date())
        var closed = open
        closed.windowId = nil
        #expect(TerminalRowAccessibility(terminal: open, canChangeWorkspace: true).actions == [.rename, .remove])
        #expect(TerminalRowAccessibility(terminal: closed, canChangeWorkspace: true).actions == [.rename, .remove])
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
