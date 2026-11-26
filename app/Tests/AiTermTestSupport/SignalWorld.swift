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
    /// A Jira signal on `labels = operator`, done when its Done trigger (Jira `status = Done` unless given) matches.
    @discardableResult mutating func signal(name: String = "Plan tickets", age: TimeInterval = 0,
                                           agents: [AgentChoice] = [Self.agent], then: SignalFinish.Then = .keep,
                                           start: SignalTrigger = SignalTrigger(source: .jira, query: "labels = operator"),
                                           done: SignalTrigger = SignalTrigger(source: .jira, query: "status = Done"),
                                           merges: Bool = false) -> UUID {
        let signal = Signal(name: name, createdAt: now.addingTimeInterval(age), start: start, done: done,
                            work: SignalWork(prompt: "/psg:plan"), agents: agents,
                            finish: SignalFinish(then: then, mergesWhenReady: merges))
        state.signals.append(signal)
        return signal.id
    }
    /// A schedule on `cron` in the world's project, done when the Operator decides unless `done` says otherwise, with
    /// `scheduledFrom` at `from` (the world's now unless given).
    @discardableResult mutating func scheduled(name: String = "Weekly dependency update", cron: String = "0 9 * * 1",
                                               done: SignalTrigger = SignalTrigger(source: .operator, query: ""),
                                               from: Date? = nil, then: SignalFinish.Then = .keep, merges: Bool = false) -> UUID {
        let signal = Signal(name: name, createdAt: from ?? now,
                            start: SignalTrigger(source: .schedule, query: cron, project: project.id), done: done,
                            work: SignalWork(prompt: "Update the dependencies", ticketDescription: false, requestDescription: false),
                            agents: [Self.agent], finish: SignalFinish(then: then, mergesWhenReady: merges), scheduledFrom: from ?? now)
        state.signals.append(signal)
        return signal.id
    }
    /// A project signal on `labels = review` unless `start` says otherwise, on one agent row, done when the person
    /// decides unless `done` says otherwise.
    @discardableResult mutating func projectSignal(name: String = "Review tickets", age: TimeInterval = 0,
                                                  start: SignalTrigger = SignalTrigger(source: .jira, query: "labels = review"),
                                                  done: SignalTrigger = SignalTrigger(source: .person, query: ""),
                                                  then: SignalFinish.Then = .keep) -> UUID {
        let signal = Signal.project(name: name, createdAt: now.addingTimeInterval(age), start: start, done: done,
                                    agent: Self.agent, then: then)
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
    /// An ordinary task `signal` started on `item` (the world's ticket unless given): marked with its origin, no record.
    @discardableResult mutating func markedTask(signal: UUID, item: ItemRef? = nil) -> UUID {
        let item = item ?? ticket().item
        var task = TaskItem.make(project: project.id, worktreePath: project.path + "/.worktrees/work",
                                 model: Self.agent.model, reasoning: Self.agent.reasoning, createdAt: now, windowId: "task-window")
        task.signalOrigin = SignalOrigin(signal: signal, name: state.signal(id: signal)?.name ?? "", item: item, startedAt: now)
        state.tasks.append(task)
        return task.id
    }
}
