import SwiftUI
import AiTermUI
import AiTermCore

/// The branch line of a sidebar row: the branch of the tab you are looking at, plus a `+n` chip
/// when the same window has other branches open (design canvas, "Branch awareness · 17 Sep",
/// option A).
///
/// The name is the only thing allowed to truncate. The chip carries the fact that there is more to
/// see, so it keeps its intrinsic width however narrow the row gets — `fixedSize` plus the higher
/// layout priority is what makes SwiftUI shorten the name instead of the chip. Amber means the
/// agent is not on the branch the row is bound to; the tooltip then names both. A task row turns
/// `showsHelp` off: nothing on its badge line but a checked or merged badge answers the pointer.
struct BranchLabelView: View {
    let label: BranchLabel
    var showsHelp = true
    /// Replaces the `onSelection: Bool` this view used to take. `Surface.secondaryInk` is the
    /// drift-free branch name's ink on every ground — `Palette.muted`, a selected row's too, and
    /// `Palette.onAccentSecondary` only on the accent. A drifted branch is amber everywhere.
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale

    private var nameColor: Color {
        if label.drifted { return Palette.amber }
        return surface.secondaryInk
    }

    /// The name, or when the window has more to say, its detail: what the tooltip and VoiceOver say.
    private var words: String { label.detail.isEmpty ? label.name : label.detail }

    var body: some View {
        if !label.name.isEmpty {
            HStack(spacing: scale(Space.snug)) {
                Text(label.name)
                    .font(Typography.mono)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
                if label.extra > 0 {
                    Badge("+\(label.extra)")
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            // An empty `.help` would still claim the hover; put none on at all when it has nothing to say.
            .modifier(RowHelp(text: showsHelp ? words : ""))
            // Without its tooltip, VoiceOver still hears what it said: which branch each tab is on.
            .modifier(SpokenWords(text: showsHelp ? "" : words))
        }
    }
}

/// An accessibility label only when there is one to give.
private struct SpokenWords: ViewModifier {
    let text: String
    @ViewBuilder func body(content: Content) -> some View {
        if text.isEmpty { content } else { content.accessibilityElement(children: .ignore).accessibilityLabel(text) }
    }
}
