import SwiftUI
import AiTermUI
import AiTermCore

/// New Broadcast… (spec §3.1, the design page's `p-op-new` and `p-bs2-*`): Broadcast · Prompt · Agents · Task · Done on
/// the shipped `SheetStepper`, at `Sheet.height`, drawn from the creation frame's parts as New Task is (`CreationSteps.broadcast`): Continue on
/// ⌘↩ through step 4, Back from step 2, Cancel on step 1, and Start Broadcast on step 5, whose failure is the footer's
/// `Notice` (`CreationFooter`). Step 1 is an optional name, the Jira projects and the projects, which it needs one of;
/// Prompt is a `PromptStep` editor, whose `/` lists both agents' skills; then `AgentsStep`, `TaskStep` and `DoneStep`.
/// The `DestinationLine` ends steps 1 and 5. There is no command preview: the Operator chooses each task's agent from
/// the Agents rows.
struct NewBroadcastSheet: View {
    @Bindable var model: NewBroadcastModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int = 1
    @State private var jiraOpen = false
    @State private var projectsOpen = false
    private static let steps = CreationSteps.broadcast

    init(model: NewBroadcastModel) { _model = Bindable(wrappedValue: model) }

    /// Step 1's lists, in the order ⎋ closes them.
    private var pickers: [Binding<Bool>] { [$jiraOpen, $projectsOpen] }

    var body: some View {
        SteppedSheetFrame(title: NewBroadcastModel.title, height: Sheet.height, step: step, stepNames: NewBroadcastModel.stepNames,
                          onBackgroundTap: closeLists) {
            content
            if Self.steps.showsDestination(onStep: step) { DestinationLine(NewBroadcastModel.destination) }
        } footer: {
            // What Start waits for is said on every step, so it can be put right before the prompt is written.
            CreationFooter(step: step, steps: Self.steps, error: model.error, availableAgents: [],
                           createLabel: NewBroadcastModel.createLabel, creating: model.starting,
                           canAdvance: model.canAdvance(step: step), closeList: closeOpenList,
                           back: back, advance: advance, recover: {},
                           waiting: (BroadcastReadiness.title, model.notReadyLines))
        }
        // Both agents' skills, from the home and the picked projects: read again as the picks change.
        .task(id: model.projects.map(\.id)) { await model.loadCompletions() }
        .task(id: model.projects.map(\.id)) { await model.loadCodeHosts() }
        .task { await model.loadJiraProjects() }
        // The agents' cards and the delivery check's file, read for as long as the sheet is open.
        .task { await model.checkReadiness() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: broadcastStep
        // Claude's form for what `/` writes: the Operator reads every field, and a Codex task is told
        // of its skill in the brief the Operator writes for it.
        case 2: PromptStep(text: $model.prompt, agent: .claude, completions: model.completions, label: "Prompt", placeholder: nil,
                           help: NewBroadcastModel.promptHelp).id(2)
        case 3: AgentsStep(model: model)
        case 4: TaskStep(model: model).id(4)
        default: DoneStep(model: model).id(5)
        }
    }

    // -- step 1: broadcast ----------------------------------------------------------

    private var broadcastStep: some View {
        FrontToBackStack(spacing: Space.block) {
            FormField("Name") {
                Input(placeholder: NewBroadcastModel.namePlaceholder, text: $model.name)
                HelpText(NewBroadcastModel.nameHelp)
            }
            FormField("Jira projects") {
                ChipsPicker(placeholder: NewBroadcastModel.jiraProjectsPlaceholder, picks: model.jiraProjects,
                            open: $jiraOpen, matches: model.matchingJiraProjects(query:),
                            mark: { _ in .brand(Palette.jira) }, label: { "\($0.key) · \($0.name)" },
                            row: { PickerResultRow(mark: .brand(Palette.jira), key: $0.key, keyWidth: Size.pickerProjectKey, title: $0.name, detail: nil) },
                            onPick: { model.add(jiraProject: $0) }, onRemove: { model.remove(jiraProject: $0) })
                HelpText(NewBroadcastModel.jiraProjectsHelp)
                jiraStatus
            }
            FormField("Projects") {
                ChipsPicker(placeholder: NewBroadcastModel.projectsPlaceholder, picks: model.projects,
                            open: $projectsOpen, matches: model.matchingProjects(query:),
                            mark: { ProviderIcon.source(of: $0.provider) }, label: \.name,
                            row: { ProjectResultRow(project: $0) },
                            onPick: { model.add(project: $0) }, onRemove: { model.remove(project: $0) })
                HelpText(NewBroadcastModel.projectsHelp)
            }
        }
    }

    /// Loading, none found, or Jira not reached, under the help, as the Jira projects sheet says them.
    @ViewBuilder private var jiraStatus: some View {
        if let status = model.jiraStatus {
            if model.jiraLoad == .loading {
                HStack(spacing: Space.snug) {
                    ProgressView().controlSize(.small)
                    HelpText(status)
                }
            } else {
                HelpText(status)
            }
        }
    }

    // -- the footer's moves ---------------------------------------------------------

    private func closeLists() { for picker in pickers { picker.wrappedValue = false } }

    /// The list ⎋ closes, if one is open where it can be seen: step 1's pickers, or the completion
    /// popup on Prompt, Task and Done. The footer's hidden ⎋ button hears the key first.
    private func closeOpenList() -> Bool {
        if Self.steps.hasPrompt(onStep: step), model.completions.isOpen {
            model.completions.close()
            return true
        }
        guard step == 1, let open = pickers.first(where: { $0.wrappedValue }) else { return false }
        open.wrappedValue = false
        return true
    }

    private func back() { guard !model.starting else { return }; if step == 1 { dismiss.afterThisEvent() } else { step -= 1 } }

    /// Continue, or Start Broadcast on the last step; `canAdvance` gates both the button and ⌘↩.
    private func advance() {
        guard model.canAdvance(step: step) else { return }
        if Self.steps.creates(onStep: step) { start(); return }
        closeLists()
        model.completions.close()
        step += 1
    }

    /// Already past the button's event by the time it dismisses: the start is awaited first.
    private func start() { Task { if await model.start() != nil { dismiss() } } }
}

#if DEBUG
extension NewBroadcastSheet {
    /// The sheet already on `step`: what only clicks reach in the app, for the snapshots and tests.
    func seeded(step: Int) -> Self {
        var sheet = self
        sheet._step = State(initialValue: step)
        return sheet
    }
}
#endif
