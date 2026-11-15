import SwiftUI
import AiTermUI
import AiTermCore

/// Shared creation chrome, completed-step navigation, closing summary, footer and initial loads.
/// Each sheet owns its decisions and picker state; this frame owns the common keyboard routing.
struct CreationSheet<Kind: CreationKind, Content: View>: View {
    let model: CreationModel<Kind>
    @Binding var step: Int
    let title: String
    let stepNames: [String]
    /// Where the window opens, drawn last on the first step and the last; `nil` while it isn't known
    /// yet. The agent's step never draws one, so the sheet need not work it out there.
    let destination: Destination?
    let createLabel: String
    let canAdvance: Bool
    let pickers: [Binding<Bool>]
    let content: Content
    @Environment(\.dismiss) private var dismiss

    init(model: CreationModel<Kind>, step: Binding<Int>, title: String, stepNames: [String],
         destination: Destination?, createLabel: String, canAdvance: Bool, pickers: [Binding<Bool>],
         @ViewBuilder content: () -> Content) {
        self.model = model; self._step = step; self.title = title; self.stepNames = stepNames
        self.destination = destination; self.createLabel = createLabel; self.canAdvance = canAdvance
        self.pickers = pickers; self.content = content()
    }

    var body: some View {
        SteppedSheetFrame(title: title, height: Sheet.creationHeight, step: step, stepNames: stepNames,
                          onBackgroundTap: { for picker in pickers { picker.wrappedValue = false } }, onNavigate: navigate) {
            content
            if Kind.steps.creates(onStep: step) {
                CreationClosingBlock {
                    if let destination { DestinationLine(destination) }
                    Text("Runs \(model.draft.agent.displayName) with \(model.models.first { $0.id == model.draft.model }?.label ?? model.draft.model).")
                        .font(Typography.body).foregroundStyle(Palette.text)
                }
            }
        } footer: {
            CreationFooter(step: step, steps: Kind.steps, error: model.error, availableAgents: model.availableAgents, createLabel: createLabel,
                           creating: model.creating, canAdvance: canAdvance && model.canChangeWorkspace(),
                           closeList: closeOpenList, back: back, advance: advance, recover: recover,
                           fix: model.fixSession, canApply: model.canChangeWorkspace(), applyFix: model.applyFix)
        }
        // A fix being applied is never left half-made: ⎋ does nothing then (the footer's Cancel is
        // the fix's, which ignores it), and neither does any other way of closing the sheet.
        .interactiveDismissDisabled(model.fixSession?.state == .applying)
        // A create run by a landed fix closes the sheet as its own create does.
        .onChange(of: model.createdAfterFix) { _, created in if created { dismiss() } }
        .task { await model.search(text: "") }
        .task(id: model.draft.agent) { await model.loadAgentCatalogue() }
        .task { await model.loadBranches() }
        .task { await model.loadWorktreeIncludes() }
        .task { await model.loadProjectFiles() }
        // Closed while an agent looks, the Look stops and its clone goes; a proposal left up is declined.
        .onDisappear { model.cancelSearch(); model.fixSession?.cancel() }
    }

    /// The list ⎋ closes, if one is open where it can be seen: the pickers on step 1, the prompt's
    /// completion popup on the prompt's step. A picker list left open on a later step is out of sight, so the
    /// key goes straight to Back there. The popup is the footer's to close, not the text view's:
    /// the footer's hidden ⎋ button hears the key first.
    private func closeOpenList() -> Bool {
        if Kind.steps.hasPrompt(onStep: step), model.completions.isOpen {
            model.completions.close()
            return true
        }
        guard step <= 2, let open = pickers.first(where: { $0.wrappedValue }) else { return false }
        open.wrappedValue = false
        return true
    }

    private func navigate(_ target: Int) {
        guard !model.creating, SheetStepper.canNavigate(from: step, to: target, count: Kind.steps.count) else { return }
        for picker in pickers { picker.wrappedValue = false }
        model.completions.close(); step = target
    }

    private func back() { guard !model.creating else { return }; if step == 1 { dismiss.afterThisEvent() } else { step -= 1 } }

    /// What the primary button does, named once: the button and the ⌘↩ shortcut both call it, and
    /// `canAdvance` gates both, so the keycaps never advertise a key that does nothing.
    /// Leaving step 1 closes its lists, so going back to it finds them as a fresh sheet does.
    /// While a fix's proposal is up it is Apply (the footer routes its button there too).
    private func advance() {
        // A backstop only: the footer owns the routing, and sends a proposal's ⌘↩ to Apply itself.
        if model.primaryAction() == .applyFix { model.applyFix(); return }
        if Kind.steps.creates(onStep: step) { create(); return }
        for picker in pickers { picker.wrappedValue = false }
        step += 1
    }

    /// Already past the button's event by the time it dismisses: the create is awaited first.
    private func create() { Task { if await model.create() { dismiss() } } }

    /// The footer's fix for the last failure, and the create after it, dismissing as `create` does.
    private func recover() { Task { if await model.recoverAndCreate() { dismiss() } } }
}
