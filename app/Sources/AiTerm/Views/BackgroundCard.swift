import SwiftUI
import AiTermUI
import AiTermCore

/// The existing ordered work list, with native short descriptions when available. Raw commands
/// remain on each job for fallback/help; the visual and spoken descriptions use the same label.
/// Idle teammates (`BackgroundJob.idle`) are alive but run nothing: they follow the running work, each wearing a `zzz`
/// corner on its avatar, and the count in the card's heading leaves them out (proposal Background work with vendor
/// avatars, B2 without its heading, 26 Nov 2026).
struct BackgroundCard: Equatable {
    let jobs: [BackgroundJob]

    var running: [BackgroundJob] { jobs.filter { !$0.idle } }
    var idle: [BackgroundJob] { jobs.filter(\.idle) }

    var heading: String {
        switch running.count {
        case 0 where !idle.isEmpty: "Background work · none running"
        case 0, 1: "Background work"
        case let count: "Background work · \(count) jobs"
        }
    }

    /// The card's lines under its heading: the running jobs, then the idle ones.
    var lines: [BackgroundJob] { running + idle }

    /// The agents at work as the task row's avatar group, from two up (C1): idle teammates and tools do not count.
    var agents: AvatarGroup? {
        let marks = running.filter(\.kind.isAgent).map(Self.mark)
        return marks.count < 2 ? nil : SidebarModel.avatars(of: marks)
    }

    /// The card in words, the row's value for VoiceOver: every job, which the card may scroll or cut short.
    var spoken: String {
        let what = running.map(\.label).joined(separator: ", ")
        let waiting = idle.map(\.label).joined(separator: ", ")
        var parts: [String] = []
        if !what.isEmpty { parts.append("Background work: " + what) }
        if !waiting.isEmpty { parts.append("Idle, can be messaged: " + waiting) }
        return parts.isEmpty ? TaskStatus.background.label : parts.joined(separator: ". ")
    }

    /// Preserve the turn/input status and the row's other detail, without repeating jobs its
    /// Operator tooltip already names. The visual card stays accessibility-hidden.
    func accessibilityValue(status: TaskStatus, detail: String? = nil) -> String {
        var parts = [status.label]
        if let detail, !detail.isEmpty, detail != status.label { parts.append(detail) }
        let remaining = jobs.filter { !(detail?.contains($0.text) ?? false) && !(detail?.contains($0.label) ?? false) }
        if !remaining.isEmpty { parts.append(BackgroundCard(jobs: remaining).spoken) }
        return parts.joined(separator: ". ")
    }

    /// Whose mark leads a line (A): agent work (a subagent, a teammate, a workflow, a cloud session, a dream) wears the
    /// vendor of the tab it runs in, Claude unless the tab names another; everything else (a shell, a monitor, an MCP
    /// task, a test run) the terminal's.
    static func mark(_ job: BackgroundJob) -> SessionAgent {
        job.kind.isAgent ? job.agent ?? .claude : .shell
    }
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

    init(isOpen: Bool = false, sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.isOpen = isOpen; self.sleep = sleep
    }

    func mark(_ hovering: Bool) { onMark = hovering; settle() }
    func card(_ hovering: Bool) { onCard = hovering; settle() }
    func close() {
        pending?.cancel(); pending = nil
        onMark = false; onCard = false; isOpen = false
    }

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

/// The heading stays still above up to five one-line jobs. Only the jobs scroll; their native
/// short descriptions use the system face, raw shell-command fallbacks the monospaced face.
struct BackgroundCardView: View {
    let card: BackgroundCard
    var visibleJobs = maximumVisibleJobs
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.motionStill) private var motionStill
    #endif

    private var snapshotDrawing: Bool {
        #if DEBUG
        motionStill == .snapshot
        #else
        false
        #endif
    }

    /// A local item-count policy, not a new shared measurement token.
    static let maximumVisibleJobs = 5
    static let cornerRadius = Radius.control

    /// Every line's mark, agent or tool alike, at the size a vendor mark takes outside an avatar group (A).
    private static let markSize = Size.vendorMark

    static func height(jobs: Int, scale: InterfaceScale) -> CGFloat {
        2 * scale(Space.base) + scale(Size.chip)
            + CGFloat(min(maximumVisibleJobs, max(0, jobs))) * (scale(Size.chip) + scale(Space.tight))
    }

    static func visibleJobs(total: Int, availableHeight: CGFloat, scale: InterfaceScale) -> Int {
        let room = availableHeight - 2 * scale(Space.base) - scale(Size.chip)
        let fits = max(0, Int(floor(room / (scale(Size.chip) + scale(Space.tight)))))
        return min(total, maximumVisibleJobs, fits)
    }

