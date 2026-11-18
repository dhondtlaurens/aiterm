#if DEBUG
import SwiftUI
import AiTermCore
import AiTermUI

@MainActor enum SignalSnapshots {
    static var all: [Snapshot] {
        var values: [Snapshot] = []
        for source in [SignalTrigger.Source.jira, .gitLab] {
            for step in SignalModel.stepNames.indices.map({ $0 + 1 }) {
                values.append(Snapshot("signal-\(source.rawValue)-\(step).png") { SignalSheet(model: model(source)).seeded(step: step) })
            }
        }
        values += [
            // A Start query that names no role of the account's is refused under its field.
            Snapshot("signal-gitLab-refused.png") {
                let model = model(.gitLab); model.start.query = "review-state:unreviewed draft:no"
                return SignalSheet(model: model).seeded(step: SignalModel.startStep)
            },
            // The account's own merge requests: merge when ready is offered, and on.
            Snapshot("signal-gitLab-merge.png") {
                let model = model(.gitLab); model.name = "My merge requests"
                model.start = SignalTrigger(source: .gitLab, description: "My merge requests with a thread waiting on my reply",
                                            query: "author:@me threads:waiting-on-me")
                model.done = SignalTrigger(source: .gitLab, description: "When no thread waits on my reply", query: "-threads:waiting-on-me")
                model.mergeWhenReady = true; model.then = .keep
                return SignalSheet(model: model).seeded(step: SignalModel.doneStep)
            },
            // Claude writing the Start query: the button is its own progress, the fields stay editable.
            Snapshot("signal-jira-writing.png") { writing(.jira) },
            Snapshot("signal-gitLab-writing.png") { writing(.gitLab) },
        ]
        return values
    }
    /// The Start trigger described, its query not yet written, while Claude writes it.
    private static func writing(_ source: SignalTrigger.Source) -> SignalSheet {
        let model = model(source, matched: false); model.start.query = ""
        model.seed(writing: QueryWriting(busy: true), start: true)
        return SignalSheet(model: model).seeded(step: SignalModel.startStep)
    }
    /// A signal of `source` with both triggers described and written by Claude; `matched` with its match preview read.
    static func model(_ source: SignalTrigger.Source, matched: Bool = true) -> SignalModel {
        let jira = JiraProjectRef(id: "pay", key: "PAY", name: "Payments", siteURL: URL(string: "https://jira.example")!)
        let remote = "https://gitlab.example.com/shop/webshop"
        let project = Project(id: UUID(), name: "webshop", path: "/synthetic/webshop", provider: .gitlab,
                              remoteUrl: remote, addedAt: Snapshots.clock.now, collapsed: false, jiraProjects: [jira])
        let read: SignalRead
        if source == .jira {
            let titles = ["Cart drawer keeps focus on close", "Round prices per order, not per line", "Export orders without VAT", "Rotate the staging certificates"]
            read = SignalRead(items: zip(["PAY-142", "PAY-150", "PAY-151", "OPS-12"], titles).map { key, title in
                let ticket = JiraTicket(key: key, summary: title, description: "A synthetic description.", issueType: "Task", status: "To Do",
                                        url: "https://jira.example/browse/" + key)
                return SignalItem(item: .ticket(site: "https://jira.example", key: key), title: title, description: ticket.description, ticket: ticket)
            }, complete: true)
        } else {
            let requests = [(412, "Search facets count hidden products"), (96, "Cache the price list per market")]
            read = SignalRead(items: requests.map { number, title in
                let request = MergeRequest(iid: number, title: title, sourceBranch: "fix/facets", targetBranch: "main", author: "sam",
                                           state: "opened", draft: false, url: remote + "/-/merge_requests/" + String(number),
                                           description: "A synthetic merge request description.")
                return SignalItem(item: .request(remote: remote, number: number), title: title, description: request.description, mergeRequest: request)
            }, complete: true, accountUser: "alex")
        }
        let context = SignalContext(models: models, defaults: [.claude: .init(agent: .claude, model: "claude-opus-5-5", reasoning: "high"),
                                                              .codex: .init(agent: .codex, model: "gpt-6-astra", reasoning: "medium")])
        let model = SignalModel(projects: [project], context: context, at: Snapshots.clock.now, preview: { _ in read }, save: { _ in })
        if source == .jira {
            model.name = "Sprint tickets"
            model.start = SignalTrigger(source: .jira, description: "My tickets in my open sprints, labelled ai, that nobody started yet",
                                        query: #"assignee = currentUser() AND sprint in openSprints() AND labels = "ai" AND statusCategory = "To Do""#)
            model.done = SignalTrigger(source: .gitLab, description: "When a reviewer is asked on its merge request", query: "reviewer:any")
            model.prompt = "/psg:plan, then /psg:implement and /psg:review"
        } else {
            model.name = "Reviews"
            model.start = SignalTrigger(source: .gitLab, description: "Merge requests where I’m a reviewer and haven’t reviewed yet, no drafts",
                                        query: "reviewer:@me review-state:unreviewed draft:no")
            model.done = SignalTrigger(source: .gitLab, description: "When I’ve approved it", query: "reviewer:@me review-state:approved")
            model.prompt = "/psg:peer-review"
            if let row = model.agentRows.first(where: { $0.choice.agent == .codex }) { model.removeAgent(row.id) }
        }
        model.seed(writing: QueryWriting(written: true), start: true); model.seed(writing: QueryWriting(written: true), start: false)
        if matched { try! model.received(preview: read) }
        return model
    }
    private static let models: [AgentKind: [AgentModel]] = [
        .claude: [AgentModel(id: "claude-opus-5-5", label: "Opus 5.5", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")],
        .codex: [AgentModel(id: "gpt-6-astra", label: "gpt-6-astra", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "medium")],
    ]
}
#endif
