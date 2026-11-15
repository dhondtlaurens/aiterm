import Foundation
import AiTermCore

/// Complete reads become saved intents in one workspace mutation. This owner never performs I/O
/// against a project, a worker or an account; StageRunner consumes the returned launch ids.
@MainActor final class ItemRouter {
    private let workspace: WorkspaceStore
    private let now: () -> Date
    private let workerIsWorking: @MainActor (UUID) -> Bool
    var changed: (UUID, String) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, now: @escaping () -> Date, workerIsWorking: @escaping @MainActor (UUID) -> Bool = { _ in false }) {
        self.workspace = workspace; self.now = now; self.workerIsWorking = workerIsWorking
    }
    @discardableResult func apply(signals ids: [UUID], read: SignalRead) -> [UUID] {
        apply(observations: [SignalObservation(signals: ids, read: read)])
    }
    @discardableResult func apply(observations: [SignalObservation]) -> [UUID] {
        let complete = observations.filter { $0.read.complete }
        guard !complete.isEmpty, workspace.canChangeWorkspace else { return [] }
        let at = now(), state = workspace.state
        let ids = Set(complete.flatMap(\.signals))
        let signals = state.signals.filter { ids.contains($0.id) && $0.isRunnable }
        let items = Dictionary(complete.flatMap { $0.read.items }.compactMap { item in item.item.identity.map { ($0, item) } },
                               uniquingKeysWith: { first, _ in first })
        let matches = complete.flatMap { observation in
            signals.filter { observation.signals.contains($0.id) }.flatMap { signal in observation.read.items.map { item in
                SignalMatch(signal: signal.id, item: item.item,
                            project: ItemProjectMapper.projects(for: item.item, in: state.projects).first?.id,
                            matchedAt: at, branch: item.mergeRequest?.sourceBranch)
            } }
        }
        let decisions = MatchDecision.decide(matches: matches, signals: signals, tasks: state.tasks + state.archive.map(\.task),
                                             projects: state.projects, seen: state.signalSeen, complete: true)
        var launches: [UUID] = [], events: [(UUID, String)] = []
        workspace.mutate { state in
            for observation in complete where observation.read.full {
                let matching = Set(observation.read.items.compactMap { $0.item.identity })
                for index in state.signalSeen.indices where observation.signals.contains(state.signalSeen[index].signal) {
                    if state.signalSeen[index].item.identity.map({ !matching.contains($0) }) == true {
                        state.signalSeen[index].isMatching = false
                    }
                }
            }
            func configured(_ stage: SignalStage) -> SignalStage {
                var stage = stage
                stage.configuration = state.signal(id: stage.signal)
                if let signal = stage.configuration, let item = stage.item.identity.flatMap({ items[$0] }) {
                    stage.prompt = Self.prompt(signal: signal, item: item)
                }
                return stage
            }
            func seen(_ signal: UUID, _ item: ItemRef, _ disposition: SignalSeen.Disposition, reason: String? = nil) {
                state.signalSeen.removeAll { $0.signal == signal && $0.item.identity == item.identity }
                state.signalSeen.append(SignalSeen(signal: signal, item: item, disposition: disposition, at: at, reason: reason))
            }
            for decision in decisions {
                switch decision {
                case .skip(let match, let reason):
                    let old = state.signalSeen.first { $0.signal == match.signal && $0.item.identity == match.item.identity }
                    seen(match.signal, match.item, .skipped, reason: reason)
                    if old?.disposition != .skipped || old?.reason != reason || old?.isMatching != true {
                        events.append((match.signal, "Skipped " + (match.item.identity ?? "unknown item") + ": " + reason))
                    }
                case .start(let match, let pending):
                    guard let signal = state.signal(id: match.signal), let project = match.project,
                          let item = match.item.identity.flatMap({ items[$0] }) else { continue }
                    var task = Self.makeTask(item: item, signal: signal, project: project, at: at)
                    task.signalTask?.pendingStages = pending.map(configured)
                    let candidates = ItemProjectMapper.projects(for: match.item, in: state.projects).map(\.id)
                    if candidates.count > 1 {
                        task.signalTask?.candidateProjects = candidates
                        task.signalTask?.phase = .blocked
                        task.signalTask?.blockedReason = "Choose which linked project should hold this ticket."
                    }
                    state.tasks.append(task); launches.append(task.id)
                    seen(match.signal, match.item, .started)
                    for stage in pending { seen(stage.signal, stage.item, .started) }
                    events.append((task.id, "A signal matched a new item."))
                case .continueTask(let id, let proposed):
                    let stage = configured(proposed)
                    guard let task = state.signalItem(id: id), let signal = stage.configuration else { continue }
                    var record = task.signalTask ?? SignalTask(signal: stage.signal, item: stage.item, startedAt: at)
                    if task.signalTask == nil {
                        record.configuration = signal; record.prompt = stage.prompt
                    } else {
                        guard let next = try? SignalTransitions.apply(.matched(stage), to: record, at: at,
                                                                      workerIsWorking: workerIsWorking(id)) else { continue }
                        record = next
                    }
                    let startingConfiguration = record.configuration ?? state.signal(id: record.signal)
                    state.updateSignalItem(id) { task in
                        task.signalTask = record
                        if let item = stage.item.identity.flatMap({ items[$0] }) {
                            if let request = item.mergeRequest { task.mr = MergeRequestRef(iid: request.iid, title: request.title, url: request.url) }
                            if task.jira == nil { task.jira = item.ticket.map(JiraRef.init) }
                        }
                        if record.phase == .launching {
                            if let configuration = startingConfiguration, configuration.agents.count == 1, let choice = configuration.agents.first {
                                task.agent = choice.agent; task.model = choice.model; task.reasoning = choice.reasoning
                            } else {
                                task.signalTask?.phase = .blocked
                                task.signalTask?.blockedReason = "Choose a permitted agent and model for this stage."
                            }
                        }
                    }
                    if state.signalItem(id: id)?.signalTask?.phase == .launching { launches.append(id) }
                    seen(stage.signal, stage.item, .started)
                    events.append((id, record.phase == .launching ? "A signal continued this item." : "A signal queued the next stage."))
                }
            }
            let live = Set(state.allSignalTasks.compactMap { $0.signalTask?.item.identity })
            state.signalSeen = SignalSeen.pruned(state.signalSeen, liveItems: live, now: at)
        }
        guard workspace.flush() else { return [] }
        for (id, event) in events { changed(id, event) }
        return Array(Set(launches)).sorted { $0.uuidString < $1.uuidString }
    }
    nonisolated private static func prompt(signal: Signal, item: SignalItem) -> String {
        signal.work.workerPrompt(ticket: item.ticket?.description ?? (item.mergeRequest == nil ? item.description : nil),
                                 request: item.mergeRequest?.description ?? (item.ticket == nil ? item.description : nil))
    }
    nonisolated private static func makeTask(item: SignalItem, signal: Signal, project: UUID, at: Date) -> TaskItem {
        let agent = signal.agents.first ?? AgentChoice(agent: .claude, model: "", reasoning: nil)
        var draft = TaskDraft(ticket: nil, baseBranch: "", agent: agent.agent, model: agent.model, reasoning: agent.reasoning)
        draft.apply(ticket: item.ticket); draft.setTitle(item.title)
        let branch = item.mergeRequest?.sourceBranch ?? draft.branch
        let review: Bool
        switch signal.source {
        case .gitLab(let request), .gitHub(let request): review = request.event == .reviewRequested
        default: review = false
        }
        var task = TaskItem(id: UUID(), projectId: project, title: item.title, branch: branch, worktreePath: "",
                            baseBranch: item.mergeRequest?.targetBranch ?? "", jira: item.ticket.map(JiraRef.init),
                            kind: review ? .review : .task,
                            mr: item.mergeRequest.map { MergeRequestRef(iid: $0.iid, title: $0.title, url: $0.url) },
                            agent: agent.agent, model: agent.model, reasoning: agent.reasoning, firstPrompt: nil,
                            appendTicket: false, createdAt: at, windowId: nil)
        var record = SignalTask(signal: signal.id, item: item.item, startedAt: at)
        record.configuration = signal; record.prompt = prompt(signal: signal, item: item)
        if signal.agents.count != 1 || !AgentCommand.operatedAgents.contains(agent.agent) || agent.model.isEmpty {
            record.phase = .blocked; record.blockedReason = "Choose a permitted agent and model for this task."
        }
        task.signalTask = record
        return task
    }
}
