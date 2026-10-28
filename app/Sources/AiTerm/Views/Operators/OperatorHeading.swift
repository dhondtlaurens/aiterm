import SwiftUI
import AiTermUI
import AiTermCore

/// `OPERATOR`, above `PROJECTS` (spec §3, §13; 28 Oct 2026). With no broadcast it is a `SidebarHeading` and its "+",
/// an `AddMenu` with New Broadcast…, the one way to start one. Once one exists, one at a time, the heading carries
/// what the broadcast's header row did: its progress `Space.gap` after the word in `Typography.monoChip`
/// (`paused · 2 of 8` while paused), and the board button in the "+"'s slot. The word now and then decodes into
/// another (`OperatorTitle`). The broadcast's menu (Open Board, Rename…, Pause or Resume, End Broadcast…) is its
/// context menu, and its lead row's (`OperatorRowView`); its tooltip is the broadcast's projects and status line.
///
/// While a broadcast exists, the Operator's section and the projects fold into each other, one open at a time,
/// kept with the workspace (`AppState.foldedRuns`): a click on either heading switches. Each heading has the
/// disclosure chevron a macOS sidebar section has (`SectionFoldChevron`), shown folded and, open, under the
/// pointer, and folded it says what needs you in its section once, as an amber `StatusCountChips` count, whose
/// click opens the section at the first row that needs you.
struct OperatorHeading: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    @State private var hovering = false

    /// The broadcast's glyph, where a broadcast is drawn as a project would be: the Shelf's ended broadcasts.
    static let glyph = "dot.radiowaves.left.and.right"

    /// Whether the heading offers New Broadcast…: only while there is no broadcast.
    static func offersNewBroadcast(_ broadcast: BroadcastSection?) -> Bool { broadcast == nil }

    /// Whether the word decodes now and then: while the broadcast runs, never while it is paused or done, nor while
    /// something in it needs you, which the heading's chip or its rows say then.
    static func decodes(_ broadcast: BroadcastSection) -> Bool {
        !broadcast.header.isPaused && !broadcast.header.isDone && !broadcast.needsAttention
    }

    var body: some View {
        let broadcast = controller.rows.broadcast
        HStack(spacing: scale(Space.base)) {
            if let broadcast {
                running(broadcast)
            } else {
                SidebarHeading("Operator")
                Spacer()
                AddMenu(help: "New broadcast", enabled: controller.canChangeWorkspace) {
                    OperatorMenuButtons(items: OperatorMenus.headingPlus) { _ in controller.presentNewBroadcast() }
                }
            }
        }
        // `PROJECTS`' anatomy (`SidebarHeader`), so the two headings line up with and without the "+".
        .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private func running(_ broadcast: BroadcastSection) -> some View {
        let header = broadcast.header, folds = controller.canChangeWorkspace
        // Only the label folds; the chip and the board button keep their own clicks.
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.gap)) {
                OperatorTitle(decodes: Self.decodes(broadcast), hovering: hovering)
                if let progress = header.headerProgress { HeaderProgress(text: progress) }
            }
            Spacer(minLength: scale(Space.tight))
            if broadcast.folded, !broadcast.attention.isEmpty {
                Button { controller.openAttention(of: broadcast.id) } label: { StatusCountChips(counts: broadcast.attention) }
                    .buttonStyle(.plain)
            }
            SectionFoldChevron(folded: broadcast.folded, hovering: hovering)
        }
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { controller.toggleFolded(run: broadcast.id) }, including: folds ? .all : .subviews)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Operator")
        .accessibilityValue(Self.spoken(broadcast))
        .accessibilityAddTraits(folds ? .isButton : [])
        .modifier(DefaultAccessibilityAction(enabled: folds) { controller.toggleFolded(run: broadcast.id) })
        // Open Board, then the menu's other items, as named actions.
        .accessibilityActions {
            ForEach(Self.voiceOverActions(header, canChangeWorkspace: controller.canChangeWorkspace), id: \.self) { item in
                Button(item.actionTitle) { controller.perform(item, onBroadcast: header.id) }
            }
        }
        .help(Self.help(header))
        .contextMenu { BroadcastMenu(runId: header.id, controller: controller) }
        BoardButton { controller.openBoard(broadcast.id) }
    }

    /// Whether a menu item can be chosen: Open Board changes nothing, so a locked workspace greys only the rest.
    static func enabled(_ item: OperatorMenuItem, canChangeWorkspace: Bool) -> Bool {
        item == .openBoard || canChangeWorkspace
    }

    /// What VoiceOver offers beside the fold: the menu's items it can choose now, Open Board first. An action
    /// cannot be greyed, only left out.
    static func voiceOverActions(_ row: BroadcastRow, canChangeWorkspace: Bool) -> [OperatorMenuItem] {
        OperatorMenus.broadcast(row).filter { $0 != .separator && enabled($0, canChangeWorkspace: canChangeWorkspace) }
    }

    /// The heading as VoiceOver reads it: the broadcast's name, its progress, every project, the whole status line,
    /// whether it is folded, and what needs you while it is.
    static func spoken(_ section: BroadcastSection) -> String {
        let row = section.header
        let attention = section.folded && !section.attention.isEmpty ? SidebarModel.statusCountsLabel(section.attention) : nil
        return [row.title, row.headerProgress, row.projectsHelp.isEmpty ? nil : row.projectsHelp, row.line.tooltip,
                section.folded ? "folded" : nil, attention]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The tooltip: its projects, then its whole status line.
    static func help(_ row: BroadcastRow) -> String {
        [row.projectsHelp, row.line.tooltip].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The broadcast's menu, the OPERATOR heading's and its lead row's: Open Board, Rename…, Pause or Resume Broadcast,
/// End Broadcast…, greyed but Open Board while the workspace is locked. It reads the broadcast itself, so the lead
/// row it is the menu of is not redrawn when its progress moves.
struct BroadcastMenu: View {
    let runId: UUID
    let controller: AppController

    var body: some View {
        if let header = controller.rows.broadcast?.header, header.id == runId {
            OperatorMenuButtons(items: OperatorMenus.broadcast(header),
                                enabled: { OperatorHeading.enabled($0, canChangeWorkspace: controller.canChangeWorkspace) }) {
                controller.perform($0, onBroadcast: runId)
            }
        }
    }
}

/// OPERATOR's word (28 Oct 2026). While `decodes`, it now and then decodes into one of `words`, the Operator's side
/// of the Matrix, the way Claude Code shows its spinner words: after 20–60 s, over `decodeDuration`, held `hold`,
/// then back. Under the pointer (`hovering`, the heading's) it decodes straight back to OPERATOR, over
/// `hoverDuration`, and changes no more until the pointer leaves. Drawn by `DecodeWordsView` in the heading's micro
/// face, tracking and muted ink, laid out by the word it decodes into; still under Reduce Motion and in the
/// snapshots. VoiceOver always reads "Operator".
struct OperatorTitle: View {
    let decodes: Bool
    let hovering: Bool
    @State private var word = Self.home
    @State private var duration = Self.decodeDuration
    @Environment(\.interfaceScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.stillSpinners) private var still
    #else
    private let still = false
    #endif

    static let home = "Operator"
    /// What it decodes into, in turn from a random start.
    static let words = ["Jacking in", "Tracing the call", "Rerouting", "Decrypting", "Loading the construct",
                        "Patching through", "Watching for agents", "Reading the code"]
    /// How long a decode takes each way, in seconds: slower than a line's (`OperatorBadge.decodeDuration`), since a
    /// whole new word arrives.
    static let decodeDuration = 0.9
    /// How long it takes back to OPERATOR under the pointer, in seconds.
    static let hoverDuration = 0.35
    /// How long a word stands before it decodes back, in seconds.
    static let hold = 3.0
    /// How long OPERATOR stands between two words, in seconds: irregular, so it never reads as a loop.
    static let rest: ClosedRange<Double> = 20...60

    var body: some View {
        let animates = !reduceMotion && !still
        let text = Text(word).font(Typography.micro).kerning(SidebarHeading.tracking).textCase(.uppercase).lineLimit(1)
        Group {
            if animates {
                // Laid out by the word, drawn by the decode's own view: a frame is never a SwiftUI update.
                text.opacity(0).overlay {
                    DecodeWords(text: word.uppercased(), font: Typography.micro.scaled(by: scale).nsFont, ink: Palette.muted,
                                duration: duration, kerning: SidebarHeading.tracking, decodesFirst: false)
                }
            } else {
                text.foregroundStyle(Palette.muted)
            }
        }
        .fixedSize()
        .onChange(of: hovering) { _, hovering in
            if hovering, word != Self.home { duration = Self.hoverDuration; word = Self.home }
        }
        .task(id: decodes && animates && !hovering) { await cycle(running: decodes && animates && !hovering) }
        .accessibilityLabel(Self.home)
    }

    /// Words, while it runs, until it is cancelled; OPERATOR again once it stops.
    private func cycle(running: Bool) async {
        guard running else {
            if word != Self.home { duration = Self.hoverDuration; word = Self.home }
            return
        }
        var next = Int.random(in: Self.words.indices)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: Self.rest)))
            guard !Task.isCancelled else { return }
            duration = Self.decodeDuration
            word = Self.words[next]
            next = (next + 1) % Self.words.count
            try? await Task.sleep(for: .seconds(Self.decodeDuration + Self.hold))
            guard !Task.isCancelled else { return }
            word = Self.home
            try? await Task.sleep(for: .seconds(Self.decodeDuration))
        }
    }
}

