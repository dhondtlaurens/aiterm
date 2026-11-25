import SwiftUI
import AiTermUI
import AiTermCore

/// The existing ordered work list, with native short descriptions when available. Raw commands
/// remain on each job for fallback/help; the visual and spoken descriptions use the same label.
/// Idle teammates (`BackgroundJob.idle`) are alive but run nothing: they follow the running work under their own
/// heading, and the count in the card's heading leaves them out.
struct BackgroundCard: Equatable {
    let jobs: [BackgroundJob]

    static let idleHeading = "Idle (can be messaged)"

    var running: [BackgroundJob] { jobs.filter { !$0.idle } }
    var idle: [BackgroundJob] { jobs.filter(\.idle) }

    var heading: String {
        switch running.count {
        case 0 where !idle.isEmpty: "Background work · none running"
        case 0, 1: "Background work"
        case let count: "Background work · \(count) jobs"
        }
    }

    /// One line of the card under its heading: a job, or the heading of the idle ones.
    enum Line: Equatable {
        case job(BackgroundJob)
        case idleHeading
    }

    /// The running jobs, then the idle ones under their heading.
    var lines: [Line] {
        running.map(Line.job) + (idle.isEmpty ? [] : [.idleHeading] + idle.map(Line.job))
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

    /// What each line is at a glance: a shell's command, an agent at work, an idle agent asleep until it is messaged, and
    /// anything else that follows a live signal and reports back (a monitor, a workflow, an MCP task). Not `eye`: on
    /// macOS that is the show/hide mark, a control rather than work.
    static func glyph(_ job: BackgroundJob) -> String {
        if job.idle { return "zzz" }
        switch job.kind {
        case .shell: return "apple.terminal"
        case .subagent: return "sparkle"
        case .monitor, .task: return "waveform.path.ecg"
        }
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

    /// SF Symbols can be wider than their point size. Allow a third more width for the terminal
    /// glyph; narrower symbols share the column. This allowance follows the mark, not the row gap.
    private static let glyphColumnWidth = Size.inlineMark * 4 / 3

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
            HelpText(card.heading, fixedVerticalSize: false).lineLimit(1)
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
        .padding(.vertical, scale(Space.base)).padding(.horizontal, scale(Space.gap))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.height(jobs: rows, scale: scale))
        .menuChrome(cornerRadius: scale(Self.cornerRadius))
        .surface(.sheet)
        .accessibilityHidden(true)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                Group {
                    switch line {
                    case .idleHeading:
                        Text(BackgroundCard.idleHeading).font(Typography.help)
                            .foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
                    case .job(let job):
                        HStack(alignment: .center, spacing: scale(Space.tight)) {
                            Icon(.symbol(BackgroundCard.glyph(job)), size: scale(Size.inlineMark), tint: Palette.muted)
                                .frame(width: scale(Self.glyphColumnWidth))
                            Text(job.label).font(job.isCommand ? Typography.mono : Typography.help)
                                .foregroundStyle(job.idle ? Palette.muted : Palette.text).lineLimit(1).truncationMode(.tail)
                                .help(job.kind == .shell && !job.isCommand ? job.text : "")
                        }
                    }
                }
                .frame(height: scale(Size.chip))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
