import SwiftUI
import AiTermUI
import AiTermCore

/// New Broadcast… (spec §3.1, the design page's `p-op-new`): Broadcast · Prompt · Review · Done on the
/// shipped `StepBar`, drawn from the creation frame's parts as New Task is (`CreationSteps.broadcast`):
/// Continue on ⌘↩ through step 3, Back from step 2, Cancel on step 1, and Start Broadcast on step 4,
/// whose failure is the footer's `Notice` (`CreationFooter`). Step 1 is an optional name, the Jira
/// projects and the projects, which it needs one of; Prompt, Review and Done are the same
/// `PromptStep` editor, whose `/` lists both agents' skills. The `DestinationLine` ends steps 1 and 4.
/// There is no command preview: the Operator chooses each task's agent.
struct NewBroadcastSheet: View {
    @Bindable var model: NewBroadcastModel
    @Environment(\.dismiss) private var dismiss
    private var _step = State(initialValue: 1)
    private var step: Int { get { _step.wrappedValue } nonmutating set { _step.wrappedValue = newValue } }
    private var _jiraOpen = State(initialValue: false)
    private var _projectsOpen = State(initialValue: false)
    /// A Jira project result's key column, as the Jira projects sheet has it: a ticket key without its number.
    private static let jiraKeyWidth: CGFloat = 64
    private static let steps = CreationSteps.broadcast

    init(model: NewBroadcastModel) { _model = Bindable(wrappedValue: model) }

    /// Step 1's lists, in the order ⎋ closes them.
    private var pickers: [Binding<Bool>] { [_jiraOpen.projectedValue, _projectsOpen.projectedValue] }

    var body: some View {
        SheetLayout(title: NewBroadcastModel.title, height: Sheet.height, onBackgroundTap: closeLists) {
            StepBar(step: step, names: NewBroadcastModel.stepNames)
        } content: {
            FrontToBackStack(spacing: Space.block) {
                content
                if Self.steps.showsDestination(onStep: step) { DestinationLine(NewBroadcastModel.destination) }
            }
        } footer: {
            // What Start waits for is said on every step, so it can be put right before the prompt is written.
            CreationFooter(step: step, steps: Self.steps, error: model.error, availableAgents: [],
                           createLabel: NewBroadcastModel.createLabel, creating: model.starting,
                           canAdvance: model.canAdvance(step: step), closeList: closeOpenList,
                           back: back, advance: advance, recover: {},
                           waiting: (BroadcastReadiness.title, model.notReadyLines))
        }
        // Both agents' skills, from the home and the picked projects: read again as the picks change.
        .task(id: model.projects.map(\.id)) { await model.loadCompletions() }
        .task { await model.loadJiraProjects() }
        // The agents' cards and the delivery check's file, read for as long as the sheet is open.
        .task { await model.checkReadiness() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: broadcastStep
        case 2: editor(text: $model.prompt, label: "Prompt", placeholder: nil, help: NewBroadcastModel.promptHelp).id(2)
        case 3: editor(text: $model.review, label: "Review", placeholder: NewBroadcastModel.reviewPlaceholder, help: model.reviewHelp).id(3)
        default: editor(text: $model.done, label: "Done", placeholder: NewBroadcastModel.donePlaceholder, help: model.doneHelp).id(4)
        }
    }

    /// Claude's form for what `/` writes: the Operator reads every field, and a Codex task is told
    /// of its skill in the brief the Operator writes for it.
    private func editor(text: Binding<String>, label: String, placeholder: String?, help: String) -> some View {
        PromptStep(text: text, agent: .claude, completions: model.completions, label: label, placeholder: placeholder, help: help)
    }

    // -- step 1: broadcast ----------------------------------------------------------

    private var broadcastStep: some View {
        FrontToBackStack(spacing: Space.block) {
            FormField("Name") {
                Input(placeholder: NewBroadcastModel.namePlaceholder, text: $model.name)
                HelpText(NewBroadcastModel.nameHelp)
            }
            FormField("Jira projects") {
                ChipsPicker(placeholder: NewBroadcastModel.jiraProjectsPlaceholder, picks: model.jiraProjects,
                            open: _jiraOpen.projectedValue, matches: model.matchingJiraProjects(query:),
                            mark: { _ in .brand(Palette.jira) }, label: { "\($0.key) · \($0.name)" },
                            row: { PickerResultRow(mark: .brand(Palette.jira), key: $0.key, keyWidth: Self.jiraKeyWidth, title: $0.name, detail: nil) },
                            onPick: { model.add(jiraProject: $0) }, onRemove: { model.remove(jiraProject: $0) })
                HelpText(NewBroadcastModel.jiraProjectsHelp)
                jiraStatus
            }
            FormField("Projects") {
                ChipsPicker(placeholder: NewBroadcastModel.projectsPlaceholder, picks: model.projects,
                            open: _projectsOpen.projectedValue, matches: model.matchingProjects(query:),
                            mark: { ProviderIcon.source(of: $0.provider) }, label: \.name,
                            row: { ProjectResultRow(project: $0) },
                            onPick: { model.add(project: $0) }, onRemove: { model.remove(project: $0) })
                HelpText(NewBroadcastModel.projectsHelp)
            }
        }
    }

