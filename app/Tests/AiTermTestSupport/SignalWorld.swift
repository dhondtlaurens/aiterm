import Foundation
import AiTermCore

/// Signals and items share one repository and Jira link. No live account, git process or window.
struct SignalWorld {
    var state = AppState()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let project: Project
    static let agent = AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")
    init() {
        project = .make(name: "shop", path: "/synthetic/shop", provider: .gitlab,
                        remoteUrl: "git@git.example:shop/web.git", jiraProjects: [
                            JiraProjectRef(id: "1", key: "PAY", name: "Payments", siteURL: URL(string: "https://jira.example")!)
                        ])
        state.append(project: project)
    }
    @discardableResult mutating func signal(name: String = "Plan tickets", age: TimeInterval = 0,
                                           agents: [AgentChoice] = [Self.agent], then: SignalFinish.Then = .keep,
                                           done: DoneWhen = .operatorJudges) -> UUID {
        let signal = Signal(name: name, createdAt: now.addingTimeInterval(age), source: .jira(JiraConditions()),
                            work: SignalWork(prompt: "/psg:plan"), agents: agents,
                            finish: SignalFinish(doneWhen: done, then: then))
        state.signals.append(signal)
        return signal.id
    }
    func ticket(_ key: String = "PAY-1") -> SignalItem {
        let ticket = JiraTicket(key: key, summary: "Make retries safe", description: "Use an idempotency key.",
                                issueType: "Task", status: "To Do", url: "https://jira.example/browse/" + key)
        return SignalItem(item: .ticket(site: "https://jira.example", key: key), title: ticket.summary,
                          description: ticket.description, ticket: ticket)
    }
    @discardableResult mutating func workingTask(signal: UUID) -> UUID {
        var task = TaskItem.make(project: project.id, worktreePath: project.path + "/.worktrees/work",
                                 model: Self.agent.model, reasoning: Self.agent.reasoning, firstPrompt: "/psg:plan", createdAt: now, windowId: "worker-window")
        let stage = SignalStage(signal: signal, item: ticket().item, matchedAt: now, configuration: state.signal(id: signal)!)
        var record = SignalTask(current: stage, startedAt: now)
        record.phase = .working
        task.signalTask = record; state.tasks.append(task)
        if state.operatorSession == nil { state.operatorSession = OperatorSession(createdAt: now) }
        return task.id
    }

}
