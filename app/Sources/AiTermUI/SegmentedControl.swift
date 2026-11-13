import SwiftUI

/// The segmented track the agent picker, the sidebar size and a task's end are drawn from. Tabs
/// are not segments: a sheet's tabs are a `TabBar`.
///
/// 28 pt overall — `Size.control`, so it lines up with the fields beside it — which is a 24 pt
/// segment inside a 2 pt track: a `Radius.control` segment inside the track's `Radius.group`. The
/// track is a `field`, edged in `borderStrong`, as a field is. This
/// existed twice before, at 30 pt and at 34 pt, because neither copy knew about the other.
///
/// It is hand-built rather than a `Picker`: the system segmented control cannot carry a logo and
/// paints its selection in the accent colour.
///
/// The selected segment is a neutral fill (`controlActive`, the lightest ground), and the house
/// focus ring goes around the track while it has the keyboard. It inks each segment for the ground
/// it sits on — the selected one in the surface's ink, the rest in its secondary ink — so a
/// segment's label is plain `Text` that sets no colour.
public struct SegmentedControl<Value: Hashable, Content: View>: View {
    let values: [Value]
    @Binding var selection: Value
    let isSelectable: (Value) -> Bool
    let help: (Value) -> String?
    @ViewBuilder var content: (Value, Bool) -> Content
    // `@FocusState` is a normal property wrapper, not a macro, so it compiles without Xcode.
    @FocusState private var focused: Bool

    /// `isSelectable` says which segments can be picked; the rest stay in place, dimmed and
    /// disabled. `help` is a segment's tooltip, or `nil` for none.
    public init(values: [Value], selection: Binding<Value>,
                isSelectable: @escaping (Value) -> Bool = { _ in true },
                help: @escaping (Value) -> String? = { _ in nil },
                @ViewBuilder content: @escaping (Value, Bool) -> Content) {
        self.values = values
        self._selection = selection
        self.isSelectable = isSelectable
        self.help = help
        self.content = content
    }

    public var body: some View {
        HStack(spacing: Space.hairline) {
            ForEach(values, id: \.self) { value in
                let on = value == selection, selectable = isSelectable(value)
                Button { selection = value } label: {
                    SegmentInk(on: on) { content(value, on) }
                        .frame(maxWidth: .infinity)
                        .frame(height: Size.control - 2 * Space.hairline)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(on ? Palette.controlActive : .clear))
                        .contentShape(Rectangle())
                }
                .selectableButtonStyle(selectable)
                .opacity(selectable ? 1 : Opacity.disabled)
                .optionalHelp(help(value))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Space.hairline)
        .groupChrome(fill: Palette.field, edge: Palette.borderStrong)
        // A segmented control answers to ← and → on macOS. Without this the track could be reached
        // by tab and then did nothing, which is worse than not being focusable at all.
        .focusable()
        .focused($focused)
        // SwiftUI otherwise adds its own compositor-drawn halo as well as the house focus ring.
        .focusEffectDisabled()
        .focusRing(focused, cornerRadius: Radius.group)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Moves the selection by `delta`, skipping anything that cannot be picked and stopping at the
    /// ends.
    private func step(_ delta: Int) {
        if let next = SelectionStep.next(from: selection, by: delta, in: values, isSelectable: isSelectable) { selection = next }
    }
}

/// A segment's label in the ink of the ground the track sits on.
private struct SegmentInk<Label: View>: View {
    let on: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.surface) private var surface

    var body: some View {
        label().foregroundStyle(on ? surface.ink : surface.secondaryInk)
    }
}

private extension View {
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