    /// Loading, none found, or Jira not reached, under the help, as the Jira projects sheet says them.
    @ViewBuilder private var jiraStatus: some View {
        if let status = model.jiraStatus {
            if model.jiraLoad == .loading {
                HStack(spacing: Space.snug) {
                    ProgressView().controlSize(.small)
                    HelpText(status)
                }
            } else {
                HelpText(status)
            }
        }
    }

    // -- the footer's moves ---------------------------------------------------------

    private func closeLists() { for picker in pickers { picker.wrappedValue = false } }

    /// The list ⎋ closes, if one is open where it can be seen: step 1's pickers, or the completion
    /// popup on Prompt, Review and Done. The footer's hidden ⎋ button hears the key first.
    private func closeOpenList() -> Bool {
        if Self.steps.hasPrompt(onStep: step), model.completions.isOpen {
            model.completions.close()
            return true
        }
        guard step == 1, let open = pickers.first(where: { $0.wrappedValue }) else { return false }
        open.wrappedValue = false
        return true
    }

    private func back() { guard !model.starting else { return }; if step == 1 { dismiss.afterThisEvent() } else { step -= 1 } }

    /// Continue, or Start Broadcast on the last step; `canAdvance` gates both the button and ⌘↩.
    private func advance() {
        guard model.canAdvance(step: step) else { return }
        if Self.steps.creates(onStep: step) { start(); return }
        closeLists()
        model.completions.close()
        step += 1
    }

    /// Already past the button's event by the time it dismisses: the start is awaited first.
    private func start() { Task { if await model.start() != nil { dismiss() } } }
}

#if DEBUG
extension NewBroadcastSheet {
    /// The sheet already on `step`: what only clicks reach in the app, for the snapshots and tests.
    func seeded(step: Int) -> Self {
        var sheet = self
        sheet._step = State(initialValue: step)
        return sheet
    }
}
#endif

/// A project in New Broadcast's project list: its host's mark and its name, inked for the ground its
/// row declares, as `PickerResultRow` is.
struct ProjectResultRow: View {
    let project: Project
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: Space.base) {
            Icon(ProviderIcon.source(of: project.provider), size: Size.pickerRowLogo, tint: PickerResultRow.logoTint(on: surface))
            Text(project.name).font(Typography.caption).foregroundStyle(surface.ink).lineLimit(1)
            Spacer(minLength: Space.snug)
        }
    }
}

/// One pick in a `ChipsPicker`: the service's mark, its name in `Typography.caption`, and the ✕ that
/// removes it, on the badge wash at `Radius.chip`, `lineHeight` tall (the design's lane chip).
struct PickChip: View {
    let mark: IconSource
    let label: String
    let remove: () -> Void

    /// `Size.chip`, and room for the caption: the chip's height, and the search field's beside it.
    static var lineHeight: CGFloat { Size.chip + Space.tight }

    var body: some View {
        let removeHelp = "Remove \(label)"
        return HStack(spacing: Space.tight) {
            Icon(mark, size: Size.pickerRowLogo)
            // The label gives way when the chip is narrower than it wants to be: the mark and the ✕ keep their size.
            Text(label).font(Typography.caption).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
            Button(action: remove) {
                Image(systemName: "xmark").font(Typography.micro).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain).help(removeHelp).accessibilityLabel(removeHelp)
        }
        .padding(.horizontal, Space.snug).frame(height: Self.lineHeight)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Palette.badge))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A field of several picks: each a `PickChip`, then a search field after them that adds one more,
/// its results hanging under the field in a `DropdownList` as `SearchPicker`'s do, keyed by
/// `DropdownKeys`. The field wraps onto more lines as the chips fill it (`ChipFlow`). Focusing it, or
/// typing, opens the list; a pick joins the chips and the field stays for the next one. The caller
/// keeps `open`, since the sheet closes the list from outside: ⎋, and a click past it.
struct ChipsPicker<Item: Identifiable, Row: View>: View {
    let placeholder: String
    let picks: [Item]
    @Binding var open: Bool
    let matches: (String) -> [Item]
    let mark: (Item) -> IconSource
    let label: (Item) -> String
    let row: (Item) -> Row
    let onPick: (Item) -> Void
    let onRemove: (Item) -> Void
    private var _query = State(initialValue: "")
    private var query: String { get { _query.wrappedValue } nonmutating set { _query.wrappedValue = newValue } }
    private var _index = State(initialValue: 0)
    private var index: Int { get { _index.wrappedValue } nonmutating set { _index.wrappedValue = newValue } }
    private var _focused = State(initialValue: false)
    private var focused: Bool { get { _focused.wrappedValue } nonmutating set { _focused.wrappedValue = newValue } }

