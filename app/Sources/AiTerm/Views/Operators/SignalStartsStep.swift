import SwiftUI
import AiTermCore
import AiTermUI

struct SignalStartsStep: View {
    @Bindable var model: SignalModel
    @Binding var projectsOpen: Bool
    var body: some View {
        if model.sourceKind == .jira {
            FormField("Find tickets by") {
                SegmentedControl(values: SignalModel.QueryMode.allCases, selection: $model.queryMode) { value, _ in
                    Text(value == .conditions ? "Conditions" : "JQL")
                }
            }
            if model.queryMode == .jql {
                PromptStep(text: $model.jql, agent: .claude, completions: model.jqlCompletions, label: "JQL", placeholder: "labels = operator",
                           help: "Your query as written, in the Jira projects you can see. AiTerm checks every minute.")
            } else {
                FormField("Conditions") {
                    SignalConditionPicker(model: model)
                    HelpText("A ticket must meet every condition, in any Jira project and on any board. AiTerm checks every minute.")
                }
            }
        } else {
            FormField("Start a task when") {
                SegmentedControl(values: [RequestConditions.Event.reviewRequested, .myRequest],
                                 selection: Binding(get: { model.event }, set: model.setEvent)) { event, _ in
                    Text(event == .reviewRequested ? "I’m asked to review" : "My merge request needs me")
                }
                if model.event == .reviewRequested { HelpText("Someone else’s merge request, with you as a reviewer.") }
            }
            if model.event == .myRequest {
                VStack(alignment: .leading, spacing: Space.base) {
                    DescriptionToggle("It’s waiting on my reply", isOn: $model.waitingOnMyReply, help: "A reviewer left threads I haven’t answered.")
                    DescriptionToggle("It’s sent back to me", isOn: $model.sentBackToMe, help: "It’s assigned to me again, or a reviewer asked for changes.")
                }
            }
            FormField("Projects (optional)") {
                ChipsPicker(placeholder: "Add a project", picks: selected, open: $projectsOpen,
                            matches: matching, mark: { _ in model.sourceKind.mark }, label: \.name,
                            row: { item in Text(item.name).font(Typography.caption).foregroundStyle(Palette.text) },
                            onPick: { model.requestProjects.append($0.id) },
                            onRemove: { pick in model.requestProjects.removeAll { sameRemote($0, pick.id) } })
                HelpText("Empty: every project of yours on \(model.sourceKind.label). AiTerm checks every minute.")
            }
        }
        SignalMatchPreview(model: model)
    }
    private func sameRemote(_ first: String, _ second: String) -> Bool {
        guard let identity = ItemRef.repository(first) else { return first == second }
        return identity == ItemRef.repository(second)
    }
    private struct ProjectPick: Identifiable { var id: String; var name: String }
    private var selected: [ProjectPick] {
        model.requestProjects.map { remote in
            ProjectPick(id: remote, name: model.projects.first { $0.remoteUrl.map { sameRemote($0, remote) } == true }?.name
                        ?? RemoteURL(remote)?.path ?? remote)
        }
    }
    private func matching(_ query: String) -> [ProjectPick] {
        model.projects.compactMap { project in
            guard let remote = project.remoteUrl, let host = RemoteURL(remote)?.host,
                  (model.sourceKind == .gitHub) == (host == "github.com"),
                  !model.requestProjects.contains(where: { sameRemote($0, remote) }),
                  query.isEmpty || project.name.localizedCaseInsensitiveContains(query) else { return nil }
            return ProjectPick(id: remote, name: project.name)
        }
    }
}

struct SignalMatchPreview: View {
    let model: SignalModel
    /// The creation sheet shows a sample, keeping room for its conditions and the count of all matches.
    private static let sampleLimit = 4
    private var limit: Int { model.sourceKind == .jira && model.queryMode == .jql ? 3 : Self.sampleLimit }
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
                         : "These start at once. Existing tasks carry on; items without a project are skipped.")
            }
        }
    }
    private var heading: String {
        let title = model.title == "New signal" ? "Starts when you create it" : "Starts when you save it"
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
        case .mergeRequest(let request): (model.sourceKind == .gitHub ? "#" : "!") + String(request.number)
        case .branch(let branch): branch.name
        case .unknown: "Item"
        }
    }
}