/// A section heading's disclosure chevron while the Operator's section and the projects fold into each other: a
/// macOS sidebar section's, in the trailing column before the heading's "+" or board button, shown folded and,
/// open, only under the pointer. The heading's click folds; the chevron is not a control of its own.
struct SectionFoldChevron: View {
    let folded: Bool
    let hovering: Bool
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HeaderChevron(collapsed: folded)
            .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
            .opacity(folded || hovering ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// The heading's progress, in `Typography.monoChip` and its surface's secondary ink: it keeps its width.
struct HeaderProgress: View {
    let text: String
    @Environment(\.surface) private var surface

    var body: some View {
        Text(verbatim: text).font(Typography.monoChip).foregroundStyle(surface.secondaryInk).lineLimit(1).fixedSize()
    }
}

/// The board button, in the trailing slot where no broadcast has its "+": the board's glyph, `rectangle.split.3x1`,
/// drawn as the "+" is, bare, in the surface's secondary ink.
struct BoardButton: View {
    let open: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        Button(action: open) {
            Image(systemName: "rectangle.split.3x1").font(Typography.label).foregroundStyle(surface.secondaryInk)
                .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(OperatorMenuItem.openBoard.title)
        .accessibilityLabel(OperatorMenuItem.openBoard.title)
    }
}
