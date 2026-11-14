import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// The Operator's summary on the sheet's Tasks tab (14 Nov 2026; first on a tab of its own, option 3A, 21 Oct 2026): under a
/// `BoardHeading`, the summary the Operator wrote, its paragraphs in `Typography.body` and `Palette.text`, `Space.gap`
/// apart and selectable, with `Written by the Operator at 16:05` under it in muted `Typography.help`; while there is
/// none, why, in the same muted line. Once the broadcast's goal was checked, how it went, `Goal not met`, in
/// `Typography.caption` and `Palette.text`. Drawn once the broadcast reached its summary (`RunSummary.notYet` draws
/// nothing: the sheet leaves it out).
struct BroadcastSummaryView: View {
    /// Which link just copied: Copy All, or a snag's Copy, by the snag's key.
    enum CopyTarget: Equatable { case all, snag(String) }

    let summary: RunSummary
    let goalOutcome: GoalOutcome?
    @Environment(\.footerClock) private var clock

    static let title = "Summary"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            BoardHeading(title: Self.title)
            if case .written(let text, let at) = summary {
                VStack(alignment: .leading, spacing: Space.gap) {
                    ForEach(Array(Self.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).font(Typography.body).foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                Text(Self.byline(at: at, calendar: clock?.calendar ?? .current)).font(Typography.help).foregroundStyle(Palette.muted)
            } else if let placeholder = Self.placeholder(for: summary) {
                Text(placeholder).font(Typography.help).foregroundStyle(Palette.muted)
            }
            if let goalOutcome { Text(Self.goal(goalOutcome)).font(Typography.caption).foregroundStyle(Palette.text) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a snag's item says nowhere on screen, its tooltip and VoiceOver value: what AiTerm showed, and how the
    /// Operator got unstuck.
    static func details(of snag: OperatorSnag) -> String {
        "AiTerm showed: \(snag.showed)\nThe Operator: \(snag.workaround)"
    }

    static let copyHelp = "Copy a complete Markdown fix task for AiTerm"
    static let copyAllHelp = "Copy every one as a complete Markdown fix task for AiTerm"
    static let copyAllLabel = "Copy All, every one as a complete Markdown fix task for AiTerm"
    static func copyLabel(of snag: OperatorSnag) -> String { "Copy “\(snag.title)” as a complete Markdown fix task for AiTerm" }
    /// What a link reads once it copied, and VoiceOver announces.
    static let copied = "Copied"
    static let copiedFor: Duration = .seconds(2)

    /// The summary's paragraphs: its text split at each blank line, a paragraph's own line breaks kept.
    static func paragraphs(_ text: String) -> [String] {
        var paragraphs: [String] = [], lines: [Substring] = []
        func close() {
            if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy(\.isWhitespace) { close() } else { lines.append(line) }
        }
        close()
        return paragraphs
    }

    /// How the goal went, as a line of its own: `Goal not met`.
    static func goal(_ outcome: GoalOutcome) -> String { outcome.words.capitalizingFirst }

    /// `Written by the Operator at 16:05`.
    static func byline(at date: Date, calendar: Calendar) -> String {
        "Written by the Operator at \(BroadcastActivityView.timeText(at: date, calendar: calendar))"
    }

    /// What the section says while it has no summary to show: the Operator still writing it, never writing it, or the
    /// broadcast ended before it finished. Nil once there is one, or before the broadcast reached it.
    static func placeholder(for summary: RunSummary) -> String? {
        switch summary {
        case .writing: "The Operator is writing its summary."
        case .notComing: "The Operator didn’t write a summary."
        case .endedEarly: "Ended before it finished. The Operator didn’t write a summary."
        case .notYet, .written: nil
        }
    }
}

/// Left for you on the Tasks tab, from its first item, during the run too: a `BoardHeading` with its count over each
/// item in `Typography.caption`, one line as `leave_for_you` wrote it, selectable.
struct LeftForYouList: View {
    let items: [String]

    static let title = "Left for you"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            BoardHeading(title: Self.title, count: items.count)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item).font(Typography.caption).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Worked around in AiTerm, the Tasks tab's last section, only when the Operator reported a snag (option 2B, 21 Oct
/// 2026): each item its title in `Typography.caption` and `Palette.text`, what was true under it in muted
/// `Typography.help`, then Copy as a link in `Typography.help` and `Palette.link`, `Space.hairline` apart; with two or
/// more, Copy All a link at the heading's trailing edge. A link copies its fix task (`BroadcastBoard.fixTask`,
/// `copyAll`) and reads Copied for 2 s, which VoiceOver announces.
struct WorkedAroundList: View {
    typealias CopyTarget = BroadcastSummaryView.CopyTarget

    let snags: [OperatorSnag]
    /// A snag's Copy text: the board's `fixTask`.
    let fixTask: (OperatorSnag) -> String
    /// Copy All's text; nil leaves it out.
    let copyAll: String?
    @State private var justCopied: (target: CopyTarget, id: UUID)? = nil

    static let title = "Worked around in AiTerm"

    init(board: BroadcastBoard) {
        snags = board.snags; fixTask = board.fixTask; copyAll = board.copyAll
    }

    /// The heading with Copy All beside it, not in it: `BoardHeading` hides its children from VoiceOver.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            HStack(spacing: Space.base) {
                BoardHeading(title: Self.title, count: snags.count)
                Spacer(minLength: 0)
                if let copyAll {
                    copyLink(.all, text: copyAll, help: BroadcastSummaryView.copyAllHelp, label: BroadcastSummaryView.copyAllLabel)
                }
            }
            ForEach(snags, id: \.key) { snag in
                VStack(alignment: .leading, spacing: Space.hairline) {
                    VStack(alignment: .leading, spacing: Space.hairline) {
                        Text(snag.title).font(Typography.caption).foregroundStyle(Palette.text)
                        Text(snag.actual).font(Typography.help).foregroundStyle(Palette.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(BroadcastSummaryView.details(of: snag))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(BroadcastSummaryView.details(of: snag))
                    copyLink(.snag(snag.key), text: fixTask(snag), help: BroadcastSummaryView.copyHelp,
                             label: BroadcastSummaryView.copyLabel(of: snag))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A link reads Copied for `copiedFor`; another copy meanwhile starts the wait over.
        .task(id: justCopied?.id) {
            guard justCopied != nil, (try? await Task.sleep(for: BroadcastSummaryView.copiedFor)) != nil else { return }
            justCopied = nil
        }
    }

    /// Copy, or Copy All: a link that puts `text` on the clipboard and reads Copied for `copiedFor`.
    private func copyLink(_ target: CopyTarget, text: String, help: String, label: String) -> some View {
        Button(justCopied?.target == target ? BroadcastSummaryView.copied : (target == .all ? "Copy All" : "Copy")) { copy(text, as: target) }
            .buttonStyle(.link).font(Typography.help)
            .help(help).accessibilityLabel(label)
    }

    private func copy(_ text: String, as target: CopyTarget) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = (target, UUID())
        AccessibilityNotification.Announcement(BroadcastSummaryView.copied).post()
    }
}
