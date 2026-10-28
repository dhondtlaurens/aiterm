import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// New Broadcast's Agents, Task and Done steps (broadcast setup v2), as the design page's 1A, 13A and 10A draw them: the
/// three steps, the Task step with the Merge slice off, and the Done step with the Oracle off.
@MainActor
enum BroadcastSetupSnapshots {
    static var all: [Snapshot] {
        [
            Snapshot("broadcast-setup-agents.png") { sheet(step: 3) },
            Snapshot("broadcast-setup-task.png") { sheet(step: 4) },
            Snapshot("broadcast-setup-done.png") { sheet(step: 5) },
            Snapshot("broadcast-setup-task-merge-off.png") { sheet(step: 4, slices: Slices(jira: true, review: true)) },
            Snapshot("broadcast-setup-done-oracle-off.png") { sheet(step: 5, oracle: false) },
        ]
    }

    /// New Broadcast on `step`, filled as the drawings are: PAY · Payments and its projects picked, the prompt written, the
    /// last broadcast's three rows, the review prompt, and the goal while the Oracle is on.
    private static func sheet(step: Int, slices: Slices = Slices(jira: true, review: true, merge: true), oracle: Bool = true) -> some View {
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
        return NewBroadcastSheet(model: model).seeded(step: step)
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
