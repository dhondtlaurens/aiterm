import SwiftUI
import AiTermCore
import AiTermUI

struct SignalDoneStep: View {
    @Bindable var model: SignalModel
    var body: some View {
        FormField("Done when") {
            HStack(alignment: .top, spacing: Space.gap) {
                Select(values: Array(model.doneChoices.indices), selection: Binding(get: {
                    model.doneChoices.firstIndex(of: model.done) ?? 0
                }, set: { index in model.done = model.doneChoices[index] }),
                       label: { Self.label(model.doneChoices[$0]) })
                if case .ticketStatus = model.done {
                    if statusChoices.isEmpty { Input(placeholder: "Status in Jira", text: $model.status) }
                    else { Select(values: statusChoices, selection: $model.status, label: { $0 }) }
                }
            }
            HelpText(Self.help(model.done))
        }
        if model.offersMerge {
            DescriptionToggle("Merge it when it’s ready", isOn: $model.mergeWhenReady,
                              help: "Once it’s approved, the pipeline is green, every thread is resolved and the Oracle agrees. AiTerm merges; a worker never does.")
        }
        FormField("Then") {
            SegmentedControl(values: SignalFinish.Then.allCases, selection: $model.then) { value, _ in
                Text(Self.thenLabel(value))
            }
            HelpText(thenHelp)
        }
        if model.then == .remove {
            DescriptionToggle("Delete its branch once merged", isOn: $model.deleteMergedBranch,
                              help: "Only when it’s merged and still at the commit that was merged.")
        }
    }
    private var thenHelp: String {
        switch model.then {
        case .unknown: "Choose a supported finish for this version."
        case .keep: "It stays under the signal, with its window and worktree."
        case .archive: "Its window and worktree close. Branch and conversation stay in the Archive. Unsaved work keeps the worktree."
        case .remove: "The task and its worktree go. Unsaved work keeps the worktree."
        }
    }
    private static func thenLabel(_ then: SignalFinish.Then) -> String {
        switch then { case .unknown: "Not supported by this version"; case .keep: "Keep the task"; case .archive: "Archive it"; case .remove: "Remove it" }
    }
    private var statusChoices: [String] {
        Array(Set(model.metadata.statuses.map(\.name) + (model.status.isEmpty ? [] : [model.status]))).sorted()
    }
    static func label(_ condition: DoneWhen) -> String {
        switch condition {
        case .operatorJudges: "The Operator judges it done"
        case .hasReviewer: "Its merge request has a reviewer"
        case .approved: "Its merge request is approved"
        case .threadsResolved: "Every thread is resolved"
        case .merged: "Its merge request is merged"
        case .ticketStatus: "The ticket reaches a status"
        case .myReviewPosted: "My review is posted"
        case .mergedOrClosed: "Merged or closed"
        case .unknown: "Unsupported condition"
        }
    }
    static func help(_ condition: DoneWhen) -> String {
        switch condition {
        case .operatorJudges: "The Operator judges the work against your prompt."
        case .hasReviewer: "Someone is set to review it. The Operator lets go of the task."
        case .approved: "People on the host have approved its current changes."
        case .threadsResolved: "No open thread is left on it. The Operator lets go of the task."
        case .merged: "You or a colleague merges it. The Operator follows the task until then."
        case .ticketStatus: "Its status in Jira. The Operator lets go of the task."
        case .myReviewPosted: "AiTerm sees a review, comments or an approval from you, made after the task started."
        case .mergedOrClosed: "You or a colleague merges or closes it."
        case .unknown: "This version of AiTerm cannot follow this condition."
        }
    }
}

/// What a signal will do, end to end, in one paragraph: New Signal's closing block on its Done step.
struct SignalDoneSummary: View {
    let model: SignalModel
    var body: some View {
        Text(life).font(Typography.body).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
    }
    private var life: String {
        let what = model.sourceKind == .jira ? "ticket that matches" : model.event == .reviewRequested ? "review you’re asked for" : "merge request of yours that needs you"
        let agents = ModelChoice.pair.filter { agent in model.agents.contains { $0.agent == agent } }.map(\.displayName).joined(separator: " or ")
        let ending = switch model.then {
        case .unknown: "this version cannot finish it"
        case .keep: "the task is kept"
        case .archive: "it’s archived"
        case .remove: model.deleteMergedBranch ? "it’s removed, and its branch deleted only if it’s merged and unchanged" : "it’s removed"
        }
        let condition = if case .ticketStatus = model.done { "the ticket reaches " + model.status }
            else if model.done == .operatorJudges { "the Operator judges it done" }
            else if model.done == .myReviewPosted { "your review is posted" }
            else { SignalDoneStep.label(model.done).lowercased() }
        let merge = model.finish.mergesWhenReady ? "AiTerm merges it when it’s ready and " : ""
        let count = model.startCount.map { "\($0) \($0 == 1 ? "item matches" : "items match") now and \($0 == 1 ? "starts" : "start") at once." }
            ?? "AiTerm checks for matches when you save."
        return "Each \(what) starts a task for \(agents). The Operator and the Oracle answer its questions and ask you only when they disagree or it’s yours to decide. "
            + "It’s done when \(condition); then \(merge)\(ending). \(count)"
    }
}