    var body: some View {
        let rows = min(card.lines.count, max(0, visibleJobs), Self.maximumVisibleJobs)
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            HStack(spacing: scale(Space.tight)) {
                HelpText(card.heading, fixedVerticalSize: false).lineLimit(1)
                Spacer(minLength: 0)
                if let agents = card.agents { AvatarGroupView(group: agents, markSize: Size.vendorMark) }
            }
            .frame(height: scale(Size.chip))
            if rows > 0 {
                Group {
                    // ImageRenderer does not materialise native scroll views. Static fixtures
                    // draw these same lines clipped; hosted tests exercise the actual scroller.
                    if snapshotDrawing { lines }
                    else if card.lines.count > rows {
                        ScrollView(.vertical) { lines }
                    } else { lines }
                }
                .frame(height: CGFloat(rows) * scale(Size.chip) + CGFloat(rows - 1) * scale(Space.tight),
                       alignment: .topLeading)
                .clipped()
            }
        }
        .modifier(FloatingCardChrome(height: Self.height(jobs: rows, scale: scale)))
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, job in
                HStack(alignment: .center, spacing: scale(Space.tight)) {
                    VendorMark(agent: BackgroundCard.mark(job), size: scale(Self.markSize))
                        .overlay(alignment: .bottomTrailing) {
                            if job.idle { IdleCorner().offset(x: scale(Space.hairline), y: scale(Space.hairline)) }
                        }
                    Text(job.label).font(job.isCommand ? Typography.mono : Typography.help)
                        .foregroundStyle(job.idle ? Palette.muted : Palette.text).lineLimit(1).truncationMode(.tail)
                        .help(job.kind == .shell && !job.isCommand ? job.text : "")
                }
                .frame(height: scale(Size.chip))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An idle teammate's corner (B2): a `Size.cornerBadge` disc in `Palette.controlActive` with `zzz` in `Palette.text`,
/// over the avatar's corner and overhanging it by `Space.hairline`, ringed in the card's ground so it reads apart from
/// the avatar, as `Badge(corner:)`'s check is.
private struct IdleCorner: View {
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    /// The glyph inside the disc, in proportion to it, as `SettledMark` draws its check.
    private static let glyphShare: CGFloat = 0.6
    /// The ring that cuts the disc from the avatar beneath, stroked under its fill so a one-point hairline shows outside
    /// it. Unscaled, as every border is.
    private static let ring: CGFloat = 2

    var body: some View {
        let size = scale(Size.cornerBadge)
        Icon(.symbol("zzz"), size: size * Self.glyphShare, tint: Palette.text)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.controlActive))
            .background { Circle().stroke(surface.occludingBackground, lineWidth: Self.ring) }
    }
}

/// The chrome a floating sidebar card is drawn in, the background-work card's and the signal card's: its padding, at
/// `height`, in `menuChrome` on the menu's surface, so a ring drawn on it occludes in the card's own ground. Hidden from
/// VoiceOver: the row's value says what the card does.
struct FloatingCardChrome: ViewModifier {
    let height: CGFloat
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content
            .padding(.vertical, scale(Space.base)).padding(.horizontal, scale(Space.gap))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height)
            .menuChrome(cornerRadius: scale(BackgroundCardView.cornerRadius))
            .surface(.menu)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A source row's hover and native anchor, applied inside SelectableRow's padding. The sidebar
    /// presenter floats the card; standalone debug fixtures draw its content directly.
    func backgroundCard(_ jobs: [BackgroundJob], source: RowSelection,
                        activate: @escaping () -> Void, commands: [[RowCommand]]) -> some View {
        modifier(BackgroundCardOverlay(jobs: jobs, source: source, activate: activate, commands: commands))
    }

    /// A row's trailing mark as the hover target that opens its card: the whole `Size.slot` square.
    func opensBackgroundCard(slot: CGFloat) -> some View { modifier(OpensBackgroundCard(slot: slot)) }

    /// A task row's signal card: the hover its avatar's disc opens, on the same delays as the background card's, and
    /// its native anchor, applied inside SelectableRow's padding. `card` is nil for a row with no disc; the sidebar
    /// presenter resolves the open card from the projection, and only standalone debug fixtures call `card`.
    func signalCard(_ card: (() -> SignalCard?)?, source: RowSelection,
                    activate: @escaping () -> Void, commands: [[RowCommand]]) -> some View {
        modifier(SignalCardOverlay(card: card, source: source, activate: activate, commands: commands))
    }

    /// The signals disc as the hover target that opens its card: a `square` centred on it.
    func opensSignalCard(square: CGFloat) -> some View { modifier(OpensSignalCard(square: square)) }
}

