import SwiftUI

/// A segmented tab bar's command-number keys, carried by hidden buttons with each
/// tab's own title and selection rule.
struct TabShortcuts<Item: Hashable>: ViewModifier {
    let items: [Item]
    let title: (Item) -> String
    let key: (Item) -> KeyEquivalent
    let select: (Item) -> Void

    func body(content: Content) -> some View {
        content.background {
            ForEach(items, id: \.self) { item in
                Button(title(item)) { select(item) }.keyboardShortcut(key(item), modifiers: .command)
            }
            .hidden()
        }
    }
}
