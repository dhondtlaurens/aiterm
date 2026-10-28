import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// New Broadcast's Agents, Task and Done steps (broadcast setup v2), as the design page's 1A, 13A and 10A draw them: the
/// three steps, the Task step with the Merge slice off and with closing left off, and the Done step with the Oracle off.
/// The Task step runs past `Sheet.height`, where a snapshot's sheet clips rather than scrolls, so its images draw the step
/// alone, whole, on the sheet's ground and within its margins, as 13A draws it at the height its content needs.
@MainActor
enum BroadcastSetupSnapshots {
    static var all: [Snapshot] {
        [
            Snapshot("broadcast-setup-agents.png") { sheet(step: 3) },
            Snapshot("broadcast-setup-task.png") { taskStep() },
            Snapshot("broadcast-setup-done.png") { sheet(step: 5) },
            Snapshot("broadcast-setup-task-merge-off.png") { taskStep(slices: Slices(jira: true, review: true)) },
            Snapshot("broadcast-setup-done-oracle-off.png") { sheet(step: 5, oracle: false) },
            Snapshot("broadcast-setup-task-closing-off.png") { taskStep(closing: false) },
        ]
    }

    /// New Broadcast on `step`, filled as the drawings are: PAY · Payments and its projects picked, the prompt written, the
    /// last broadcast's three rows, the review prompt, and the goal while the Oracle is on.
    private static func sheet(step: Int, slices: Slices = Slices(jira: true, review: true, merge: true), oracle: Bool = true) -> some View {
        NewBroadcastSheet(model: model(slices: slices, oracle: oracle)).seeded(step: step)
    }

    /// The Task step alone and whole, at the sheet's width, inside its margins, on its ground; `closing` false unticks
    /// “Close finished tasks’ tabs…”, which dims the branch box.
    private static func taskStep(slices: Slices = Slices(jira: true, review: true, merge: true), closing: Bool = true) -> some View {
        let filled = model(slices: slices, oracle: true)
        filled.closeWhenDone = closing
        return TaskStep(model: filled)
            .padding(Space.margin)
            .frame(width: Sheet.width, alignment: .topLeading)
            .background(Palette.surface)
    }

    private static func model(slices: Slices, oracle: Bool) -> NewBroadcastModel {
        let projects = [OperatorScene.project("webshop"), OperatorScene.project("payments-api")]
        let context = NewBroadcastContext(slices: slices, oracleIsOn: oracle, models: models,
                                          defaults: [.claude: opusHigh, .codex: astraMedium],
                                          lastAgents: [opusHigh, AgentChoice(agent: .claude, model: "claude-sonnet-5-5", reasoning: "medium"), astraMedium])
        let model = NewBroadcastModel(projects: projects, context: context, skills: { _, _ in [] }) { _ in UUID() }
        model.received([OperatorScene.payments])
        model.add(jiraProject: OperatorScene.payments)
        model.prompt = OperatorScene.prompt
        model.review = "An adversarial review with /code-review. It passes with no Critical or Important findings. After 3 rounds of fixes, ask me."
        if oracle { model.done = "Every PAY ticket in sprint 12 is merged, and its Jira ticket is in Review." }
        return model
    }

    private static let opusHigh = AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")
    private static let astraMedium = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")

    /// Claude's and Codex's model lists in Settings › Agents.
    private static let models: [AgentKind: [AgentModel]] = {
        let efforts = ["low", "medium", "high"]
        return [.claude: [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: efforts, defaultEffort: "high"),
                          AgentModel(id: "claude-sonnet-5-5", label: "Sonnet 5.5", detail: nil, efforts: efforts, defaultEffort: "medium")],
                .codex: [AgentModel(id: "gpt-6-astra", label: "gpt-6-astra", detail: nil, efforts: efforts, defaultEffort: "medium")]]
    }()
}
#endif