private struct BackgroundCardHoverKey: EnvironmentKey { static let defaultValue: BackgroundCardHover? = nil }
private struct SignalCardHoverKey: EnvironmentKey { static let defaultValue: BackgroundCardHover? = nil }

private extension EnvironmentValues {
    var backgroundCardHover: BackgroundCardHover? {
        get { self[BackgroundCardHoverKey.self] }
        set { self[BackgroundCardHoverKey.self] = newValue }
    }
    /// The disc's card's hover, a second `BackgroundCardHover` beside the trailing mark's: the two open and close apart.
    var signalCardHover: BackgroundCardHover? {
        get { self[SignalCardHoverKey.self] }
        set { self[SignalCardHoverKey.self] = newValue }
    }
}

/// The hover lives here rather than in the row: a row view holding a new object on every rebuild would never equal
/// itself, and every row would redraw for any change to the sidebar.
private struct BackgroundCardOverlay: ViewModifier {
    let jobs: [BackgroundJob]
    let source: RowSelection
    let activate: () -> Void
    let commands: [[RowCommand]]
    @Environment(\.backgroundCardPresenter) private var presenter
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.seededHover) private var seededHover
    #endif
    @State private var own = BackgroundCardHover()

    private var hover: BackgroundCardHover {
        #if DEBUG
        if let hover = seededHover?.backgroundCard { return hover }
        #endif
        return own
    }

    func body(content: Content) -> some View {
        content
            .environment(\.backgroundCardHover, jobs.isEmpty ? nil : hover)
            .background {
                if let presenter, !jobs.isEmpty {
                    BackgroundCardAnchor(source: source, presenter: presenter, hover: hover,
                                         activate: activate, commands: commands)
                }
            }
            .overlay(alignment: .topTrailing) {
                // ImageRenderer cannot host a native panel: standalone debug fixtures draw the
                // same content directly. Real sidebar presentation is exclusively the presenter.
                #if DEBUG
                if presenter == nil, hover.isOpen, !jobs.isEmpty {
                    BackgroundCardView(card: BackgroundCard(jobs: jobs))
                        .onHover { hover.card($0) }
                        .onDisappear { hover.card(false) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(EdgeInsets(top: -scale(Space.base), leading: -scale(Space.base), bottom: -scale(Space.base),
                                            trailing: SidebarRowLayout.trailingSlot(scale) + scale(Space.tight)))
                }
                #endif
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

/// The signal card's hover and anchor, as `BackgroundCardOverlay` holds the background card's.
private struct SignalCardOverlay: ViewModifier {
    let card: (() -> SignalCard?)?
    let source: RowSelection
    let activate: () -> Void
    let commands: [[RowCommand]]
    @Environment(\.backgroundCardPresenter) private var presenter
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.seededHover) private var seededHover
    #endif
    @State private var own = BackgroundCardHover()

    private var hover: BackgroundCardHover {
        #if DEBUG
        if let hover = seededHover?.signalCard { return hover }
        #endif
        return own
    }

    func body(content: Content) -> some View {
        content
            .environment(\.signalCardHover, card == nil ? nil : hover)
            .background {
                if let presenter, card != nil {
                    BackgroundCardAnchor(source: source, presenter: presenter, hover: hover,
                                         activate: activate, commands: commands, kind: .signal)
                }
            }
            .overlay(alignment: .topLeading) {
                // As the background card's: standalone debug fixtures draw the card here, after the avatar, from the
                // row's top to the pill's trailing edge.
                #if DEBUG
                if presenter == nil, hover.isOpen, let card {
                    SignalCardFallback(card: card, hover: hover)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(EdgeInsets(top: -scale(Space.base),
                                            leading: AvatarGroupView.columnWidth(scale) + scale(Space.tight),
                                            bottom: -scale(Space.base), trailing: -SidebarRowLayout.trailingInset(scale)))
                }
                #endif
            }
    }
}

#if DEBUG
/// Reads the card only while it is open, so a row with a closed card observes nothing of it.
private struct SignalCardFallback: View {
    let card: () -> SignalCard?
    let hover: BackgroundCardHover

    var body: some View {
        if let card = card() {
            SignalCardView(card: card)
                .onHover { hover.card($0) }
                .onDisappear { hover.card(false) }
        }
    }
}
#endif

private struct OpensSignalCard: ViewModifier {
    let square: CGFloat
    @Environment(\.signalCardHover) private var hover

    func body(content: Content) -> some View {
        content.frame(width: square, height: square).contentShape(Rectangle()).onHover { hover?.mark($0) }
    }
}
