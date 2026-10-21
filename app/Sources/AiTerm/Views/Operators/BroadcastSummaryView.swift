import SwiftUI
import AiTermUI
import AiTermCore

/// The Operator sheet's Summary (option 3A, 21 Oct 2026): the summary the Operator wrote, its paragraphs in
/// `Typography.body` and `Palette.text`, `Space.gap` apart and selectable, with `Written by the Operator at 16:05`
/// under it in muted `Typography.help`; while there is none, why, in the same muted line. Then, only when
/// something is, Left for you: a `BoardHeading` with its count over each item in `Typography.caption`, one line
/// as `leave_for_you` wrote it.
struct BroadcastSummaryView: View {
    let summary: RunSummary
    let leftForYou: [String]
    @Environment(\.footerClock) private var clock

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            if case .written(let text, let at) = summary {
                VStack(alignment: .leading, spacing: Space.base) {
                    VStack(alignment: .leading, spacing: Space.gap) {
                        ForEach(Array(Self.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph).font(Typography.body).foregroundStyle(Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                    Text(Self.byline(at: at, calendar: clock?.calendar ?? .current)).font(Typography.help).foregroundStyle(Palette.muted)
                }
            } else if let placeholder = Self.placeholder(for: summary) {
                Text(placeholder).font(Typography.help).foregroundStyle(Palette.muted)
            }
            if !leftForYou.isEmpty {
                VStack(alignment: .leading, spacing: Space.base) {
                    BoardHeading(title: "Left for you", count: leftForYou.count)
                    ForEach(Array(leftForYou.enumerated()), id: \.offset) { _, item in
                        Text(item).font(Typography.caption).foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    /// `Written by the Operator at 16:05`.
    static func byline(at date: Date, calendar: Calendar) -> String {
        "Written by the Operator at \(BroadcastActivityView.timeText(at: date, calendar: calendar))"
    }

    /// What the tab says while it has no summary to show: the Operator still writing it, never writing it, or the
    /// broadcast ended before it finished. Nil once there is one, or before the tab can be chosen.
    static func placeholder(for summary: RunSummary) -> String? {
        switch summary {
        case .writing: "The Operator is writing its summary."
        case .notComing: "The Operator didn’t write a summary."
        case .endedEarly: "Ended before it finished. The Operator didn’t write a summary."
        case .notYet, .written: nil
        }
    }
}
