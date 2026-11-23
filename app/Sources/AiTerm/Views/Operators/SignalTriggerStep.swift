import SwiftUI
import AiTermCore
import AiTermUI

/// A Start or Done trigger. Each opens with its two-way row, Starts on (An item · A schedule) or Done when (A query
/// matches · The Operator decides). An item's or a query's trigger is the source it reads, the person's description with
/// its Write button on the label's row, and the query that runs, in short mono editors; a schedule's is the description,
/// its cron, its project and its next runs; the Operator's Done is an optional description of done. The help under a
/// query names the syntax, says Claude wrote it, or, in warning ink, why the write failed or why AiTerm refuses it.
struct SignalTriggerStep: View {
    @Bindable var model: SignalModel
    let start: Bool
    @State private var describeFocused = false
    var body: some View {
        if start {
            FormField("Starts on") {
                SegmentedControl(values: [SignalModel.StartKind.item, .schedule], selection: $model.startKind) { kind, _ in
                    Text(kind == .item ? "An item" : "A schedule")
                }
            }
            if model.isScheduled { scheduleFields } else { queryFields }
        } else {
            FormField("Done when") {
                SegmentedControl(values: [SignalModel.DoneKind.query, .operatorDecides], selection: $model.doneKind) { kind, _ in
                    Text(kind == .query ? "A query matches" : "The Operator decides")
                }
            }
            if model.doneKind == .operatorDecides { operatorFields } else { queryFields }
        }
    }
    @ViewBuilder private var queryFields: some View {
        let trigger = start ? $model.start : $model.done
        let source = trigger.wrappedValue.source
        // A run has no ticket, so a scheduled signal's Done cannot read Jira.
        let jiraOff = !start && model.isScheduled
        FormField("Reads") {
            SegmentedControl(values: SignalTrigger.Source.itemSources, selection: trigger.source,
                             isSelectable: { !(jiraOff && $0 == .jira) },
                             help: { jiraOff && $0 == .jira ? "A run has no ticket for a Jira query to match." : nil }) { source, _ in
                HStack(spacing: Space.snug) { Icon(source.mark, size: Size.pickerRowLogo); Text(source.label) }
            }
        }
        describeField(trigger, source: source)
        queryField(trigger, source: source, label: Self.queryLabel(source))
    }
    @ViewBuilder private var scheduleFields: some View {
        describeField($model.start, source: .schedule)
        queryField($model.start, source: .schedule, label: "Cron")
        FormField("Project") {
            Select(values: [nil] + model.projects.map(\.id), selection: $model.start.project,
                   label: { id in id.flatMap { id in model.projects.first { $0.id == id }?.name } ?? "Choose a project" },
                   isSelectable: { $0 != nil })
            HelpText("Each run starts a task here, on a branch of its own.")
        }
        if model.startRefusal == nil, !model.nextRuns.isEmpty { SignalNextRuns(model: model) }
    }
    @ViewBuilder private var operatorFields: some View {
        FormField("What done looks like (optional)") {
            ZStack(alignment: .topLeading) {
                PromptEditor(text: $model.done.description, agent: .claude, completions: model.doneDescribeCompletions,
                             onFocusChange: { if describeFocused != $0 { describeFocused = $0 } }, focusOnAppear: true)
                    .frame(height: Sheet.queryEditorHeight)
                    .fieldBox(focused: describeFocused)
                PromptPlaceholder(text: $model.done.description, placeholder: Self.describePlaceholder(.operator, start: false))
            }
            HelpText("When the worker ends its turn, the Operator judges whether the work is done and the Oracle has to agree. "
                     + "If they disagree, or the Oracle is off, you decide in the Operator’s chat. Left empty: the prompt’s work is complete.")
        }
    }
    private func describeField(_ trigger: Binding<SignalTrigger>, source: SignalTrigger.Source) -> some View {
        FormField("Describe it") {
            writeButton(source)
        } content: {
            ZStack(alignment: .topLeading) {
                PromptEditor(text: trigger.description, agent: .claude,
                             completions: start ? model.startDescribeCompletions : model.doneDescribeCompletions,
                             onFocusChange: { if describeFocused != $0 { describeFocused = $0 } }, focusOnAppear: true)
                    .frame(height: Sheet.queryEditorHeight)
                    .fieldBox(focused: describeFocused)
                PromptPlaceholder(text: trigger.description, placeholder: Self.describePlaceholder(source, start: start))
            }
        }
    }
    private func queryField(_ trigger: Binding<SignalTrigger>, source: SignalTrigger.Source, label: String) -> some View {
        let help = queryHelp(source)
        return PromptStep(text: trigger.query, agent: .claude, completions: start ? model.startCompletions : model.doneCompletions,
                          label: label, placeholder: Self.queryPlaceholder(source, start: start),
                          help: help.text, helpTone: help.tone, editorHeight: Sheet.queryEditorHeight, focusOnAppear: false)
    }
    private func writeButton(_ source: SignalTrigger.Source) -> some View {
        let busy = model.writing(start: start).busy
        return Button { Task { await model.write(start: start) } } label: {
            HStack(spacing: Space.snug) {
                if busy { StatusMark(status: .working, size: Size.statusMark) }
                Text(busy ? "Writing…" : "Write " + Self.queryLabel(source))
            }
        }
        .buttonStyle(.push(.secondary)).controlSize(.small)
        .disabled(!model.canWrite(start: start))
    }
    private func queryHelp(_ source: SignalTrigger.Source) -> (text: String, tone: HelpText.Tone) {
        let writing = model.writing(start: start)
        if let error = writing.error { return (error, .warning) }
        if let refusal = start ? model.startRefusal : model.doneRefusal { return (refusal.message, .warning) }
        if writing.written, let checker = Self.checker(source) {
            return ("Written by Claude from your description and checked by \(checker). Edit it as you like.", .secondary)
        }
        if !start, model.isScheduled, source == .gitLab || source == .gitHub {
            return ("Checked against the merge request its run opens. A run without one isn’t done.", .secondary)
        }
        return (Self.syntaxHelp(source, start: start), .secondary)
    }
    static func queryLabel(_ source: SignalTrigger.Source) -> String {
        switch source { case .jira: "JQL"; case .gitLab: "GitLab query"; case .gitHub: "GitHub query"; case .schedule: "cron"; case .operator, .unknown: "Query" }
    }
    /// Who checked a written query: Jira its JQL, AiTerm GitLab's syntax, GitHub its own.
    private static func checker(_ source: SignalTrigger.Source) -> String? {
        switch source { case .jira: "Jira"; case .gitLab, .schedule: "AiTerm"; case .gitHub: "GitHub"; case .operator, .unknown: nil }
    }
    private static func describePlaceholder(_ source: SignalTrigger.Source, start: Bool) -> String {
        switch (source, start) {
        case (.jira, true): "My tickets in my open sprints that nobody started yet"
        case (.jira, false): "When it’s handed to someone else"
        case (.gitLab, true): "Merge requests where I’m a reviewer and haven’t reviewed yet, no drafts"
        case (.gitLab, false): "When I’ve approved it"
        case (.gitHub, true): "Pull requests where my review is requested, no drafts"
        case (.gitHub, false): "When I’ve reviewed it"
        case (.schedule, _): "Every Monday at 9am"
        case (.operator, _): "What done looks like, for the Operator and the Oracle"
        case (.unknown, _): ""
        }
    }
    private static func queryPlaceholder(_ source: SignalTrigger.Source, start: Bool) -> String {
        switch (source, start) {
        case (.jira, true): "assignee = currentUser() AND sprint in openSprints()"
        case (.jira, false): "status = Done"
        case (.gitLab, true): "reviewer:@me review-state:unreviewed draft:no"
        case (.gitLab, false): "reviewer:@me review-state:approved"
        case (.gitHub, true): "is:open user-review-requested:@me"
        case (.gitHub, false): "-user-review-requested:@me"
        case (.schedule, _): "0 9 * * 1"
        case (.operator, _), (.unknown, _): ""
        }
    }
    private static func syntaxHelp(_ source: SignalTrigger.Source, start: Bool) -> String {
        switch (source, start) {
        case (.jira, true): "Your JQL as written, in the Jira projects you can see. AiTerm checks every minute."
        case (.gitLab, true): "GitLab’s search syntax, naming you in one role: author:@me, assignee:@me or reviewer:@me. AiTerm checks every minute."
        case (.gitHub, true): "GitHub’s search syntax, for pull requests. AiTerm checks every minute."
        case (.jira, false): "Checked against each task’s own ticket: for a merge request, the key in its branch or title."
        case (.gitLab, false), (.gitHub, false): "Checked against each task’s own merge request. A task without one isn’t done."
        case (.schedule, _): "Minute, hour, day of month, month, weekday. Type your own, or describe it and let Claude write it."
        case (.operator, _): "Left empty: the prompt’s work is complete."
        case (.unknown, _): "This version of AiTerm cannot read this source."
        }
    }
}

