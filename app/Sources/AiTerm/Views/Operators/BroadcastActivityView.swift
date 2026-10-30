import SwiftUI
import AiTermUI
import AiTermCore

/// The Operator sheet's Activity (option 2A, 21 Oct 2026): every call the Operator made, newest first, under a
/// `SidebarHeading` for each day (`Today`, then the day). A row is the time in `Typography.mono` in a leading
/// column, the line in `Typography.caption` with the task's name in medium weight (muted for a call that only
/// read), and the task's key trailing in `Typography.monoChip`; a call that did not go through leads with its
/// `label`, and a reason sits under the line in `Typography.help`. A click opens the row in place, on
/// `Palette.rowHoverSolid`: the call itself, its tool, arguments and outcome in `Typography.mono` on
/// `Palette.surfaceRaised`, selectable. One row is open at a time; a second click closes it.
struct BroadcastActivityView: View {
    /// Newest first.
    let entries: [ActivityEntry]
    /// The broadcast's task titles by id, to set a line's task name in medium weight.
    var titles: [UUID: String] = [:]
    private var _openId = State<UUID?>(initialValue: nil)
    private var openId: UUID? { get { _openId.wrappedValue } nonmutating set { _openId.wrappedValue = newValue } }
    @Environment(\.footerClock) private var clock

    init(entries: [ActivityEntry], titles: [UUID: String] = [:], openId: UUID? = nil) {
        self.entries = entries; self.titles = titles
        _openId = State(initialValue: openId)
    }

    /// One day's run of entries, newest first.
    struct Day: Identifiable {
        /// The day's first instant.
        var start: Date
        var entries: [ActivityEntry]
        var id: Date { start }
    }

    var body: some View {
        let calendar = clock?.calendar ?? .current, now = clock?.now ?? Date()
        if entries.isEmpty {
            HelpText("Nothing recorded yet.", fixedVerticalSize: false)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.days(entries, calendar: calendar)) { day in
                    SidebarHeading(Self.dayTitle(day.start, now: now, calendar: calendar))
                        .frame(height: Size.menuRow)
                        .padding(.horizontal, Space.base)
                    ForEach(day.entries) { entry in
                        ActivityRow(entry: entry, title: entry.task.flatMap { titles[$0] }, time: Self.timeText(at: entry.at, calendar: calendar),
                                    isOpen: openId == entry.id) {
                            openId = openId == entry.id ? nil : entry.id
                        }
                    }
                }
            }
            // The rows' ground reaches `Space.base` past the content's margins; their text stays on them.
            .padding(.horizontal, -Space.base)
        }
    }

    /// `entries`, newest first, in runs of one calendar day.
    static func days(_ entries: [ActivityEntry], calendar: Calendar) -> [Day] {
        entries.reduce(into: []) { days, entry in
            let start = calendar.startOfDay(for: entry.at)
            if days.last?.start == start { days[days.count - 1].entries.append(entry) } else { days.append(Day(start: start, entries: [entry])) }
        }
    }

    /// A day's heading: `Today`, else the day (`10 Mar`), with the year once it is another year's.
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
                                     timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) { style = style.year() }
        return day.formatted(style)
    }

    /// A row's time: `14:35`, on the 24-hour clock whatever the locale.
    static func timeText(at date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// What a call that did not go through leads with; nil for one that did, or was answered from the first.
    static func label(for outcome: ActivityEntry.Outcome) -> String? {
        switch outcome {
        case .refused: "Refused"
        case .failed: "Failed"
        case .challenged: "Challenged"
        case .ok, .repeated: nil
        }
    }

    /// The call itself, as an open row shows it under its tool's name: its arguments as JSON, then how it went and
    /// what AiTerm answered.
    static func details(of entry: ActivityEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let arguments = (try? encoder.encode(entry.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let answer = entry.result.isEmpty ? entry.outcome.rawValue : "\(entry.outcome.rawValue) · \(entry.result)"
        return arguments + "\n→ " + answer
    }
}

/// One call on Activity: its line over its reason, and, open, the call itself under them.
private struct ActivityRow: View {
    let entry: ActivityEntry
    /// The task's title, when the broadcast still has it: the line's name for it is set in medium weight.
    let title: String?
    let time: String
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.gap) {
            Text(verbatim: time).font(Typography.mono).foregroundStyle(Palette.muted).fixedSize()
            VStack(alignment: .leading, spacing: Space.tight) {
                Button(action: toggle) { head }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(isOpen ? "Hides the call." : "Shows the call itself."))
                if isOpen { details }
            }
        }
        .padding(.vertical, Space.snug).padding(.horizontal, Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isOpen { RoundedRectangle(cornerRadius: Radius.control).fill(Palette.rowHoverSolid) }
        }
    }

    /// The line, the key trailing on its baseline, and the reason under them: the row's click.
    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.gap) {
                line.font(Typography.caption).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let key = entry.taskLabel {
                    Text(verbatim: key).font(Typography.monoChip).foregroundStyle(Palette.muted).fixedSize()
                }
            }
            if let reason = entry.reason {
                HelpText(reason, fixedVerticalSize: false).fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }

    /// `Refused · …` in amber, `Challenged · …` muted, then the line in its ink, the task's name in medium weight.
    private var line: Text {
        let ink = entry.isRead ? Palette.muted : Palette.text
        var text = Text(verbatim: "")
        if let label = BroadcastActivityView.label(for: entry.outcome) {
            let tone = entry.outcome == .challenged ? Palette.muted : Palette.amber
            text = Text("\(Text(verbatim: label).fontWeight(.medium).foregroundStyle(tone))\(Text(verbatim: " · ").foregroundStyle(ink))")
        }
        guard let title, !title.isEmpty, let range = entry.line.range(of: title) else {
            return Text("\(text)\(Text(verbatim: entry.line).foregroundStyle(ink))")
        }
        let before = Text(verbatim: String(entry.line[..<range.lowerBound])).foregroundStyle(ink)
        let name = Text(verbatim: title).fontWeight(.medium).foregroundStyle(ink)
        let after = Text(verbatim: String(entry.line[range.upperBound...])).foregroundStyle(ink)
        return Text("\(text)\(before)\(name)\(after)")
    }

    /// The tool's name, then its arguments and its outcome, selectable.
    private var details: some View {
        let rest = Text(verbatim: "\n" + BroadcastActivityView.details(of: entry)).foregroundStyle(Palette.muted)
        return Text("\(Text(verbatim: entry.tool).fontWeight(.medium).foregroundStyle(Palette.text))\(rest)")
            .font(Typography.mono)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.base).padding(.horizontal, Space.inset)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.surfaceRaised))
    }
}
