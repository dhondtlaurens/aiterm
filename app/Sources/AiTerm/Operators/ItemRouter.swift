import Foundation
import AiTermCore

/// A project signal's decided pick-up, waiting for its create (`ProjectSignals`): nothing about it is saved until its
/// task is, so a quit loses only the queue and the next full read decides the item again.
struct ProjectPickup: Equatable {
    var signal: UUID
    var item: SignalItem
    var project: UUID
    /// The account the item was read as: who "you" are for the review rule.
    var accountUser: String?
    var matchedAt: Date
    /// Where its signal read the item when it was decided (`schedule` for a run): a signal edited to read elsewhere no
    /// longer makes it.
    var source: SignalTrigger.Source
    /// The item's identity, which claims it from Operator signals while the pick-up waits.
    var identity: String { item.item.identity ?? "" }
    /// One pick-up per signal and item.
    var key: String { signal.uuidString + ":" + identity }
}

/// Complete reads become saved intents in one workspace mutation. This owner never performs I/O
/// against a project, a worker or an account; StageRunner consumes the returned launch ids and ProjectSignals the
/// returned pick-ups.
@MainActor final class ItemRouter {
    /// What one pass decided: the Operator tasks to launch, the project signals' pick-ups, which wrote nothing, and the
    /// tasks a project signal's re-match left owing its prompt (`ProjectSignals.deliverSoon`).
    struct Routed: Equatable {
        var launches: [UUID] = []
        var pickups: [ProjectPickup] = []
        var rematches: [UUID] = []
    }
    private let workspace: WorkspaceStore
    private let now: () -> Date
    private let workerIsWorking: @MainActor (UUID) -> Bool
    /// The Operator's events: written to its activity log, and they may wake it.
    var changed: (UUID, String) -> Void = { _, _ in }
    /// A project signal's events (a skip), the person's and never the Operator's: no activity record and no wake.
    var projectChanged: (UUID, String) -> Void = { _, _ in }
    /// The identities project pick-ups hold (queued, under way or backing off), which no Operator signal takes.
    var claimed: @MainActor () -> Set<String> = { [] }
    init(workspace: WorkspaceStore, now: @escaping () -> Date, workerIsWorking: @escaping @MainActor (UUID) -> Bool = { _ in false }) {
        self.workspace = workspace; self.now = now; self.workerIsWorking = workerIsWorking
    }
    /// The Operator tasks to launch; a project signal's pick-ups are dropped (`route` returns them).
    @discardableResult func apply(observations: [SignalObservation]) -> [UUID] { route(observations: observations).launches }
    @discardableResult func route(observations: [SignalObservation]) -> Routed {
        let complete = observations.filter { $0.read.complete }
        guard !complete.isEmpty, workspace.canChangeWorkspace else { return Routed() }
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
                            matchedAt: at, branch: item.mergeRequest?.sourceBranch, fromFork: item.mergeRequest?.forkHead != nil)
            } }
        }
        let decisions = MatchDecision.decide(matches: matches, signals: signals, tasks: state.tasks + state.archive.map(\.task),
                                             projects: state.projects, seen: state.signalSeen, complete: true, claimed: claimed())
        var launches: [UUID] = [], pickups: [ProjectPickup] = [], events: [(UUID, String)] = [], projectEvents: [(UUID, String)] = []
        var rematches: [UUID] = []
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
                        let event = (match.signal, "Skipped " + (match.item.identity ?? "unknown item") + ": " + reason)
                        if state.signal(id: match.signal)?.isProject == true { projectEvents.append(event) } else { events.append(event) }
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
                // Nothing is written for a pick-up: its started record lands with its task (`ProjectSignals`).
                case .startOrdinary(let match):
                    guard let signal = state.signal(id: match.signal), let project = match.project, let identity = match.item.identity,
                          let item = items[identity] else { continue }
                    pickups.append(ProjectPickup(signal: match.signal, item: item, project: project,
                                                 accountUser: users[identity] ?? nil, matchedAt: at, source: signal.start.source))
                // Its own task, or one made by hand (O1): marked with the signal and owing the newly composed prompt, in
                // this change with the started record, which replaces a held baseline's skip.
                case .rematch(let id, let match):
                    if let signal = state.signal(id: match.signal), let identity = match.item.identity, let item = items[identity],
                       let task = state.signalItem(id: id) {
                        let pickup = ProjectPickup(signal: signal.id, item: item, project: task.projectId,
                                                   accountUser: users[identity] ?? nil, matchedAt: at, source: signal.start.source)
                        // Composed here, once: the descriptions' JSON is not the same text twice.
                        let text = Self.pickupKind(pickup, signal: signal, baseBranch: "")?.prompt ?? signal.work.prompt
                        state.updateSignalItem(id) { task in
                            task.signalOrigin = Self.rematched(task.signalOrigin, signal: signal, item: match.item, prompt: text, at: at)
                            // The matched item's request is the task's from now, as a continued Operator task's is: a later
                            // request on the same branch would otherwise be read, and end Done, by the earlier one.
                            if let request = item.mergeRequest { task.mr = MergeRequestRef(iid: request.iid, title: request.title, url: request.url) }
                            if task.jira == nil { task.jira = item.ticket.map(JiraRef.init) }
                        }
                        rematches.append(id)
                    }
                    seen(match.signal, match.item, .started)
                }
            }
            let live = Set(state.allSignalTasks.compactMap { $0.signalTask?.current.item.identity }).union(state.markedItems)
            state.signalSeen = SignalSeen.pruned(state.signalSeen, liveItems: live, now: at, projectSignals: state.projectSignalIds)
        }
        guard workspace.flush() else { return Routed() }
        for (id, event) in events { changed(id, event) }
        for (id, event) in projectEvents { projectChanged(id, event) }
        return Routed(launches: Array(Set(launches)).sorted { $0.uuidString < $1.uuidString }, pickups: pickups, rematches: rematches)
    }

    /// A task's origin once `signal` matched `item` again: a hand-made task's first, an earlier signal's moved into
    /// `earlier`; owing `prompt` as a delivery, which replaces any prompt still owed; Done an edge again and Then to run
    /// again, as `StageMachine.continueStage` clears `thenApplied`; the turn and its notification for the next prompt.
    nonisolated static func rematched(_ origin: SignalOrigin?, signal: Signal, item: ItemRef, prompt: String, at: Date) -> SignalOrigin {
        var origin = origin ?? SignalOrigin(signal: signal.id, name: signal.name, item: item, startedAt: at)
        if origin.signal != signal.id {
            origin.earlier = (origin.earlier ?? []) + [SignalStep(signal: origin.signal, name: origin.name, at: origin.startedAt)]
            origin.signal = signal.id; origin.startedAt = at
        }
        origin.name = signal.name; origin.item = item
        origin.owed = OwedPrompt(text: prompt, at: at, kind: .delivery)
        origin.doneKey = nil; origin.doneMatched = nil; origin.doneAt = nil
        origin.thenApplied = nil; origin.thenNote = nil
        origin.turn = nil; origin.notifiedAt = nil
        return origin
    }
    /// A scheduler pass in one workspace mutation: each due run of an Operator signal a new task in its signal's project,
    /// each due run of a project signal a pick-up (written nothing: `ProjectSignals` makes its task), each skip recorded
    /// with its reason, and every moved cursor, saved in the same flush. The moved cursor, not a record, keeps a run from
    /// starting twice, so a project run's pick-up is never decided again.
    @discardableResult func apply(schedule outcome: ScheduleDecision.Outcome, calendar: Calendar) -> Routed {
        guard !(outcome.due.isEmpty && outcome.skipped.isEmpty && outcome.cursors.isEmpty), workspace.canChangeWorkspace else { return Routed() }
        let at = now(), state = workspace.state
        let matches = outcome.due.map { SignalMatch(signal: $0.signal, item: .run($0.run), project: $0.project, matchedAt: at) }
        let decisions = MatchDecision.decide(matches: matches, signals: state.signals, tasks: state.tasks + state.archive.map(\.task),
                                             projects: state.projects, seen: state.signalSeen, complete: true)
        var launches: [UUID] = [], pickups: [ProjectPickup] = [], events: [(UUID, String)] = [], projectEvents: [(UUID, String)] = []
        workspace.mutate { state in
            for (signal, cursor) in outcome.cursors { state.scheduleCursors[signal] = cursor }
            // A run's cursor, not `signalSeen`, keeps it from starting twice: only its signal's latest skip is kept, for the
            // heading's tooltip, and a started run is not recorded at all.
            func skipped(_ signal: UUID, _ run: SignalRunRef, _ reason: String) {
                Self.recordRunSkip(signal: signal, run: run, reason: reason, at: at, in: &state)
                let event = (signal, Self.runSkipEvent(run, reason: reason, calendar: calendar))
                if state.signal(id: signal)?.isProject == true { projectEvents.append(event) } else { events.append(event) }
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
                // A project signal's run: an ordinary task on a run branch, made by `ProjectSignals`.
                case .startOrdinary(let match):
                    guard case .run(let run) = match.item, let signal = state.signal(id: match.signal), let project = match.project else { continue }
                    let title = ScheduleDecision.runTitle(signalName: signal.name, at: run.at, calendar: calendar)
                    pickups.append(ProjectPickup(signal: signal.id, item: SignalItem(item: match.item, title: title), project: project,
                                                 accountUser: nil, matchedAt: at, source: signal.start.source))
                case .skip(let match, let reason):
                    if case .run(let run) = match.item { skipped(match.signal, run, reason) }
                case .continueTask, .rematch: continue
                }
            }
        }
        guard workspace.flush() else { return Routed() }
        for (id, event) in events { changed(id, event) }
        for (id, event) in projectEvents { projectChanged(id, event) }
        return Routed(launches: launches, pickups: pickups)
    }
    /// `signal`'s run skipped in `state`, the signal's one run record: only its latest skip is kept, for the heading's tooltip.
    nonisolated static func recordRunSkip(signal: UUID, run: SignalRunRef, reason: String, at: Date, in state: inout AppState) {
        state.signalSeen.removeAll { seen in
            guard seen.signal == signal, case .run = seen.item else { return false }
            return true
        }
        state.signalSeen.append(SignalSeen(signal: signal, item: .run(run), disposition: .skipped, at: at, reason: reason))
    }
    nonisolated static func runSkipEvent(_ run: SignalRunRef, reason: String, calendar: Calendar) -> String {
        "Skipped the run of " + ScheduleDecision.runTime(run.at, calendar: calendar) + ": " + reason
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
    /// What a project signal's pick-up creates, as `makeTask` reads the item: a merge request someone else asked the account
    /// to review is a review; the account's own request is its source branch checked out as a task; a ticket is a new
    /// task on `baseBranch`, and a scheduled run a new task on its run branch from `baseBranch`. The signal's one agent row,
    /// its bare prompt and its two description switches: the create composes the prompt once
    /// (`TaskLauncher.UnattendedCreate.prompt`). Nil for an unknown item.
    nonisolated static func pickupKind(_ pickup: ProjectPickup, signal: Signal, baseBranch: String) -> TaskLauncher.UnattendedCreate.Kind? {
        let agent = signal.agents.first ?? AgentChoice(agent: .claude, model: "", reasoning: nil)
        let item = pickup.item
        switch item.item {
        case .mergeRequest:
            guard let request = item.mergeRequest else { return nil }
            var draft = ReviewDraft(mr: nil, agent: agent.agent, model: agent.model, reasoning: agent.reasoning)
            draft.apply(mr: request)
            if let ticket = item.ticket { draft.apply(ticket: ticket) }
            draft.promptText = signal.work.prompt
            draft.appendTicket = signal.work.ticketDescription; draft.appendRequest = signal.work.requestDescription
            return isReview(item, accountUser: pickup.accountUser) ? .review(draft) : .ownRequest(draft)
        case .ticket:
            var draft = TaskDraft(ticket: nil, baseBranch: baseBranch, agent: agent.agent, model: agent.model, reasoning: agent.reasoning)
            draft.apply(ticket: item.ticket); draft.setTitle(item.title)
            draft.promptText = signal.work.prompt
            draft.appendTicket = signal.work.ticketDescription
            return .task(draft)
        // A scheduled run: titled with its time (the router's `item.title`), on a run branch from the default branch,
        // with the bare prompt (a run has no ticket or merge request to describe).
        case .run(let run):
            var draft = TaskDraft(ticket: nil, baseBranch: baseBranch, agent: agent.agent, model: agent.model, reasoning: agent.reasoning)
            draft.setTitle(item.title)
            draft.setFullBranch(BranchNaming.runBranch(signalName: signal.name, signal: signal.id, at: run.at))
            draft.promptText = signal.work.prompt
            draft.appendTicket = false
            return .run(draft)
        case .unknown: return nil
        }
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