extension SignalTrigger.Source {
    var label: String {
        switch self { case .jira: "Jira"; case .gitLab: "GitLab"; case .gitHub: "GitHub"; case .schedule: "Schedule"; case .operator: "Operator"; case .unknown(let value): value }
    }
    var mark: IconSource {
        switch self {
        case .jira: .brand(Palette.jira)
        case .gitLab: .brand(Palette.gitlab)
        case .gitHub: .brand(Palette.github)
        case .schedule: .symbol("clock")
        case .operator: .symbol("checkmark.seal")
        case .unknown: .symbol("questionmark.circle")
        }
    }
}

/// A schedule's next four runs, each with its project, in place of the match preview, and how the schedule keeps time.
struct SignalNextRuns: View {
    let model: SignalModel
    var body: some View {
        FormField("Next runs") {
            VStack(alignment: .leading, spacing: Space.snug) {
                ForEach(model.nextRuns, id: \.self) { run in
                    HStack(spacing: Space.snug) {
                        Text(Self.time(run, calendar: model.calendar)).font(Typography.caption.tabular).foregroundStyle(Palette.text)
                        Spacer(minLength: Space.snug)
                        if let project = model.scheduleProject {
                            Text(project.name).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                }
            }.padding(Space.inset).frame(maxWidth: .infinity, alignment: .leading).fieldBox()
            HelpText("In your Mac’s time zone, \(model.calendar.timeZone.identifier). Nothing starts when you \(model.isEditing ? "save" : "create") it. "
                     + "A run missed while AiTerm was closed or asleep starts once when it’s back; older misses are dropped.")
        }
    }
    /// `Mon 30 Nov 09:00`.
    static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB"); formatter.calendar = Cron.gregorian(calendar); formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}

struct SignalMatchPreview: View {
    let model: SignalModel
    /// The creation sheet shows a sample, keeping room for its conditions and the count of all matches.
    private let limit = 4
    var body: some View {
        FormField(heading) {
            if model.previewing { HelpText("Checking matches…") }
            else if let error = model.previewError { HelpText(error, tone: .warning) }
            else if let count = model.startCount {
                if !model.previewItems.isEmpty {
                    VStack(alignment: .leading, spacing: Space.snug) {
                        ForEach(Array(model.previewItems.prefix(limit).enumerated()), id: \.offset) { _, item in
                            preview(item)
                        }
                        if model.previewItems.count > limit { HelpText("And \(model.previewItems.count - limit) more.") }
                    }.padding(Space.inset).frame(maxWidth: .infinity, alignment: .leading).fieldBox()
                }
                HelpText(count == 0 ? "No items start now. The signal watches for future matches."
                         : "Existing tasks, including ones you made, continue with this prompt after their turn.")
            }
        }
    }
    private var heading: String {
        let title = model.isEditing ? "Starts when you save it" : "Starts when you create it"
        return title + (model.startCount.map { " · " + String($0) } ?? "")
    }
    private func preview(_ item: SignalItem) -> some View {
        let projects = ItemProjectMapper.projects(for: item.item, in: model.projects)
        return VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.snug) {
                Text(key(item.item)).font(Typography.caption.tabular).foregroundStyle(Palette.link).fixedSize()
                Text(item.title).font(Typography.caption).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: Space.snug)
                if !projects.isEmpty {
                    Text(projects.map(\.name).sentenceList).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            if projects.isEmpty { HelpText("No project in AiTerm matches this item.", tone: .warning, fixedVerticalSize: false) }
        }
    }
    private func key(_ item: ItemRef) -> String {
        switch item {
        case .ticket(let ticket): ticket.key
        case .mergeRequest(let request): (model.start.source == .gitHub ? "#" : "!") + String(request.number)
        case .run, .unknown: "Item"
        }
    }
}
