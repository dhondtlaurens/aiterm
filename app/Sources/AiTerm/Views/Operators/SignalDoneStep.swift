import SwiftUI
import AiTermCore
import AiTermUI

/// The Done trigger, merge when ready where the Start trigger's merge requests are the person's own, and Then.
struct SignalDoneStep: View {
    @Bindable var model: SignalModel
    var body: some View {
        SignalTriggerStep(model: model, start: false)
        if model.offersMerge {
            DescriptionToggle("Merge it when it’s ready", isOn: $model.mergeWhenReady,
                              help: "AiTerm merges through the host once it’s approved, its checks pass and its threads are resolved, unless the Oracle vetoes. Offered when the merge request is yours.")
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
}

/// What a signal will do, end to end, in one paragraph: New Signal's closing block on its Done when step.
struct SignalDoneSummary: View {
    let model: SignalModel
    var body: some View {
        life.font(Typography.body).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
    }
    private var life: Text {
        let start = model.start
        let what = switch (start.source, start.startRole) {
        case (.jira, _): "Each ticket that matches starts a task"
        case (_, .reviewer?): "Each merge request that matches starts a review task"
        case (_, .author?), (_, .assignee?): "Each merge request that matches starts a task"
        case (_, nil): "Each merge request that matches starts a task, a review task unless it’s yours"
        }
        // The query, never the description: free words do not read inside this sentence.
        let query = model.done.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let condition = query.isEmpty ? Text("its Done query matches")
            : Text("it matches ") + Text(query).fontWeight(.semibold)
        let ending = switch model.then {
        case .unknown: "this version cannot finish it"
        case .keep: "its task is kept"
        case .archive: "its task is archived"
        case .remove: model.deleteMergedBranch ? "its task is removed, and its branch deleted only if it’s merged and unchanged" : "its task is removed"
        }
        let finish = model.finish.mergesWhenReady
            ? Text("AiTerm merges it once it’s ready, and it’s done when merged or closed. ")
            : Text("It’s done when ") + condition + Text(", or its merge request is merged or closed. ")
        let count = model.startCount.map { "\($0) \($0 == 1 ? "item matches" : "items match") now and \($0 == 1 ? "starts" : "start") at once." }
            ?? "AiTerm checks for matches when you save."
        return Text(what + ", and a later match continues it. ") + finish + Text("Then ") + Text(ending).fontWeight(.semibold) + Text(". " + count)
    }
}
