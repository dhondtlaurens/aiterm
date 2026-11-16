#if DEBUG
import SwiftUI
import AiTermCore
import AiTermUI

@MainActor enum SignalSnapshots {
    static var all: [Snapshot] {
        var values: [Snapshot] = []
        for kind in SignalModel.SourceKind.allCases {
            let events: [RequestConditions.Event] = kind == .jira ? [.reviewRequested] : [.myRequest, .reviewRequested]
            for event in events {
                for step in 1...5 {
                    values.append(Snapshot("signal-\(kind.rawValue)-\(event.rawValue)-\(step).png") {
                        SignalSheet(model: model(kind, event: event)).seeded(step: step)
                    })
                }
            }
        }
        values += [
            Snapshot("signal-jira-jql.png") {
                let model = model(.jira); model.queryMode = .jql
                model.jql = "labels = operator AND sprint in openSprints() AND statusCategory != Done"
                return SignalSheet(model: model).seeded(step: 2)
            },
            Snapshot("signal-jira-status-merge.png") {
                let model = model(.jira); model.done = .ticketStatus(""); model.status = "Ready for QA"
                model.mergeWhenReady = true; model.then = .keep
                return SignalSheet(model: model).seeded(step: 5)
            },
            Snapshot("signal-jira-merged-remove.png") {
                let model = model(.jira); model.done = .merged; model.then = .remove; model.deleteMergedBranch = true
                return SignalSheet(model: model).seeded(step: 5)
            },
        ]
        return values
    }
    static func model(_ kind: SignalModel.SourceKind, event: RequestConditions.Event = .reviewRequested) -> SignalModel {
        let jira = JiraProjectRef(id: "pay", key: "PAY", name: "Payments", siteURL: URL(string: "https://jira.example")!)
        let remote = kind == .gitHub ? "https://github.com/shop/webshop" : "https://git.example/shop/webshop"
        let project = Project(id: UUID(), name: "webshop", path: "/synthetic/webshop", provider: kind == .gitHub ? .github : .gitlab,
                              remoteUrl: remote, addedAt: Snapshots.clock.now, collapsed: false, jiraProjects: [jira])
        let metadata = SignalModel.Metadata(labels: ["operator", "bug"], projects: [jira])
        let read: SignalRead
        if kind == .jira {
            let titles = ["Cart drawer keeps focus on close", "Round prices per order, not per line", "Export orders without VAT", "Rotate the staging certificates"]
            read = SignalRead(items: zip(["PAY-142", "PAY-150", "PAY-151", "OPS-12"], titles).map { key, title in
                let ticket = JiraTicket(key: key, summary: title, description: "A synthetic description.", issueType: "Task", status: "To Do",
                                        url: "https://jira.example/browse/" + key)
                return SignalItem(item: .ticket(site: "https://jira.example", key: key), title: title, description: ticket.description, ticket: ticket)
            }, complete: true)
        } else {
            let number = event == .myRequest ? 96 : 412
            let title = event == .myRequest ? "Coupon field loses focus on mobile" : "Search facets count hidden products"
            let url = remote + (kind == .gitHub ? "/pull/" : "/-/merge_requests/") + String(number)
            let request = MergeRequest(iid: number, title: title, sourceBranch: "fix/coupon-focus", targetBranch: "main", author: "jan",
                                       state: "opened", draft: false, url: url, description: "A synthetic merge request description.")
            read = SignalRead(items: [SignalItem(item: .request(remote: remote, number: number), title: title,
                                                description: request.description, mergeRequest: request)], complete: true)
        }
        let context = SignalContext(models: models, defaults: [.claude: .init(agent: .claude, model: "claude-opus-5-5", reasoning: "high"),
                                                              .codex: .init(agent: .codex, model: "gpt-6-astra", reasoning: "medium")])
        let model = SignalModel(projects: [project], context: context, at: Snapshots.clock.now, preview: { _ in read }, metadata: { metadata }, save: { _ in })
        model.selectSource(kind); model.setEvent(event)
        model.name = kind == .jira ? "Sprint tickets" : event == .myRequest ? "My merge requests" : "Reviews"
        model.jira = JiraConditions(labels: ["operator"], inOpenSprints: true)
        model.prompt = kind == .jira ? "Plan the ticket, build it and open a merge request."
            : event == .myRequest ? "Answer every open thread, then run the tests." : "Review it and post only the important findings."
        if kind != .jira, event == .myRequest { model.mergeWhenReady = true }
        if kind != .jira, event == .reviewRequested, let row = model.agentRows.first(where: { $0.choice.agent == .claude }) { model.removeAgent(row.id) }
        model.received(metadata: metadata); try! model.received(preview: read)
        return model
    }
    private static let models: [AgentKind: [AgentModel]] = [
        .claude: [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")],
        .codex: [AgentModel(id: "gpt-6-astra", label: "gpt-6-astra", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "medium")],
    ]
}
#endif
