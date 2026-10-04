import SwiftUI
import AiTermUI

/// One key the app answers to, as Settings › Interface lists it.
struct KeyBinding: Equatable, Identifiable {
    let action: String
    let keys: [String]
    var id: String { action }

    /// The keys as VoiceOver should say them. It names the glyphs by their Unicode names otherwise
    /// — ⎋ is "broken circle with northwest arrow" — so the ones the tab lists are spelt out.
    var spokenKeys: String {
        keys.map { Self.spokenNames[$0] ?? $0 }.joined(separator: " ")
    }

    private static let spokenNames = [
        "⌘": "Command", "⇧": "Shift", "⌥": "Option", "⌃": "Control", "↩": "Return", "⎋": "Escape",
        "⌫": "Delete", "⇥": "Tab", "↑": "Up Arrow", "↓": "Down Arrow", "←": "Left Arrow", "→": "Right Arrow",
        "−": "minus", "+": "plus", "1–4": "1 to 4",
    ]
}

/// A group of keys that work in the same place.
struct KeyBindingGroup: Equatable, Identifiable {
    let title: String
    let help: String
    let bindings: [KeyBinding]
    var id: String { title }
}

enum KeyBindings {
    /// Every key AiTerm answers to, plus the one macOS key that moves between it and iTerm2.
    /// Ordered by reach, widest first — each group works only where the one before it does — and,
    /// within a group, in the order they are used. Written out by hand: the handlers live in the
    /// menu bar, the sidebar list, the sheets and the pickers, and `KeyboardSettingsTests` checks
    /// the menu's against this list.
    static let all: [KeyBindingGroup] = [
        KeyBindingGroup(title: "Switching apps",
                        help: "macOS’s own switcher, not AiTerm’s. A quick press goes back to the app you were last in.",
                        bindings: [KeyBinding(action: "Switch between AiTerm and iTerm2", keys: ["⌘", "⇥"])]),
        // Each row is a menu item, titled verbatim: File's, View's, then the AiTerm menu's, each in
        // its menu's order.
        KeyBindingGroup(title: "Anywhere in AiTerm", help: "The menu bar’s keys.", bindings: [
            KeyBinding(action: "Add Project…", keys: ["⌘", "P"]),
            KeyBinding(action: "Add Divider…", keys: ["⌘", "D"]),
            KeyBinding(action: "New Task…", keys: ["⌘", "N"]),
            KeyBinding(action: "New Review…", keys: ["⌘", "R"]),
            KeyBinding(action: "New Terminal…", keys: ["⌘", "T"]),
            KeyBinding(action: "Zoom In", keys: ["⌘", "+"]),
            KeyBinding(action: "Zoom Out", keys: ["⌘", "−"]),
            KeyBinding(action: "Actual Size", keys: ["⌘", "0"]),
            KeyBinding(action: "Focus View", keys: ["⌘", "F"]),
            KeyBinding(action: "List View", keys: ["⌘", "L"]),
            KeyBinding(action: "Backpack Mode", keys: ["⌘", "B"]),
            KeyBinding(action: "Settings…", keys: ["⌘", ","]),
            KeyBinding(action: "Hide AiTerm", keys: ["⌘", "H"]),
            KeyBinding(action: "Hide Others", keys: ["⌥", "⌘", "H"]),
            KeyBinding(action: "Quit AiTerm", keys: ["⌘", "Q"]),
        ]),
        KeyBindingGroup(title: "Sidebar", help: "While the list has the keyboard.", bindings: [
            KeyBinding(action: "Peek at a row’s window", keys: ["↑", "↓"]),
            KeyBinding(action: "Go to the row’s window, fold or open a project, or open an empty one’s menu", keys: ["↩"]),
            KeyBinding(action: "Remove the task, review or terminal", keys: ["⌘", "⌫"]),
        ]),
        KeyBindingGroup(title: "Sheets", help: "New task, New review, New terminal, Add divider, Rename, Jira projects and Settings.", bindings: [
            KeyBinding(action: "Continue, create or save", keys: ["⌘", "↩"]),
            KeyBinding(action: "Back a step, or close", keys: ["⎋"]),
            // One row for the four: the tabs are numbered in the order the tab bar draws them.
            KeyBinding(action: "Switch Settings tabs", keys: ["⌘", "1–4"]),
        ]),
        KeyBindingGroup(title: "Lists and the prompt", help: "A picker’s results, and the prompt’s completions.", bindings: [
            KeyBinding(action: "Move through the list", keys: ["↑", "↓"]),
            KeyBinding(action: "Pick the highlighted item", keys: ["↩"]),
            KeyBinding(action: "Close the list", keys: ["⎋"]),
            KeyBinding(action: "Commands and skills", keys: ["/"]),
        ]),
    ]
}

/// The Interface tab's "Keyboard shortcuts" section: every key, read-only for now, under one line of
/// help. Each group is a `SettingsGroup`, as "Sidebar badges" is above it, with rows split by a
/// `Hairline` and the keys in `Kbd`'s caps, inked for the sheet they sit on, at the trailing edge.
struct KeyboardSettingsPane: View {
    var groups: [KeyBindingGroup] = KeyBindings.all

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Keyboard shortcuts").font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                HelpText("Shortcuts can’t be changed yet.")
            }
            ForEach(groups) { group($0) }
        }
    }

    private func group(_ group: KeyBindingGroup) -> some View {
        SettingsGroup(title: group.title, help: group.help) {
            ForEach(Array(group.bindings.enumerated()), id: \.element.id) { index, binding in
                if index > 0 { Hairline() }
                HStack(spacing: Space.gap) {
                    Text(binding.action).font(Typography.body).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Kbd(binding.keys)
                }
                // The caps are hidden from VoiceOver, so the row reads its keys out in words.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(binding.action)
                .accessibilityValue(binding.spokenKeys)
            }
        }
    }
}
