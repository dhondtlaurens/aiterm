import Foundation
import SwiftUI
import AiTermUI
import AiTermCore

/// What the card a task row's signals disc opens says (proposal “The two floating cards”, A, 26 Nov 2026): each signal
/// that ran the task, oldest first, with when; then the work going on now beside the row's own mark: the Operator's act
/// or its line's words on a task it holds, the worker's state on yours.
struct SignalCard: Equatable {
    struct Step: Equatable {
        /// The signal's live name, or its saved one marked removed.
        var name: String
        /// When it started running the task.
        var at: Date
        /// The signal that runs the task now or ran it last; the earlier ones are drawn in the muted ink.
        var isCurrent: Bool
    }
    struct Current: Equatable {
        var text: String
        /// The whole sentence behind the line, or why it waits: the line's tooltip.
        var help: String? = nil
    }

    var steps: [Step]
    var current: Current
    /// The row's trailing mark, which the work line wears so it reads as a state, not as another signal.
    var mark: TaskRowMark = .status(.idle)

    /// The card of `task`, drawn as `row`, in `state`; nil for a task no signal started.
    static func make(task: TaskItem, row: TaskRow, state: AppState) -> SignalCard? {
        let names = Dictionary(state.signals.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let earlier: [SignalStep], now: SignalStep
        if let record = task.signalTask {
            earlier = record.earlier ?? []
            now = SignalStep(signal: record.current.signal, name: record.current.configuration.name, at: record.startedAt)
        } else if let origin = task.signalOrigin {
            earlier = origin.earlier ?? []
            now = SignalStep(signal: origin.signal, name: origin.name, at: origin.startedAt)
        } else {
            return nil
        }
        func step(_ step: SignalStep, current: Bool) -> Step {
            Step(name: SidebarModel.signalName(step.signal, saved: step.name, names: names), at: step.at, isCurrent: current)
        }
        return SignalCard(steps: earlier.map { step($0, current: false) } + [step(now, current: true)],
                          current: current(task: task, row: row, state: state), mark: row.mark)
    }

    /// The work going on now. A task the Operator holds says its line, which is the Operator's act while it acts
    /// ("Operator answering its worker"). A task a signal started that is yours says what it waits for while its prompt
    /// is owed (why, when a read or the helper held it), "Done · kept" or "Done · archived" (with why the archive did not
    /// happen) once its Done was reached, else its status.
    private static func current(task: TaskItem, row: TaskRow, state: AppState) -> Current {
        if task.signalTask != nil {
            guard let line = row.operatorLine else { return Current(text: row.status.label) }
            // The card's lines start with a capital ("Paused", "Starting its worker"), but a Done trigger's own words
            // stay as written: they may be a query.
            let text = line.tooltip.hasPrefix(OperatorLine.doneTriggerTooltip) ? line.text : BackgroundCard.sentence(line.text)
            return Current(text: text, help: line.tooltip == line.text ? nil : line.tooltip)
        }
        guard let origin = task.signalOrigin else { return Current(text: row.status.label) }
        if origin.doneAt != nil {
            let archives = state.signal(id: origin.signal)?.finish.then == .archive && origin.thenNote == nil
            return Current(text: archives ? "Done · archived" : "Done · kept", help: origin.thenNote)
        }
        if origin.owed != nil {
            let held = state.signalSeen.first {
                $0.signal == origin.signal && $0.item.identity == origin.item.identity && $0.disposition == .skipped
            }?.reason
            return Current(text: task.windowId == nil ? "Waiting for your pause to open its window" : "Waiting for its worker to be idle",
                           help: held)
        }
        return Current(text: row.status.label)
    }

    /// When a signal started on the task, as its line says it: "14:05" today, "Mon 14:05" within the week before, else
    /// "18 Nov"; 24-hour local time on `calendar`.
    static func when(_ at: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: at), to: calendar.startOfDay(for: now)).day ?? 0
        formatter.dateFormat = days == 0 ? "HH:mm" : (1...6).contains(days) ? "EEE HH:mm" : "d MMM"
        return formatter.string(from: at)
    }
}

/// The signal card: one `Size.chip` line per signal that ran the task, oldest first, its name cut at the end and its time
/// never, the earlier ones muted; a `Hairline`; then the work going on now beside the row's mark, in the secondary ink,
/// cut at the end with its whole sentence as help. In the background-work card's chrome. A long chain keeps its latest
/// signals when the viewport is short.
struct SignalCardView: View {
    let card: SignalCard
    var visibleSteps = Int.max
    @Environment(\.interfaceScale) private var scale
    @Environment(\.footerClock) private var clock

    /// The card's height with `steps` signal lines over the rule and the work's line.
    static func height(steps: Int, scale: InterfaceScale) -> CGFloat {
        let steps = CGFloat(max(0, steps))
        return 2 * scale(Space.base) + steps * scale(Size.chip) + Hairline.thickness + scale(Size.chip) + (steps + 1) * scale(Space.tight)
    }

    /// How many of `total` steps fit in `availableHeight` over the rule and the work's line; none when not even one does.
    static func visibleSteps(total: Int, availableHeight: CGFloat, scale: InterfaceScale) -> Int {
        let room = availableHeight - height(steps: 0, scale: scale)
        let fits = max(0, Int(floor(room / (scale(Size.chip) + scale(Space.tight)))))
        return min(total, fits)
    }

    var body: some View {
        let steps = Array(card.steps.suffix(max(0, visibleSteps)))
        let now = clock?.now ?? Date(), calendar = clock?.calendar ?? .autoupdatingCurrent
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: scale(Space.tight)) {
                    Text(step.name).font(Typography.help).foregroundStyle(step.isCurrent ? Palette.text : Palette.muted)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: scale(Space.tight))
                    Text(SignalCard.when(step.at, now: now, calendar: calendar)).font(Typography.help.tabular)
                        .foregroundStyle(Palette.muted).lineLimit(1).fixedSize()
                }
                .frame(height: scale(Size.chip))
            }
            Hairline()
            HStack(spacing: scale(Space.base)) {
                TaskRowMarkView(mark: card.mark, size: scale(Size.statusMark))
                Text(card.current.text).font(Typography.help).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .help(card.current.help ?? card.current.text)
            }
            .frame(maxWidth: .infinity, minHeight: scale(Size.chip), maxHeight: scale(Size.chip), alignment: .leading)
        }
        .modifier(FloatingCardChrome(height: Self.height(steps: steps.count, scale: scale)))
    }
}
