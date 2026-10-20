import SwiftUI
import AiTermUI

/// Every “needs your attention or your answer” in the app, drawn one way (spec §6.1, §13, §14): the
/// sidebar's banner about a failed operation or a refused connection, a failed create in a sheet's
/// footer, the Backpack sheet's permission ask, and Find a Fix's states.
///
/// An amber `exclamationmark.circle.fill` at `Size.inlineMark`, `Space.snug` before the title in
/// `Typography.label` and `Palette.text`, on one row; the description under it in `Typography.help` and
/// `Palette.muted`; then whatever a fix adds (`extra`: its busy line or its proposal); then the
/// actions as links `Space.gap` apart. `Space.tight` between the rows, and nothing indented: the
/// description starts under the mark. No amber text — the mark carries the tone, and the words say
/// whether it is a question or a failure. `help` is the tooltip, git's whole output where there is one.
///
/// Inside a sheet's footer the caller passes no actions and keeps its buttons. Not Notices: field
/// help, row captions, toasts, and the grey line while iTerm2 connects. Its tokens read `scale`, so
/// in the sidebar it grows with the interface size; a sheet resets the scale to ×1.
struct Notice<Actions: View>: View {
    static var symbol: String { "exclamationmark.circle.fill" }

    let title: String
    let description: String?
    let help: String?
    private let extra: AnyView?
    @ViewBuilder let actions: Actions
    @Environment(\.interfaceScale) private var scale

    init(title: String, description: String?, help: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.description = description; self.help = help
        extra = nil
        self.actions = actions()
    }

    /// With `extra` drawn under the description: a fix's busy line or its proposal, in the same Notice
    /// as the problem it is for.
    init<Extra: View>(title: String, description: String?, help: String? = nil, @ViewBuilder extra: () -> Extra,
                      @ViewBuilder actions: () -> Actions) {
        self.title = title; self.description = description; self.help = help
        self.extra = AnyView(extra())
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            Group {
                HStack(alignment: .firstTextBaseline, spacing: scale(Space.snug)) {
                    Icon(.symbol(Self.symbol), size: scale(Size.inlineMark), tint: Palette.amber).accessibilityHidden(true)
                    Text(title).font(Typography.label).foregroundStyle(Palette.text)
                }
                if let description {
                    Text(description).font(Typography.help).foregroundStyle(Palette.muted)
                }
            }
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .help(help ?? "")
            if let extra { extra }
            if Actions.self != EmptyView.self {
                HStack(spacing: scale(Space.gap)) { actions }
                    .buttonStyle(.link).font(Typography.help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Notice where Actions == EmptyView {
    /// A Notice with no links: in a sheet's footer, whose buttons are its actions.
    init(title: String, description: String? = nil, help: String? = nil) {
        self.init(title: title, description: description, help: help) { EmptyView() }
    }
}
