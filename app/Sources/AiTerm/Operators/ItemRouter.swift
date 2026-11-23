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
    @discardableResult func apply(observations: [SignalObservation]) -> [UUID] {
        let complete = observations.filter { $0.read.complete }
        guard !complete.isEmpty, workspace.canChangeWorkspace else { return [] }
        let at = now(), state = workspace.state
        let ids = Set(complete.flatMap(\.signals))
        let signals = state.signals.filter { ids.contains($0.id) && $0.isRunnable }
        let items = Dictionary(complete.flatMap { $0.read.items }.compactMap { item in item.item.identity.map { ($0, item) } },
                               uniquingKeysWith: { first, _ in first })
        // The account each item was read as: who "you" are for the review rule.
        let users = Dictionary(complete.flatMap { observation in observation.read.items.compactMap { item in
            item.item.identity.map { ($0, observation.read.accountUser) }
        } }, uniquingKeysWith: { first, _ in first })
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
                if let item = stage.item.identity.flatMap({ items[$0] }) { stage.prompt = Self.prompt(signal: stage.configuration, item: item) }
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
                    var task = Self.makeTask(item: item, signal: signal, project: project, accountUser: users[match.item.identity ?? ""] ?? nil, at: at)
                    task.signalTask?.pendingStages = pending.map(configured)
                    let candidates = ItemProjectMapper.projects(for: match.item, in: state.projects).map(\.id)
                    task.prepareLaunch(candidates: candidates, at: at)
                    state.tasks.append(task); launches.append(task.id)
                    seen(match.signal, match.item, .started)
                    for stage in pending { seen(stage.signal, stage.item, .started) }
                    events.append((task.id, "A signal matched a new item."))
                case .continueTask(let id, let proposed):
                    let stage = configured(proposed)
                    guard let task = state.signalItem(id: id) else { continue }
                    var record = task.signalTask ?? SignalTask(current: stage, startedAt: at)
                    if task.isUnderOperator {
                        guard let next = try? SignalTransitions.apply(.matched(stage), to: record, at: at,
                                                                      workerIsWorking: workerIsWorking(id)) else { continue }
                        record = next
                    }
                    state.updateSignalItem(id) { task in
                        task.signalTask = record
                        if let item = stage.item.identity.flatMap({ items[$0] }) {
                            if let request = item.mergeRequest { task.mr = MergeRequestRef(iid: request.iid, title: request.title, url: request.url) }
                            if task.jira == nil { task.jira = item.ticket.map(JiraRef.init) }
                        }
                        if record.phase == .launching { task.prepareLaunch(candidates: nil, at: at) }
                    }
                    if state.signalItem(id: id)?.signalTask?.phase == .launching { launches.append(id) }
                    seen(stage.signal, stage.item, .started)
                    let phase = state.signalItem(id: id)?.signalTask?.phase
                    events.append((id, phase == .launching ? "A signal continued this item."
                                   : phase == .choosing ? "A signal continued this item; the Operator chooses its agent." : "A signal queued the next stage."))
                }
            }
            let live = Set(state.allSignalTasks.compactMap { $0.signalTask?.current.item.identity })
            state.signalSeen = SignalSeen.pruned(state.signalSeen, liveItems: live, now: at)
        }
        guard workspace.flush() else { return [] }
        for (id, event) in events { changed(id, event) }
        return Array(Set(launches)).sorted { $0.uuidString < $1.uuidString }
    }
    /// A scheduler pass in one workspace mutation: each due run a new task in its signal's project, each skip recorded
    /// with its reason, and every moved cursor, saved in the same flush. The ids of the tasks to launch.
    @discardableResult func apply(schedule outcome: ScheduleDecision.Outcome, calendar: Calendar) -> [UUID] {
        guard !(outcome.due.isEmpty && outcome.skipped.isEmpty && outcome.cursors.isEmpty), workspace.canChangeWorkspace else { return [] }
        let at = now(), state = workspace.state
        let matches = outcome.due.map { SignalMatch(signal: $0.signal, item: .run($0.run), project: $0.project, matchedAt: at) }
        let decisions = MatchDecision.decide(matches: matches, signals: state.signals, tasks: state.tasks + state.archive.map(\.task),
                                             projects: state.projects, seen: state.signalSeen, complete: true)
        var launches: [UUID] = [], events: [(UUID, String)] = []
        workspace.mutate { state in
            for (signal, cursor) in outcome.cursors { state.scheduleCursors[signal] = cursor }
            // A run's cursor, not `signalSeen`, keeps it from starting twice: only its signal's latest skip is kept, for the
            // heading's tooltip, and a started run is not recorded at all.
            func skipped(_ signal: UUID, _ run: SignalRunRef, _ reason: String) {
                state.signalSeen.removeAll { seen in
                    guard seen.signal == signal, case .run = seen.item else { return false }
                    return true
                }
                state.signalSeen.append(SignalSeen(signal: signal, item: .run(run), disposition: .skipped, at: at, reason: reason))
                events.append((signal, "Skipped the run of " + ScheduleDecision.runTime(run.at, calendar: calendar) + ": " + reason))
            }
            for skip in outcome.skipped { skipped(skip.signal, skip.run, skip.reason) }
            for decision in decisions {
                switch decision {
                case .start(let match, _):
                    guard case .run(let run) = match.item, let signal = state.signal(id: match.signal), let project = match.project else { continue }
                    var task = Self.makeRunTask(run, signal: signal, project: project, at: at, calendar: calendar)
                    task.prepareLaunch(candidates: [project], at: at)
                    state.tasks.append(task); launches.append(task.id)
                    events.append((task.id, "A schedule started a run due " + ScheduleDecision.runTime(run.at, calendar: calendar) + "."))
                case .skip(let match, let reason):
                    if case .run(let run) = match.item { skipped(match.signal, run, reason) }
                case .continueTask: continue
                }
            }
        }
        guard workspace.flush() else { return [] }
        for (id, event) in events { changed(id, event) }
        return launches
    }
    /// A run's task: titled with its scheduled time, on a branch of its own, with the prompt alone (a run has no ticket
    /// or merge request) and its origin kept for good.
    nonisolated static func makeRunTask(_ run: SignalRunRef, signal: Signal, project: UUID, at: Date, calendar: Calendar) -> TaskItem {
        let agent = signal.agents.first ?? AgentChoice(agent: .claude, model: "", reasoning: nil)
        let title = ScheduleDecision.runTitle(signalName: signal.name, at: run.at, calendar: calendar)
        var task = TaskItem(id: UUID(), projectId: project, title: title,
                            branch: BranchNaming.runBranch(signalName: signal.name, signal: signal.id, at: run.at),
                            worktreePath: "", baseBranch: "", jira: nil, kind: .task, mr: nil,
                            agent: agent.agent, model: agent.model, reasoning: agent.reasoning, firstPrompt: nil,
                            appendTicket: false, createdAt: at, windowId: nil)
        let stage = SignalStage(signal: signal.id, item: .run(run), matchedAt: at, configuration: signal, prompt: signal.work.prompt)
        var record = SignalTask(current: stage, startedAt: at)
        record.scheduledRun = run
        task.signalTask = record
        return task
    }
    nonisolated private static func prompt(signal: Signal, item: SignalItem) -> String {
        signal.work.workerPrompt(ticket: item.ticket?.description ?? (item.mergeRequest == nil ? item.description : nil),
                                 request: item.mergeRequest?.description ?? (item.ticket == nil ? item.description : nil))
    }
    nonisolated private static func makeTask(item: SignalItem, signal: Signal, project: UUID, accountUser: String?, at: Date) -> TaskItem {
        let agent = signal.agents.first ?? AgentChoice(agent: .claude, model: "", reasoning: nil)
        var draft = TaskDraft(ticket: nil, baseBranch: "", agent: agent.agent, model: agent.model, reasoning: agent.reasoning)
        draft.apply(ticket: item.ticket); draft.setTitle(item.title)
        let branch = item.mergeRequest?.sourceBranch ?? draft.branch
        let review = isReview(item, accountUser: accountUser)
        var task = TaskItem(id: UUID(), projectId: project, title: item.title, branch: branch, worktreePath: "",
                            baseBranch: item.mergeRequest?.targetBranch ?? "", jira: item.ticket.map(JiraRef.init),
                            kind: review ? .review : .task,
                            mr: item.mergeRequest.map { MergeRequestRef(iid: $0.iid, title: $0.title, url: $0.url) },
                            agent: agent.agent, model: agent.model, reasoning: agent.reasoning, firstPrompt: nil,
                            appendTicket: false, createdAt: at, windowId: nil)
        let stage = SignalStage(signal: signal.id, item: item.item, matchedAt: at, configuration: signal, prompt: prompt(signal: signal, item: item))
        task.signalTask = SignalTask(current: stage, startedAt: at)
        return task
    }
    /// A merge request is a review task, which never pushes, unless the account authored it or is one of its assignees.
    /// A ticket is always the account's own task, even once it has a merge request.
    nonisolated static func isReview(_ item: SignalItem, accountUser: String?) -> Bool {
        switch item.item {
        case .ticket, .run: return false
        case .mergeRequest:
            guard let user = accountUser else { return true }
            let yours = { (name: String?) in name?.caseInsensitiveCompare(user) == .orderedSame }
            return !(yours(item.mergeRequest?.author) || item.assignees.contains(where: yours))
        case .unknown: return true
        }
    }
}
