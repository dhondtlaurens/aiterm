import SwiftUI
import AiTermUI
import AiTermCore

/// Step 3 of both sheets. `extra` is New Task's "Include Jira ticket details" checkbox; New Review
/// passes nothing.
struct PromptStep<Extra: View>: View {
    /// Made as the step draws rather than as the sheet builds it: a `Binding` reads its value when
    /// it is made, and a sheet that read the prompt would be redrawn whole on every keystroke.
    private let text: () -> Binding<String>
    let agent: AgentKind
    let completions: PromptCompletions
    let extra: () -> Extra
    var _editorFocused = State(initialValue: false)
    private var editorFocused: Bool {
        get { _editorFocused.wrappedValue }
        nonmutating set { _editorFocused.wrappedValue = newValue }
    }

    init(text: @autoclosure @escaping () -> Binding<String>, agent: AgentKind, completions: PromptCompletions,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.text = text; self.agent = agent; self.completions = completions; self.extra = extra
    }

    /// The empty-prompt placeholder sits where `PromptEditor`'s first glyph would: across, its text
    /// inset plus the container's line-fragment padding; down, its text inset plus
    /// ``placeholderDrop``. Read from the editor, so the two move together if its inset changes.
    private static var placeholderInsetX: CGFloat { PromptEditor.textInset.width + PromptEditor.lineFragmentPadding }
    private static var placeholderInsetY: CGFloat { PromptEditor.textInset.height + placeholderDrop }
    /// A point further down, fitted to where the text view draws its first line rather than derived
    /// from it; bespoke to this one overlay.
    private static var placeholderDrop: CGFloat { 1 }
    /// Trimmed further than the sheet's own gutters (`Space.margin` on each side) so the completion
    /// popup doesn't run to the prompt field's own edge. Tuned by eye, not derived from a scale.
    private static var completionPopupTrim: CGFloat { 40 }
    /// The prompt editor's height. Moved with the step; it was a literal here before.
    private static var editorHeight: CGFloat { 150 }

    var body: some View {
        let text = self.text()
        VStack(alignment: .leading, spacing: Space.block) {
            FormField("First prompt (optional)") {
                ZStack(alignment: .topLeading) {
                    PromptEditor(text: text, agent: agent, completions: completions,
                                 onFocusChange: { if editorFocused != $0 { editorFocused = $0 } }, focusOnAppear: true)
                        .frame(height: Self.editorHeight)
                        .fieldBox(focused: editorFocused)
                    if text.wrappedValue.isEmpty {
                        Text("Describe what the agent should do.").font(Typography.promptMono).foregroundStyle(Palette.placeholder)
                            .padding(.horizontal, Self.placeholderInsetX).padding(.top, Self.placeholderInsetY).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    CompletionPopup(completions: completions,
                                    width: Sheet.width - 2 * Space.margin - Self.completionPopupTrim)
                }
                .zIndex(2)
                CompletionHint()
            }
            .zIndex(2)
            extra()
        }
    }
}
