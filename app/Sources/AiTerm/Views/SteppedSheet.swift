import SwiftUI
import AiTermUI

/// One step of a `SteppedSheet`, as its sheet sees it this render.
struct Step {
    /// The stepper's label for it.
    let name: String
    /// Whether Continue, or the create button on the last step, is enabled.
    let canAdvance: Bool
    /// Closes the step's open list or popup, one per call, and says whether there was one.
    var closeList: () -> Bool = { false }
}

/// The stepped sheets' frame — New Task, New Review and New Signal — and the one place their navigation,
/// keys and dismissal live. Each sheet hands it its steps, its height, its create action and what the
/// current step draws.
///
/// The title row carries the `SheetStepper`; the content is the current step, `FrontToBackStack`ed so an
/// earlier field's dropdown lies over what follows it, and on the last step a `CreationClosingBlock` of
/// `closing` ends it. Every step is `height` tall, so the sheet does not jump from one to the next.
///
/// Keys: ⎋ closes the current step's open list, and with none open cancels (never while a create runs);
/// ⌘↩ is the primary button's (Continue, then the create label) while the step can advance; ⌘1…⌘n
/// go back to a completed step. A plain ↩ stays with the focused control. Leaving a step closes its
/// lists, as a click on the sheet's background does, so a step is always found as a fresh sheet has it.
struct SteppedSheet<Content: View, Notices: View, Closing: View>: View {
    let title: String
    let height: CGFloat
    let steps: [Step]
    @Binding var step: Int
    let createLabel: String
    /// Whether a create is running, read when a key or button acts: SwiftUI can keep a key's action
    /// from an earlier render, so a value captured then would be stale.
    let creating: () -> Bool
    /// Whether the sheet should close; a failure leaves it up on the last step with the failure in `notices`.
    let create: () async -> Bool
    let content: Content
    let notices: Notices
    let closing: Closing
    @Environment(\.dismiss) private var dismiss

    init(title: String, height: CGFloat, steps: [Step], step: Binding<Int>, createLabel: String,
         creating: @autoclosure @escaping () -> Bool,
         create: @escaping () async -> Bool,
         @ViewBuilder content: () -> Content, @ViewBuilder notices: () -> Notices,
         @ViewBuilder closing: () -> Closing) {
        self.title = title; self.height = height; self.steps = steps; self._step = step
        self.createLabel = createLabel; self.creating = creating; self.create = create
        self.content = content(); self.notices = notices(); self.closing = closing()
    }

    var body: some View {
        SheetLayout(title: title, height: .fixed(height), onBackgroundTap: closeLists) {
            SheetStepper(step: step, names: steps.map(\.name), onSelect: navigate)
        } header: {
            EmptyView()
        } content: {
            FrontToBackStack(spacing: Space.block) {
                content
                if step == steps.count { CreationClosingBlock { closing } }
            }
        } footer: {
            SteppedSheetFooter(step: step, count: steps.count, createLabel: createLabel, creating: creating(),
                               canAdvance: current.canAdvance && !creating(), closeList: current.closeList,
                               cancel: cancel, back: back, advance: advance) {
                notices
            }
        }
        .interactiveDismissDisabled(creating())
    }

    private var current: Step {
        steps.indices.contains(step - 1) ? steps[step - 1] : Step(name: "", canAdvance: false)
    }

    /// Every list the current step has open.
    private func closeLists() { while current.closeList() {} }

    private func cancel() {
        guard !creating() else { return }
        dismiss.afterThisEvent()
    }

    private func back() {
        guard !creating(), step > 1 else { return }
        closeLists(); step -= 1
    }

    private func navigate(_ target: Int) {
        guard !creating(), SheetStepper.canNavigate(from: step, to: target, count: steps.count) else { return }
        closeLists(); step = target
    }

    /// The primary button's action, and ⌘↩'s: its `enabled` gates both, so the keycaps never
    /// advertise a key that does nothing. The create is awaited past the key's event before it dismisses.
    private func advance() {
        guard !creating() else { return }
        if step < steps.count { closeLists(); step += 1; return }
        Task { if await create() { dismiss() } }
    }
}

/// A stepped sheet's footer: its `notices` — with any action a notice offers drawn under it — over one
/// row of Cancel, then Back from step 2 and the primary: Continue, or the create label on the last
/// step. Cancel and Back are house secondary push buttons with no key; ⎋ is `sheetEscapeKey`'s.
struct SteppedSheetFooter<Notices: View>: View {
    let step: Int
    let count: Int
    let createLabel: String
    let creating: Bool
    let canAdvance: Bool
    let closeList: () -> Bool
    let cancel: () -> Void
    let back: () -> Void
    let advance: () -> Void
    let notices: Notices

    init(step: Int, count: Int, createLabel: String, creating: Bool, canAdvance: Bool, closeList: @escaping () -> Bool,
         cancel: @escaping () -> Void, back: @escaping () -> Void, advance: @escaping () -> Void,
         @ViewBuilder notices: () -> Notices) {
        self.step = step; self.count = count; self.createLabel = createLabel; self.creating = creating
        self.canAdvance = canAdvance; self.closeList = closeList
        self.cancel = cancel; self.back = back; self.advance = advance
        self.notices = notices()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            notices
            HStack(spacing: Space.base) {
                Button("Cancel", action: cancel).disabled(creating)
                Spacer(minLength: Space.base)
                if step > 1 { Button("Back", action: back).disabled(creating) }
                SheetPrimaryButton(title: step < count ? "Continue" : createLabel, enabled: canAdvance, action: advance)
            }
            .buttonStyle(.push(.secondary))
            .sheetEscapeKey(closeList: closeList, cancel: cancel)
        }
    }
}
