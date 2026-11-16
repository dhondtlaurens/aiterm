import SwiftUI
import AiTermCore
import AiTermUI

/// Each Jira condition is a chip with one confined editor; JQL is the separate whole-query choice.
struct SignalConditionPicker: View {
    @Bindable var model: SignalModel
    @State private var editing: Field?
    enum Field: String, CaseIterable, Identifiable {
        case label, sprints, assignee, status, project
        var id: Self { self }
        var title: String {
            switch self { case .label: "Label"; case .sprints: "In my open sprints"; case .assignee: "Assignee"; case .status: "Status"; case .project: "Jira project" }
        }
    }
    /// Room for a search and a few choices, local to the condition-chip popovers.
    private static let popoverWidth: CGFloat = 320
    var body: some View {
        ChipFlow(spacing: Space.tight, hasField: true) {
            ForEach(Field.allCases.filter(has)) { field in
                HStack(spacing: Space.tight) {
                    Button { editing = field } label: {
                        HStack(spacing: Space.tight) {
                            Icon(.brand(Palette.jira), size: Size.pickerRowLogo)
                            Text(label(field)).font(Typography.caption).foregroundStyle(Palette.text).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                    PickerClearButton(help: "Remove \(field.title)", accessibilityLabel: "Remove \(field.title)") { remove(field) }
                }
                .padding(.horizontal, Space.snug).frame(height: PickChip.lineHeight).chipChrome(fill: Palette.badge)
            }
            Menu {
                ForEach(Field.allCases.filter { !has($0) }) { field in
                    Button(field.title) { if field == .sprints { model.jira.inOpenSprints = true } else { editing = field } }
                }
            } label: { Text("Add a condition").font(Typography.caption).foregroundStyle(Palette.muted) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(height: PickChip.lineHeight)
        }
        .padding(.horizontal, Space.inset).padding(.vertical, Space.tight)
        .frame(maxWidth: .infinity, minHeight: Size.control, alignment: .leading).fieldBox()
        .popover(item: $editing) { field in
            VStack(alignment: .leading, spacing: Space.base) {
                Text(field.title).font(Typography.label).foregroundStyle(Palette.text)
                editor(field)
                if let error = model.metadataError { HelpText(error, tone: .warning) }
            }.padding(Space.inset).frame(width: Self.popoverWidth).background(Palette.menu).preferredColorScheme(.dark)
        }
    }
    @ViewBuilder private func editor(_ field: Field) -> some View {
        switch field {
        case .label: SignalTextChoices(values: $model.jira.labels, options: model.metadata.labels, placeholder: "Find or enter a label")
        case .sprints: DescriptionToggle("In my open sprints", isOn: $model.jira.inOpenSprints, help: "Any open sprint on a board you can read.")
        case .assignee: SignalAssigneePicker(model: model)
        case .status: SignalTextChoices(values: $model.jira.statuses, options: model.metadata.statuses.map(\.name), placeholder: "Find or enter a status")
        case .project:
            SignalTextChoices(values: $model.jira.projects, options: model.metadata.projects.map(\.key), placeholder: "Find or enter a Jira project",
                              labels: Dictionary(model.metadata.projects.map { ($0.key, $0.key + " · " + $0.name) }, uniquingKeysWith: { first, _ in first }))
        }
    }
    private func has(_ field: Field) -> Bool {
        switch field {
        case .label: !model.jira.labels.isEmpty
        case .sprints: model.jira.inOpenSprints
        case .assignee: model.jira.assignee != nil
        case .status: !model.jira.statuses.isEmpty
        case .project: !model.jira.projects.isEmpty
        }
    }
    private func label(_ field: Field) -> String {
        switch field {
        case .label: "label is " + model.jira.labels.joined(separator: " or ")
        case .sprints: "in my open sprints"
        case .assignee: "assignee is " + (model.jira.assignee == "me" ? "me" : model.assignees.first { $0.accountId == model.jira.assignee }?.displayName ?? "Selected person")
        case .status: "status is " + model.jira.statuses.joined(separator: " or ")
        case .project: "project is " + model.jira.projects.joined(separator: " or ")
        }
    }
    private func remove(_ field: Field) {
        switch field {
        case .label: model.jira.labels = []
        case .sprints: model.jira.inOpenSprints = false
        case .assignee: model.jira.assignee = nil
        case .status: model.jira.statuses = []
        case .project: model.jira.projects = []
        }
    }
}

private struct SignalTextChoices: View {
    @Binding var values: [String]
    let options: [String]
    let placeholder: String
    var labels: [String: String] = [:]
    @State private var open = false
    @State private var query = ""
    private struct Choice: Identifiable { var id: String }
    var body: some View {
        ChipsPicker(placeholder: placeholder, picks: values.map { Choice(id: $0) }, open: $open,
                    matches: { query in
                        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        let choices = Set(options + (text.isEmpty ? [] : [text]))
                        return choices.filter { !values.contains($0) && (text.isEmpty || (labels[$0] ?? $0).localizedCaseInsensitiveContains(text)) }
                            .sorted().map { Choice(id: $0) }
                    }, mark: { _ in .brand(Palette.jira) }, label: { labels[$0.id] ?? $0.id },
                    row: { Text(labels[$0.id] ?? $0.id).font(Typography.caption).foregroundStyle(Palette.text) },
                    onPick: { values.append($0.id); query = "" }, onRemove: { pick in values.removeAll { $0 == pick.id } }, query: $query,
                    inlineResults: true)
    }
}

private struct SignalAssigneePicker: View {
    @Bindable var model: SignalModel
    @State private var query = ""
    @State private var open = false
    private struct Choice: Identifiable { var id: String; var name: String }
    var body: some View {
        let selected = model.jira.assignee.map { value in Choice(id: value, name: value == "me" ? "Me" : model.assignees.first { $0.accountId == value }?.displayName ?? "Selected person") }
        ChipsPicker(placeholder: "Find a person", picks: selected.map { [$0] } ?? [], open: $open,
                    matches: { _ in
                        [Choice(id: "me", name: "Me")] + model.assignees.map { Choice(id: $0.accountId, name: $0.displayName) }
                    }, mark: { _ in .brand(Palette.jira) }, label: \.name,
                    row: { Text($0.name).font(Typography.caption).foregroundStyle(Palette.text) },
                    onPick: { model.jira.assignee = $0.id }, onRemove: { _ in model.jira.assignee = nil }, query: $query, selectionLimit: 1,
                    inlineResults: true)
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                await model.searchAssignees(query)
            }
    }
}
