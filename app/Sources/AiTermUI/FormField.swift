import SwiftUI

/// A label above its control, at the system's spacing, with an optional accessory at the trailing end of
/// the label's row: an action on the field, such as a small push button. What the control hangs out of
/// itself — a dropdown's results — draws over the lines after it (`FrontToBackStack`).
public struct FormField<Content: View, Accessory: View>: View {
    let label: String
    let accessory: Accessory
    let content: Content

    public init(_ label: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.label = label
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        FrontToBackStack(spacing: Space.snug) {
            if Accessory.self == EmptyView.self {
                labelText
            } else {
                HStack(spacing: Space.base) {
                    labelText
                    Spacer(minLength: Space.base)
                    accessory
                }
            }
            content
        }
    }

    private var labelText: some View { Text(label).font(Typography.label).foregroundStyle(Palette.muted) }
}

public extension FormField where Accessory == EmptyView {
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.init(label, accessory: { EmptyView() }, content: content)
    }
}

/// Subordinate copy under a control: what a field means, why an option is unavailable, what went
/// wrong. It inks itself by `tone` — a caller's `.foregroundStyle` outside it would lose to the ink
/// set inside, which is how three warnings once drew grey.
public struct HelpText: View {
    /// What the copy is saying.
    public enum Tone: Equatable, Sendable {
        /// Explanation: the default, in secondary ink.
        case secondary
        /// Something needs attention — a failed search, a missing CLI — in the warning semantic.
        case warning
    }

    let text: Text
    let tone: Tone
    let fixedVerticalSize: Bool
    @Environment(\.surface) private var surface

    /// Paragraph help takes its full height; inline captions keep their container's height proposal.
    public init(_ text: String, tone: Tone = .secondary, fixedVerticalSize: Bool = true) {
        self.init(Text(text), tone: tone, fixedVerticalSize: fixedVerticalSize)
    }

    /// Composed text keeps its own emphasis, with the same help face and surface-aware secondary ink.
    public init(_ text: Text, tone: Tone = .secondary, fixedVerticalSize: Bool = true) {
        self.text = text
        self.tone = tone
        self.fixedVerticalSize = fixedVerticalSize
    }

    public var body: some View {
        text.font(Typography.help)
            .foregroundStyle(tone == .warning && !surface.isOnAccent ? Palette.amber : surface.secondaryInk)
            .fixedSize(horizontal: false, vertical: fixedVerticalSize)
    }
}