    /// At most six rows, as `SearchPicker` shows.
    static var visibleLimit: Int { 6 }

    init(placeholder: String, picks: [Item], open: Binding<Bool>, matches: @escaping (String) -> [Item],
         mark: @escaping (Item) -> IconSource, label: @escaping (Item) -> String, @ViewBuilder row: @escaping (Item) -> Row,
         onPick: @escaping (Item) -> Void, onRemove: @escaping (Item) -> Void) {
        self.placeholder = placeholder; self.picks = picks; self._open = open; self.matches = matches
        self.mark = mark; self.label = label; self.row = row; self.onPick = onPick; self.onRemove = onRemove
    }

    private var visible: [Item] { Array(matches(query).prefix(Self.visibleLimit)) }

    var body: some View {
        ChipFlow(spacing: Space.tight) {
            ForEach(picks) { item in PickChip(mark: mark(item), label: label(item)) { onRemove(item) } }
            SearchField(placeholder: placeholder,
                        text: Binding(get: { query }, set: { query = $0; open = true; index = 0 }),
                        focused: _focused.projectedValue, onCommand: command)
                .frame(height: PickChip.lineHeight)
        }
        .padding(.horizontal, Space.inset).padding(.vertical, Space.tight)
        .frame(maxWidth: .infinity, minHeight: Size.control, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focused = true; open = true }
        .fieldBox(focused: focused)
        // Under the field, `Space.tight` below it, however many lines the chips take.
        .overlay(alignment: .bottomLeading) {
            results.alignmentGuide(.bottom) { $0[.top] - Space.tight }
        }
        .onChange(of: focused) { _, focused in if focused { open = true } }
        .onChange(of: open, initial: true) { _, open in if open { index = 0 } }
    }

    @ViewBuilder private var results: some View {
        let shown = visible
        if open, !shown.isEmpty {
            DropdownList(items: shown, index: _index.projectedValue, onPick: pick, row: row)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func command(_ selector: Selector) -> Bool {
        let shown = visible
        switch DropdownKeys.handle(selector: selector, count: shown.count, index: index, open: open) {
        case .moved(let i): index = i; return true
        case .accepted(let i): pick(shown[i]); return true
        case .closed: open = false; index = 0; return true
        case .unhandled: return false
        }
    }

    private func pick(_ item: Item) {
        onPick(item)
        query = ""
        open = false
        index = 0
    }
}

/// Lays chips out in lines `spacing` apart, wrapping as a line fills, a chip never wider than a line; the last subview, the search
/// field, takes the rest of its line, and starts a line of its own when less than `fieldMinWidth` is left.
struct ChipFlow: Layout {
    let spacing: CGFloat
    /// Room for the placeholder ("Add a Jira project") beside the chips before the field wraps.
    static let fieldMinWidth: CGFloat = 140

    private struct Placement { var origin: CGPoint, size: CGSize }

    private func arrange(_ subviews: Subviews, width proposed: CGFloat?) -> (placements: [Placement], size: CGSize) {
        let width = proposed ?? .infinity
        var placements: [Placement] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        var line: [Int] = []
        func endLine() {
            for i in line { placements[i].origin.y = y + (lineHeight - placements[i].size.height) / 2 }
            y += lineHeight + spacing; x = 0; lineHeight = 0; line = []
        }
        for (i, subview) in subviews.enumerated() {
            let isField = i == subviews.count - 1
            var size: CGSize
            if isField {
                if x > 0, x + Self.fieldMinWidth > width { endLine() }
                let rest = width.isFinite ? width - x : Self.fieldMinWidth
                size = subview.sizeThatFits(ProposedViewSize(width: max(rest, Self.fieldMinWidth), height: nil))
                size.width = max(rest, Self.fieldMinWidth)
            } else {
                // Never wider than the field: a long label truncates inside its chip, the ✕ stays in view.
                size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
                if x > 0, x + size.width > width { endLine() }
            }
            placements.append(Placement(origin: CGPoint(x: x, y: 0), size: size))
            line.append(i)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        if !line.isEmpty { endLine() }
        let height = placements.isEmpty ? 0 : y - spacing
        return (placements, CGSize(width: proposed ?? widest, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(subviews, width: bounds.width).placements
        for (subview, placement) in zip(subviews, placements) {
            subview.place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                          proposal: ProposedViewSize(placement.size))
        }
    }
}
