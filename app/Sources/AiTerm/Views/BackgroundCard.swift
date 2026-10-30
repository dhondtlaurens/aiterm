import SwiftUI
import AiTermUI
import AiTermCore

/// What a background mark's card says (proposal Background work on your own tasks B, and A of its "several jobs at
/// once", 22 Oct 2026): that the turn ended, how many jobs still run when there are several, then one job per line in
/// the order the tabs list them — a shell by its command after a terminal glyph, a monitor or any other task by its
/// description after an eye.
struct BackgroundCard: Equatable {
    let jobs: [BackgroundJob]

    var heading: String {
        jobs.count > 1 ? "Turn ended · \(jobs.count) running in the background" : "Turn ended · running in the background"
    }

    /// The card in words, the row's value for VoiceOver: every job, which the card may scroll or cut short.
    var spoken: String {
        let what = jobs.map(\.text).joined(separator: ", ")
        return what.isEmpty ? TaskStatus.background.label : "Turn ended, running in the background: " + what
    }

    static func glyph(_ kind: BackgroundJob.Kind) -> String { kind == .shell ? "apple.terminal" : "eye" }
}

/// Whether a background mark's card is open. It opens once the pointer has rested on the mark for `openDelay`, so a
/// pointer passing over the trailing column leaves the rows alone; it stays while the pointer is on the mark or the
/// card, so the card can be scrolled; and it closes `closeDelay` after the pointer left both, time enough to cross
/// the `Space.tight` between them.
@MainActor @Observable
final class BackgroundCardHover {
    static let openDelay: Duration = .milliseconds(300)
    static let closeDelay: Duration = .milliseconds(150)

    private(set) var isOpen = false
    @ObservationIgnored private var onMark = false
    @ObservationIgnored private var onCard = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) { self.sleep = sleep }

    func mark(_ hovering: Bool) { onMark = hovering; settle() }
    func card(_ hovering: Bool) { onCard = hovering; settle() }

    private func settle() {
        pending?.cancel()
        let wanted = onMark || onCard
        guard wanted != isOpen else { return }
        pending = Task { [sleep] in
            await sleep(wanted ? Self.openDelay : Self.closeDelay)
            guard !Task.isCancelled, (onMark || onCard) == wanted else { return }
            isOpen = wanted
        }
    }
}

/// The card: `menuChrome` at the row pill's `Radius.control` around the heading in `Typography.help` and secondary
/// ink, then a line per job in the ink, a shell's command in `Typography.mono`, anything else's description in
/// `Typography.help`, each after its glyph at `Size.inlineMark` and cut at its end when the row is too narrow. Every
/// line is `Size.chip` tall and `Space.tight` from the next, `Space.base` inside above and below and `Space.gap` either
/// side, so the heading lies on the row's title line and the first job on its second (the background card, A, 29 Oct
/// 2026). It fills what it is offered, the pill up to the mark, and scrolls inside past that. It floats on the menu's
/// ground, never the row's, so a selected row's card reads as any other's.
struct BackgroundCardView: View {
    let card: BackgroundCard
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        // Offered its row's pill up to the mark (`backgroundCard`), it fills it: its lines from the top while they
        // fit, the whole of it scrolling past that.
        ViewThatFits(in: .vertical) {
            lines
            ScrollView(.vertical) { lines }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .menuChrome(cornerRadius: scale(Radius.control))
        .surface(.sheet)
        .accessibilityHidden(true)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            HelpText(card.heading, fixedVerticalSize: false).lineLimit(1)
                .frame(height: scale(Size.chip))
            ForEach(Array(card.jobs.enumerated()), id: \.offset) { _, job in
                HStack(spacing: scale(Space.tight)) {
                    Icon(.symbol(BackgroundCard.glyph(job.kind)), size: scale(Size.inlineMark), tint: Palette.muted)
                    Text(job.text).font(job.kind == .shell ? Typography.mono : Typography.help)
                        .foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
                }
                .frame(height: scale(Size.chip))
            }
        }
        .padding(.vertical, scale(Space.base)).padding(.horizontal, scale(Space.gap))
    }
}

extension View {
    /// A row's content with its background mark's card laid over it while open: on the row pill's top, bottom and
    /// leading edges, its trailing edge `Space.tight` before the mark's slot, so it covers the pill's wash or selection
    /// up to the mark and nothing else. Applied inside `SelectableRow`, so it reaches out over the row's `Space.base`
    /// padding to the pill's edges. No jobs, no card. It holds the card's hover, which the mark inside it reads
    /// (`opensBackgroundCard`). Debug fixtures can seed that state through the environment.
    func backgroundCard(_ jobs: [BackgroundJob]) -> some View {
        modifier(BackgroundCardOverlay(jobs: jobs))
    }

    /// A row's trailing mark as the hover target that opens its card: the whole `Size.slot` square.
    func opensBackgroundCard(slot: CGFloat) -> some View { modifier(OpensBackgroundCard(slot: slot)) }
}

private struct BackgroundCardHoverKey: EnvironmentKey { static let defaultValue: BackgroundCardHover? = nil }

private extension EnvironmentValues {
    var backgroundCardHover: BackgroundCardHover? {
        get { self[BackgroundCardHoverKey.self] }
        set { self[BackgroundCardHoverKey.self] = newValue }
    }
}

/// The hover lives here rather than in the row: a row view holding a new object on every rebuild would never equal
/// itself, and every row would redraw for any change to the sidebar.
private struct BackgroundCardOverlay: ViewModifier {
    let jobs: [BackgroundJob]
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.seededHover) private var seededHover
    #endif
    // `@State`'s storage, written out as `SelectableRow`'s is.
    private var _own = State(initialValue: BackgroundCardHover())

    init(jobs: [BackgroundJob]) { self.jobs = jobs }

    private var hover: BackgroundCardHover {
        #if DEBUG
        if let hover = seededHover?.backgroundCard { return hover }
        #endif
        return _own.wrappedValue
    }

    func body(content: Content) -> some View {
        content
            .environment(\.backgroundCardHover, hover)
            .overlay(alignment: .topTrailing) {
                if hover.isOpen, !jobs.isEmpty {
                    BackgroundCardView(card: BackgroundCard(jobs: jobs))
                        .onHover { hover.card($0) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(EdgeInsets(top: -scale(Space.base), leading: -scale(Space.base), bottom: -scale(Space.base),
                                            trailing: SidebarRowLayout.trailingSlot(scale) + scale(Space.tight)))
                }
            }
    }
}

private struct OpensBackgroundCard: ViewModifier {
    let slot: CGFloat
    @Environment(\.backgroundCardHover) private var hover

    func body(content: Content) -> some View {
        content.frame(width: slot, height: slot).contentShape(Rectangle()).onHover { hover?.mark($0) }
    }
}
