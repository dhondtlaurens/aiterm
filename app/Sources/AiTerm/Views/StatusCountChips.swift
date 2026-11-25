import SwiftUI
import AiTermUI
import AiTermCore

/// The status counts a collapsed project header draws in place of the task rows it is hiding.
///
/// Same vocabulary as the rows themselves: `StatusMark`'s own glyph, at `Size.statusMarkSmall`, in
/// front of the number of tasks wearing it — a collapsed project should not need a second colour language to
/// say the same five things. The chips keep their intrinsic width, so the project name is what
/// gives way when the sidebar narrows, exactly as it does for the branch line's `+n`.
///
/// A folded OPERATOR heading leads with the Operator's own chip (`lead`): its most urgent state as a row's mark
/// draws it, and its unfinished tasks. A folded OPERATOR heading or project header ends with the finished chip: the
/// finished disc and how many tasks are really done, on the green wash, apart from done's blue.
///
/// With `open`, as on a folded OPERATOR or PROJECTS heading, each chip is its own button, named for its own count,
/// and its click is `open(target)`. Without, as on a project header, the strip is one label.
struct StatusCountChips: View {
    let counts: [StatusCount]
    var lead: OperatorChip? = nil
    var finished = 0
    var open: ((ChipTarget) -> Void)? = nil
    @Environment(\.interfaceScale) private var scale

    private var chips: [Chip] {
        (lead.map { [Chip.operatorState($0)] } ?? []) + counts.map(Chip.status) + (finished > 0 ? [.finished(finished)] : [])
    }

    var body: some View {
        let chips = chips
        if !chips.isEmpty {
            if let open {
                HStack(spacing: scale(Space.tight)) {
                    ForEach(chips, id: \.target) { chip in
                        Button { open(chip.target) } label: { ChipView(chip: chip) }
                            .buttonStyle(.plain)
                            .help(chip.label)
                            .accessibilityLabel(chip.label)
                    }
                }
                .fixedSize()
            } else {
                let label = chips.map(\.label).joined(separator: ", ")
                HStack(spacing: scale(Space.tight)) {
                    ForEach(chips, id: \.target) { ChipView(chip: $0) }
                }
                .fixedSize()
                .help(label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
            }
        }
    }
}

/// One chip's content: a status's count, the Operator's own, or the finished tasks'.
private enum Chip {
    case status(StatusCount), operatorState(OperatorChip), finished(Int)

    var target: ChipTarget {
        switch self {
        case .status(let count): .status(count.status)
        case .operatorState: .operatorState
        case .finished: .finished
        }
    }

    var label: String {
        switch self {
        case .status(let count): SidebarModel.statusCountsLabel([count])
        case .operatorState(let chip): chip.label
        case .finished(let n): "\(n) finished"
        }
    }

    /// The status family it is drawn in: a needs-you Operator chip is an attention chip, a paused one quiet.
    var family: TaskStatus? {
        switch self {
        case .status(let count): count.status
        case .operatorState(let chip):
            if case .status(let status) = chip.mark { status } else { .idle }
        case .finished: nil
        }
    }
}

/// One chip. The wash carries the status, the ink is a lighter tone of it so the digit stays
/// legible at 10 pt, and the washes are the canvas' own values.
private struct ChipView: View {
    let chip: Chip
    @Environment(\.interfaceScale) private var scale

    private var ink: Color {
        switch chip.family {
        // Waiting is quiet: nothing of it runs, so the muted ink of idle, beside its dashed ring.
        case .idle, .waiting: return Palette.muted
        // Brighter than idle: at 8 pt a spinner arc and a hollow ring are nearly the same shape,
        // so the ink is what separates "running" from "waiting for nobody".
        // A row in the background is counted with working (`SidebarModel.statusCounts`).
        case .working, .background: return Palette.text
        case .needsInput: return Palette.badgeAmber
        case .done: return Palette.link
        case nil: return Palette.green
        }
    }

    /// The chip's fill and edge, one `Palette` pair per status family.
    private var wash: (fill: Color, stroke: Color) {
        switch chip.family {
        case .idle, .working, .background, .waiting: return (Palette.statusChipQuietFill, Palette.statusChipQuietStroke)
        case .needsInput: return (Palette.statusChipAttentionFill, Palette.statusChipAttentionStroke)
        case .done: return (Palette.statusChipDoneFill, Palette.statusChipDoneStroke)
        case nil: return (Palette.statusChipFinishedFill, Palette.statusChipFinishedStroke)
        }
    }

    var body: some View {
        HStack(spacing: scale(Space.tight)) {
            mark
            if let number { Text("\(number)").font(Typography.chip.tabular).foregroundStyle(ink) }
        }
        .padding(.horizontal, scale(Space.tight))
        .frame(height: scale(Size.chip))
        .chipChrome(fill: wash.fill, stroke: wash.stroke)
    }

    @ViewBuilder private var mark: some View {
        let size = scale(Size.statusMarkSmall)
        switch chip {
        case .status(let count): StatusMark(status: count.status, size: size)
        case .operatorState(let operatorChip): TaskRowMarkView(mark: operatorChip.mark, size: size)
        case .finished: SettledMark(.finished, size: size)
        }
    }

    private var number: Int? {
        switch chip {
        case .status(let count): count.count
        case .operatorState(let operatorChip): operatorChip.tasks > 0 ? operatorChip.tasks : nil
        case .finished(let n): n
        }
    }
}
