import Foundation
import AiTermCore

#if DEBUG
/// One filled New Broadcast fixture. Each renderer supplies its existing prompt,
/// agent catalogue and readiness variant; the common picks, review and goal stay identical.
@MainActor
enum NewBroadcastFixture {
    static func model(context: NewBroadcastContext, prompt: String, skills: [AgentCompletion] = [],
                      readiness: BroadcastReadiness = .ready) -> NewBroadcastModel {
        let projects = [OperatorScene.project("webshop"), OperatorScene.project("payments-api")]
        let model = NewBroadcastModel(projects: projects, context: context, skills: { _, _ in skills },
                                      readiness: { readiness }) { _ in UUID() }
        model.received([OperatorScene.payments])
        model.add(jiraProject: OperatorScene.payments)
        model.completions.all = skills
        model.prompt = prompt
        model.review = "An adversarial review with /code-review. It passes with no Critical or Important findings. After 3 rounds of fixes, ask me."
        if context.oracleIsOn { model.done = "Every PAY ticket in sprint 12 is merged, and its Jira ticket is in Review." }
        return model
    }
}
#endif
