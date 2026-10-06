import SwiftUI
import AiTermUI
import AiTermCore

/// What New Task and New Review share around their steps: the step bar, the command preview under
/// every step past the first, the destination line that ends steps 1 and 3, the footer and its
/// keys, and the loads the sheet starts when it appears. Each sheet keeps what is its own — its
/// first step, where it opens, what its create button says, when it may advance, and its pickers —
/// and hands those in as values.
///
/// `pickers` are the sheet's open-list flags in the order ⎋ closes them: ⎋ belongs to an open list
/// first — in every other app that list is a window of its own, and closing the whole sheet is not
/// what the key means there — and a click on the sheet's background closes them all.
struct CreationSheet<Kind: CreationKind, Content: View>: View {
    let model: CreationModel<Kind>
    @Binding var step: Int
    let title: String
    let stepNames: [String]
    /// Where the window opens, drawn last on steps 1 and 3; `nil` while it isn't known yet. Step 2
    /// never draws one, so the sheet need not work it out there.
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
        SheetLayout(title: title, height: Sheet.height,
                    onBackgroundTap: { for picker in pickers { picker.wrappedValue = false } }) {
            StepBar(step: step, names: stepNames)
        } content: {
            // Front to back: the prompt step's completion popup hangs out of the step and over the
            // command preview below it.
            FrontToBackStack(spacing: Space.block) {
                content
                if step > 1 { CommandPreview(model: model) }
                if Destination.isShown(onStep: step), let destination { DestinationLine(destination) }
            }
        } footer: {
            CreationFooter(step: step, error: model.error, availableAgents: model.availableAgents, createLabel: createLabel,
                           creating: model.creating, canAdvance: canAdvance && model.canChangeWorkspace(),
                           closeList: closeOpenList, back: back, advance: advance)
        }
        .task { await model.search(text: "") }
        .task(id: model.draft.agent) { await model.loadAgentCatalogue() }
        .task { await model.loadBranches() }
        .onDisappear { model.cancelSearch() }
    }

    /// The list ⎋ closes, if one is open where it can be seen: the pickers on step 1, the prompt's
    /// completion popup on step 3. A picker list left open on a later step is out of sight, so the
    /// key goes straight to Back there. The popup is the footer's to close, not the text view's:
    /// the footer's hidden ⎋ button hears the key first.
    private func closeOpenList() -> Bool {
        if step == 3, model.completions.isOpen {
            model.completions.close()
            return true
        }
        guard step == 1, let open = pickers.first(where: { $0.wrappedValue }) else { return false }
        open.wrappedValue = false
        return true
    }

    private func back() { guard !model.creating else { return }; if step == 1 { dismiss.afterThisEvent() } else { step -= 1 } }

    /// What the primary button does, named once: the button and the ⌘↩ shortcut both call it, and
    /// `canAdvance` gates both, so the keycaps never advertise a key that does nothing.
    /// Leaving step 1 closes its lists, so going back to it finds them as a fresh sheet does.
    private func advance() {
        if step == 3 { create(); return }
        for picker in pickers { picker.wrappedValue = false }
        step += 1
    }

    /// Already past the button's event by the time it dismisses: the create is awaited first.
    private func create() { Task { if await model.create() { dismiss() } } }
}

/// The command preview under steps 2 and 3: the one part of the frame that reads the prompt, so a
/// keystroke in the prompt redraws this line and not the sheet around it.
struct CommandPreview<Kind: CreationKind>: View {
    let model: CreationModel<Kind>
    var body: some View { CommandBlock(caption: "Command", command: model.previewCommand) }
}
