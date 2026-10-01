import SwiftUI
import AiTermUI
import AiTermCore

/// One field: the name the sidebar row carries. A terminal needs nothing else — it opens in the
/// project folder and starts no agent, unlike `NewTaskSheet`'s three steps. Its iTerm2 tabs are
/// titled with their branch, as every AiTerm window's are, not with this name.
///
/// The sheet itself is `NameSheet`; this type is the New Terminal flow's copy and its destination.
struct NewTerminalSheet: View {
    let canCreate: Bool
    let createTerminal: (String) -> Void
    let project: Project
    let suggestedName: String
    /// The checked-out branch of the project, for the destination line. Terminals run in the
    /// repository itself, not in a worktree, so there is nothing to derive it from but the repo.
    let branch: String

    /// Suggestion and branch are computed by `AppController.presentNewTerminal(project:)` and
    /// passed in: SwiftUI re-creates a sheet's root view on every state change of the presenting
    /// view, so a name computed here would jump back to the suggestion mid-typing and the branch
    /// would cost a `git symbolic-ref` on every one of those rebuilds.
    init(project: Project, suggestedName: String, branch: String, canCreate: Bool, createTerminal: @escaping (String) -> Void) {
        self.canCreate = canCreate; self.createTerminal = createTerminal
        self.project = project; self.suggestedName = suggestedName; self.branch = branch
    }

    var body: some View {
        NameSheet(title: "New terminal in \(project.name)",
                  subtitle: "Opens a shell in the project folder.",
                  fieldLabel: "Terminal name",
                  placeholder: TerminalItem.defaultName,
                  destination: .projectFolder(project, branch: branch),
                  confirmLabel: "Create Terminal",
                  initialName: suggestedName,
                  canSubmit: canCreate,
                  // An emptied field is not an error: `newTerminal(project:name:)` falls back to
                  // the same suggestion this sheet opened with.
                  submit: createTerminal)
    }
}
