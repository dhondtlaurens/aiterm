import AppKit
import SwiftUI
import AiTermUI

/// The same plain Branch input as New Task, with existing branches offered under it.
struct BranchInput: View {
    @Binding var text: String
    @Binding var open: Bool
    let choices: [String]
    @State private var index = 0
    private struct Choice: Identifiable { let name: String; var id: String { name } }
    /// The six-row dropdown policy shared with the search pickers.
    private static let visibleLimit = 6
    private var shown: [Choice] { choices.prefix(Self.visibleLimit).map { Choice(name: $0) } }
    var body: some View {
        Input(placeholder: "feat/my-task", text: Binding(get: { text }, set: { text = $0; open = true; index = 0 }),
              monospaced: true, onFocus: { open = true }, onCommand: command)
            .overlay(alignment: .topLeading) {
                if open, !shown.isEmpty {
                    DropdownList(items: shown, index: $index, onPick: pick) { choice in
                        BranchSuggestion(name: choice.name)
                    }.offset(y: Size.control + Space.tight)
                }
            }
            .onChange(of: choices) { index = 0 }
    }
    private func pick(_ choice: Choice) { text = choice.name; open = false; index = 0 }
    private func command(_ selector: Selector) -> Bool {
        DropdownKeys.perform(selector, on: shown, index: $index, open: $open, listening: open, pick: pick)
    }
    private struct BranchSuggestion: View {
        let name: String
        @Environment(\.surface) private var surface
        var body: some View { Text(name).font(Typography.monoCode).foregroundStyle(surface.ink).lineLimit(1) }
    }
}
