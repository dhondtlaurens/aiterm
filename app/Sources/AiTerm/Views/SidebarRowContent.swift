import SwiftUI
import AiTermUI
import AiTermCore

/// The three sidebar rows' grid. The column keeps its own content and layout priority;
/// the trailing mark keeps its own click target and background-card behavior.
struct SidebarRowContent<Column: View, Mark: View>: View {
    let avatars: AvatarGroup
    @ViewBuilder let column: () -> Column
    @ViewBuilder let mark: () -> Mark
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(Space.inset)) {
            AvatarGroupView(group: avatars)
            column()
            Spacer(minLength: scale(Space.tight))
            mark()
        }
    }
}

/// The label alone folds; subviews retain their clicks while folding is disabled.
struct FoldOnTap: ViewModifier {
    let enabled: Bool
    var selected = false
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded(action), including: enabled ? .all : .subviews)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(enabled ? .isButton : [])
            .accessibilityAddTraits(selected ? .isSelected : [])
            .modifier(DefaultAccessibilityAction(enabled: enabled, action: action))
    }
}

/// The headings' horizontal gutter, with the trailing glyph's overhang kept in screen points.
struct SidebarHeadingInset: ViewModifier {
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
    }
}
