import AppKit
import SwiftUI

/// A row of underline tabs: Settings' panes and the broadcast board's Board · Activity · Summary.
/// It sits at the foot of a sheet's header, so its selected tab's underline lies on the header's rule.
///
/// Each tab is its label in `Typography.bodyEmphasis`, `Space.base` over its underline, the tabs
/// `Space.section` apart from the leading edge. No accent: the selection is the label's ink and the
/// bar under it.
///
/// | State | Look |
/// | --- | --- |
/// | Selected | `Palette.text` label over a `Size.tabIndicator` bar in `Palette.text`, as wide as the label; the `.isSelected` trait |
/// | Unselected | `Palette.muted` label, no bar |
/// | Rejected by `isSelectable` | Faded to `Opacity.disabled` and disabled: no click, VoiceOver reads it dimmed |
/// | Hover / pressed | As at rest: a tab is a plain button and the selection moves on click |
/// | Keyboard focus | The bar is one focusable control: ← and → move the selection among selectable tabs, stopping at the ends. The house `focusRing` goes around the selected tab while the keyboard put focus there (⇥) or is using it (← →) — not for the focus a sheet hands its first control as it opens, nor for a click |
///
/// The bar has no command-number keys of its own: a sheet adds them with hidden buttons (`TabShortcuts`).
public struct TabBar<Value: Hashable, Label: View>: View {
    let values: [Value]
    @Binding var selection: Value
    let isSelectable: (Value) -> Bool
    @ViewBuilder var label: (Value) -> Label
    @FocusState private var focused: Bool
    /// The focus is the keyboard's: ⇥ brought it, or ← → have used it since. A sheet hands its first
    /// focusable control the focus as it opens — the bar, in Settings and on the board — and a ring
    /// there would greet every opening; a click focuses it too. Neither is the keyboard's.
    @State private var keyboardFocus = false

    /// `isSelectable` says which tabs can be picked; the rest stay in place, faded and disabled.
    /// `label` is a tab's words: the bar sets their face and ink.
    public init(values: [Value], selection: Binding<Value>, isSelectable: @escaping (Value) -> Bool = { _ in true },
                @ViewBuilder label: @escaping (Value) -> Label) {
        self.values = values
        self._selection = selection
        self.isSelectable = isSelectable
        self.label = label
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: Space.section) {
            ForEach(values, id: \.self) { value in
                let on = value == selection
                TabBarTab(on: on, selectable: isSelectable(value), ringed: on && focused && keyboardFocus) {
                    selection = value
                    keyboardFocus = false
                } label: {
                    label(value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A tab bar answers to ← and → as a segmented control does; reached by ⇥, it would otherwise do nothing.
        .focusable()
        .focused($focused)
        // SwiftUI otherwise adds its own compositor-drawn halo as well as the house focus ring.
        .focusEffectDisabled()
        .onChange(of: focused) { _, now in keyboardFocus = now && Self.tabbedIn(NSApp.currentEvent) }
        .onMoveCommand { direction in
            keyboardFocus = true
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func step(_ delta: Int) {
        if let next = SelectionStep.next(from: selection, by: delta, in: values, isSelectable: isSelectable) { selection = next }
    }

    /// Whether `event`, the one being handled as focus arrives, is ⇥ or ⇧⇥: focus the keyboard moved.
    static func tabbedIn(_ event: NSEvent?) -> Bool {
        event?.type == .keyDown && event?.keyCode == 48
    }
}

/// One tab: its label over its underline, faded and disabled when it cannot be picked, ringed while the
/// bar has the keyboard and it is the selected one.
struct TabBarTab<Label: View>: View {
    let on: Bool
    let selectable: Bool
    let ringed: Bool
    let select: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: select) {
            VStack(spacing: Space.base) {
                label().font(Typography.bodyEmphasis).foregroundStyle(on ? Palette.text : Palette.muted)
                Rectangle().fill(on ? Palette.text : .clear).frame(height: Size.tabIndicator)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .selectableButtonStyle(selectable)
        .opacity(selectable ? 1 : Opacity.disabled)
        // `Space.tight` clear of the label either side.
        .padding(.horizontal, Space.tight)
        .focusRing(ringed, cornerRadius: Radius.chip)
        .padding(.horizontal, -Space.tight)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// ← and → on a row of choices — `SegmentedControl`'s segments, `TabBar`'s tabs: the next selectable
/// value `delta` away, skipping the ones that cannot be picked; nil at either end.
enum SelectionStep {
    static func next<Value: Hashable>(from selection: Value, by delta: Int, in values: [Value],
                                      isSelectable: (Value) -> Bool) -> Value? {
        guard var index = values.firstIndex(of: selection) else { return nil }
        repeat {
            index += delta
            guard values.indices.contains(index) else { return nil }
        } while !isSelectable(values[index])
        return values[index]
    }
}

extension View {
    /// A choice that cannot be picked is disabled, so VoiceOver reads it as dimmed and a click does
    /// nothing. It is drawn bare rather than `.plain`, whose own disabled look would dim it again on
    /// top of the caller's `Opacity.disabled`; at rest the two draw the same pixels.
    @ViewBuilder
    func selectableButtonStyle(_ selectable: Bool) -> some View {
        if selectable {
            buttonStyle(.plain)
        } else {
            buttonStyle(UnselectableChoiceStyle()).disabled(true)
        }
    }
}

private struct UnselectableChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
