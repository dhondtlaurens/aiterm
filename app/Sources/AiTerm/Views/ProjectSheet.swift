import SwiftUI
import AiTermUI
import AiTermCore

struct ProjectSheet: View {
    @Bindable var model: ProjectSheetModel
    @State private var open = false
    @Environment(\.dismiss) private var dismiss
    private var providerName: String {
        switch model.preparation.project.provider {
        case .gitlab: "GitLab"
        case .github: "GitHub"
        case .git: "Git"
        case .none: "Folder"
        }
    }
    var body: some View {
        SheetLayout(title: model.title, height: .fitting(upTo: Sheet.height), onBackgroundTap: { open = false }) {
            if model.editing {
                HStack(spacing: Space.snug) {
                    Text(model.preparation.project.path).font(Typography.monoCode)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                        .help(model.preparation.project.path)
                    Text("· " + providerName).font(Typography.caption)
                    if let branch = model.preparation.defaultBranch { Text("· " + branch).font(Typography.monoCode) }
                }.foregroundStyle(Palette.muted)
            }
        } content: {
            FrontToBackStack(spacing: Space.block) {
                if !model.editing {
                    FormField("Folder") {
                        HStack(spacing: Space.gap) {
                            Input(placeholder: "Choose a project folder", text: $model.folder, monospaced: true)
                            Button("Choose…") { Task { await model.chooseFolder() } }.buttonStyle(PushButtonStyle(.secondary))
                        }
                        if model.validating { HelpText("Reading the folder…") }
                        else if let error = model.error { HelpText(error, tone: .warning) }
                        else { HelpText("\(providerName) · \(model.preparation.defaultBranch ?? "No default branch yet")") }
                    }
                }
                FormField("Jira projects (optional)") {
                    ChipsPicker(placeholder: "Add a Jira project", picks: model.linked, open: $open, matches: model.matches,
                                mark: { _ in .brand(Palette.jira) }, label: { $0.key + " · " + $0.name },
                                row: { PickerResultRow(mark: .brand(Palette.jira), key: $0.key, keyWidth: Size.pickerProjectKey, title: $0.name, detail: nil) },
                                onPick: { model.linked.append($0) }, onRemove: { item in model.linked.removeAll { $0.id == item.id } })
                    HelpText("New Task looks for tickets here, and signals start these projects’ tickets in \(model.preparation.project.name). Empty: New Task searches every Jira project.")
                    if model.loading { HelpText("Loading Jira projects…") }
                    else if let error = model.loadingError { HelpText(error, tone: .warning) }
                }
                if !model.editing, model.preparation.canImport {
                    DescriptionToggle(model.preparation.worktrees.count == 1 ? "Import its worktree as a task" : "Import its \(model.preparation.worktrees.count) worktrees as tasks", isOn: $model.importWorktrees,
                                      help: "They show under \(model.preparation.project.name). No agent starts.")
                }
                if let issue = model.preparation.importIssue { HelpText(issue.reason ?? issue.title, tone: .warning) }
                if model.editing, let error = model.error { HelpText(error, tone: .warning) }
                CreationClosingBlock { Text(model.closing).font(Typography.body).foregroundStyle(Palette.text) }
            }
        } footer: {
            SheetFooter(primary: model.editing ? "Save" : "Add Project", canSubmit: model.canSave,
                        closeList: { if open { open = false; return true }; return false },
                        cancel: { if !model.saving { dismiss.afterThisEvent() } },
                        submit: { Task { if await model.save() { dismiss() } } })
        }
        .interactiveDismissDisabled(model.saving)
        .task { await model.loadProjects() }
        .task(id: model.folder) {
            do { try await Task.sleep(for: .milliseconds(250)); await model.inspectFolder() } catch {}
        }
    }
}

#if DEBUG
extension ProjectSheet {
    func seeded(open: Bool) -> Self {
        var sheet = self; sheet._open = State(initialValue: open); return sheet
    }
}
#endif
