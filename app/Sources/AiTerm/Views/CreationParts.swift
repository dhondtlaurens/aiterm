import SwiftUI
import AiTermUI
import AiTermCore

/// What New Task and New Review put in their `SteppedSheet`'s closing block: where the window opens,
/// when that is known, and the agent and model that run in it.
struct CreationSummary<Kind: CreationKind>: View {
    let model: CreationModel<Kind>
    let destination: Destination?

    var body: some View {
        if let destination { DestinationLine(destination) }
        Text("Runs \(model.draft.agent.displayName) with \(model.models.first { $0.id == model.draft.model }?.label ?? model.draft.model).")
            .font(Typography.body).foregroundStyle(Palette.text)
    }
}

/// New Task’s and New Review’s footer notices: the last failure, with its fix under it when it has one.
///
/// A failure is a `Notice` with no actions — the footer's buttons are its actions — and shows its
/// reason, never the head of git's output: that is the command line and git's narration. The reason is
/// git's failure lines as one sentence (`GitError.sentence`), or any other error's own, as the banner
/// has it — short by construction, so it is never cut, and the Notice's title alone; git's whole
/// output is the tooltip.
struct CreationNotices: View {
    let error: CreationFailure?
    let creating: Bool
    /// The failure's fix, then the create it stopped: whether that create went through.
    let recoverAndCreate: () async -> Bool

    var body: some View {
        if let error {
            Notice(title: error.reason, help: error.detail)
            CreationRecoveryButton(recovery: error.recovery, creating: creating, recoverAndCreate: recoverAndCreate)
        }
    }
}

/// A failure's fix (`CreationFailure.recovery`), under the failure's notice: a secondary push button with
/// no key, since it moves a branch — ⌘↩ stays the create. It runs the fix and the create it stopped, and
/// closes the sheet when that create went through.
struct CreationRecoveryButton: View {
    let recovery: CreationFailure.Recovery?
    let creating: Bool
    let recoverAndCreate: () async -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let recovery {
            Button(recovery.title) { Task { if await recoverAndCreate() { dismiss() } } }
                .help(recovery.help).disabled(creating).buttonStyle(.push(.secondary))
        }
    }
}

extension View {
    /// What New Task and New Review load as they open: the picker's first results, the agent's
    /// catalogue (again when the agent changes), the branches, the worktree's copied files and the
    /// project's files for the prompt's completions. The search stops when the sheet goes.
    func creationLoads<Kind: CreationKind>(_ model: CreationModel<Kind>) -> some View {
        modifier(CreationLoads(model: model))
    }
}

private struct CreationLoads<Kind: CreationKind>: ViewModifier {
    let model: CreationModel<Kind>

    func body(content: Content) -> some View {
        content
            .task { await model.search(text: "") }
            .task(id: model.draft.agent) { await model.loadAgentCatalogue() }
            .task { await model.loadBranches() }
            .task { await model.loadWorktreeIncludes() }
            .task { await model.loadProjectFiles() }
            .onDisappear { model.cancelSearch() }
    }
}
