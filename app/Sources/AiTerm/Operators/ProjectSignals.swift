import Foundation
import AiTermCore

/// A project signal's pick-ups, from the decided match to the task's first window: one queue and one runner per project,
/// a create in that project's turn (`TaskLauncher.createUnattended`), then the window opened behind, in the person's
/// pause and the one window turn. Nothing is saved for a pick-up until its task is: the row, its origin owing the first
/// prompt and the item's started record land in one change, and the window's id and the cleared debt in another. A
/// quit loses only the queue; a task still owing its launch is queued again by `tick`.
///
/// A scheduled run's pick-up is decided once, since its cursor moved when it was due: a create that fails is queued again
/// after the back-off, up to `runRetries` times, then skipped for good with its reason. A quit loses a queued run, as a
/// time missed while AiTerm was closed is dropped. A queued run the re-check drops (its signal switched off or edited so
/// it no longer makes the run, its project gone) is recorded as the signal's run skip with its reason.
///
/// With Done "A query matches", the task's Done baseline is read and saved before any window opens (`baseline`): the
/// watch (`ProjectSignalWatch`) then sees a Done reached during the first turn as an edge. A read that fails holds the
/// launch, the task still owing its prompt, for `SignalPoller.failureBackOff`.
///
/// A re-match leaves its task owing the prompt as a delivery (`ItemRouter`), which `tick`, the router's `deliverSoon` and
/// every change to the tabs try: an archived task is restored first; the Done baseline is read before anything is typed;
/// a worker whose turn ended with nothing holding it gets the text typed, guarded against the person's keys; a task with
/// no agent listed gets its window opened behind (or a background tab in its open window), in the person's pause and the
/// window turn, resuming its first conversation with the prompt. A worker at work, asking, or with words of yours in
/// flight keeps it owed, with no limit; a refusal waits for the next tick. Only a delivery result clears it.
///
/// The turn a signal's prompt started is watched on every change to the tabs (`watchTurns`): once a session of the task
/// was seen working after the prompt was sent, its worker asking or its turn ending with nothing holding it posts one
/// note, `notifiedAt` saved first. Choosing the row or the task going takes the note back.
///
/// Every effect goes through `ports`, which the app sets from its launcher; all work starts through `work`.
@MainActor final class ProjectSignals {
    struct Ports {
        /// The task's row made without the person, saved with what the request writes.
        var create: @MainActor (TaskLauncher.UnattendedCreate) async throws -> UUID = { _ in
            throw ActionUnavailable("Creating a task is unavailable.")
        }
        /// The task's window opened behind with its agent started on the prompt, once everything it awaits is done and the
        /// third argument, looked at last with no await before the window is asked for, still allows it; false when it did
        /// not, and nothing opened. The fourth argument runs in the change that records the window.
        var open: @MainActor (UUID, String, @MainActor () -> Bool, @escaping @MainActor (inout AppState) -> Void) async throws -> Bool = { _, _, _, _ in
            throw ActionUnavailable("Opening a task is unavailable.")
        }
        /// An archived task's row back in the sidebar (re-match delivery).
        var restore: @MainActor (UUID) async throws -> Void = { _ in throw ActionUnavailable("Restore is unavailable.") }
        /// A re-match's prompt typed into a session whose turn ended (the session, the text, the task's worktree): by the
        /// helper's guarded delivery, with ownership 0, so it waits while the person types there or has words unsent.
        var deliver: @MainActor (String, String, String?) async throws -> Delivery = { _, _, _ in
            throw ActionUnavailable("Delivery is unavailable.")
        }
        /// The project's default branch, a ticket's task's base, read off the main actor.
        var defaultBranch: @MainActor (Project) async -> String = { _ in Repository.fallbackDefaultBranch }
    }
    struct Context {
        /// The Operator's runtime is running: stopped, nothing starts.
        var running: @MainActor () -> Bool = { true }
        /// The helper is there and iTerm2's tabs are known: until then the runners wait.
        var ready: @MainActor () -> Bool = { true }
    }
    private enum Job: Equatable {
        case create(ProjectPickup)
        /// A task that owes its first prompt: its window, in the person's pause.
        case launch(UUID)
    }
    private enum Created { case made(UUID), busy, ended }

    let workspace: WorkspaceStore, live: LiveSessions, work: OperatorWork, pause: PauseGate
    private let now: () -> Date
    private let context: Context
    var ports = Ports()
    /// A project signal's Done read for a task: the controller's host, scripted in tests.
    var readDone: @MainActor (TaskItem, SignalTrigger, ItemRef) async throws -> DoneCheck.Facts = { _, _, _ in
        throw ActionUnavailable("Reading a Done trigger is unavailable.")
    }
    /// A pick-up's events (a create that failed), the person's and never the Operator's.
    var changed: (UUID, String) -> Void = { _, _ in }
    /// Where a turn's note is posted and taken back: the Operator's notifications.
    var notifications: (any OperatorNotifications)?
    /// The tasks whose turn note was posted, as the workspace last had them: one that goes takes its note with it.
    private var noted: Set<UUID> = []
    private var workspaceHook: WorkspaceStore.Hook?
    private var queues: [UUID: [Job]] = [:]
    private var runners: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Each project's job its runner is on.
    private var underWay: [UUID: Job] = [:]
    /// The pick-ups whose create failed, by key, with their item's identity, until they may be tried again.
    private var backingOff: [String: (identity: String, until: Date)] = [:]
    /// The scheduled runs whose create failed, by key, until they are queued again, and each one's failures so far.
    private var runsBackingOff: [String: (pickup: ProjectPickup, until: Date)] = [:]
    private var runFailures: [String: Int] = [:]
    /// How many times a run's failed create is tried again before the run is skipped for good.
    static let runRetries = 3
    /// The tasks whose window failed to open, until they may be tried again.
    private var launchBackOff: [UUID: Date] = [:]
    /// The rows the person chose while they owed their launch: their wait for the pause ends.
    private var chosen: Set<UUID> = []
    /// The launches the person's choosing started, by task, for the row's open to await.
    private var chosenLaunches: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    /// The tasks whose Done baseline could not be read, until it may be read again: their prompt waits.
    private var baselineHeld: [UUID: Date] = [:]
    /// The re-match deliveries under way, by task.
    private var delivering: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    /// The tasks whose delivery the helper refused: tried again at the next tick, not on every change to the tabs.
    private var refused: Set<UUID> = []
    /// The tasks whose restore or window failed, until they may be tried again.
    private var deliveryBackOff: [UUID: Date] = [:]

    init(workspace: WorkspaceStore, live: LiveSessions, work: OperatorWork, pause: PauseGate, now: @escaping () -> Date,
         context: Context) {
        self.workspace = workspace; self.live = live; self.work = work; self.pause = pause; self.now = now; self.context = context
        live.onSessionsChanged { [weak self] _ in self?.sessionsChanged() }
        workspaceHook = workspace.onChange { [weak self] in self?.withdrawGone() }
    }

    isolated deinit {
        if let workspaceHook { workspace.removeHook(workspaceHook) }
    }

    /// The identities pick-ups hold, queued, under way or backing off: no Operator signal takes them meanwhile.
    var claimed: Set<String> {
        var identities = Set(backingOff.values.map(\.identity))
        for job in queues.values.flatMap({ $0 }) + Array(underWay.values) {
            if case .create(let pickup) = job { identities.insert(pickup.identity) }
        }
        return identities
    }

    /// The signals with a scheduled run queued, being created or waiting to be tried again, which has no task yet: their
    /// next time is skipped as unfinished (`ScheduleDecision.previousRunUnfinished`).
    var pendingRuns: Set<UUID> {
        var signals = Set(runsBackingOff.values.map(\.pickup.signal))
        for job in queues.values.flatMap({ $0 }) + Array(underWay.values) {
            if case .create(let pickup) = job, pickup.item.item.isRun { signals.insert(pickup.signal) }
        }
        return signals
    }

    /// Queues `pickup` behind its project's others, unless the same signal and item is queued, under way or backing off,
    /// and starts the project's runner.
    func enqueue(_ pickup: ProjectPickup) {
        guard !pickup.identity.isEmpty, context.running() else { return }
        if let off = backingOff[pickup.key], off.until > now() { return }
        let held = queues.values.flatMap { $0 } + Array(underWay.values)
        guard !held.contains(where: { if case .create(let other) = $0 { other.key == pickup.key } else { false } }) else { return }
        queues[pickup.project, default: []].append(.create(pickup))
        startRunner(pickup.project)
    }

    /// Drops every queued pick-up that a full read of its signal no longer lists: the item left the query.
    func drop(notListed observations: [SignalObservation]) {
        for observation in observations where observation.read.complete && observation.read.full {
            let listed = Set(observation.read.items.compactMap { $0.item.identity })
            for project in queues.keys {
                queues[project]?.removeAll { job in
                    guard case .create(let pickup) = job else { return false }
                    return observation.signals.contains(pickup.signal) && !listed.contains(pickup.identity)
                }
            }
        }
    }

    /// The person chose task `id`'s row while it has no window: a task that owes its launch opens at once, its wait for
    /// the pause ended, outside its project's queue, which only creates hold. The launch, for the row's open to await
    /// and then raise its window; a second choose joins it. Nil for any other task.
    func choose(_ id: UUID) -> Task<Void, Never>? {
        guard context.running(), let task = workspace.state.task(id: id), task.signalOrigin?.owed?.kind == .launch else { return nil }
        if let running = chosenLaunches[id] { return running.task }
        chosen.insert(id)
        launchBackOff[id] = nil; baselineHeld[id] = nil
        queues[task.projectId]?.removeAll { $0 == .launch(id) }
        let token = UUID()
        let running = work.start { [weak self] in
            // A runner's launch of it under way meanwhile stops waiting for the pause; the window turn and the owed
            // prompt let only one of the two open it.
            await self?.launch(id)
            if self?.chosenLaunches[id]?.id == token { self?.chosenLaunches[id] = nil }
        }
        chosenLaunches[id] = (token, running)
        return running
    }

    /// The tick's step: back-offs that ran out end; a task still owing its launch is taken as launched when an agent of
    /// its own runs or it has a conversation (a launch whose answer was lost), and otherwise queued again; every project
    /// with a queue gets its runner.
    func tick() {
        guard context.running() else { return }
        let at = now()
        backingOff = backingOff.filter { $0.value.until > at }
        launchBackOff = launchBackOff.filter { $0.value > at }
        baselineHeld = baselineHeld.filter { $0.value > at }
        for (key, off) in runsBackingOff where off.until <= at {
            runsBackingOff[key] = nil
            queues[off.pickup.project, default: []].append(.create(off.pickup))
        }
        for task in workspace.state.tasks where task.signalOrigin?.owed?.kind == .launch && !holds(task.id) {
            if launched(task) { markLaunched(task.id); continue }
            guard launchBackOff[task.id] == nil, baselineHeld[task.id] == nil, !switchedOff(task) else { continue }
            queues[task.projectId, default: []].append(.launch(task.id))
        }
        for project in queues.keys where queues[project]?.isEmpty == false { startRunner(project) }
        // The re-matches' deliveries: a refusal and a back-off that ran out are tried again.
        refused.removeAll()
        deliveryBackOff = deliveryBackOff.filter { $0.value > at }
        let state = workspace.state
        for task in state.tasks + state.archive.map(\.task) where task.signalOrigin?.owed?.kind == .delivery { startDelivery(task.id) }
        // The tabs as the first snapshot left them, which may have come before they were known: a turn that ended meanwhile.
        watchTurns()
    }

    /// Cancels every runner and forgets the queues: nothing queued was saved, and a queued run is lost.
    func stop() {
        for runner in runners.values { runner.task.cancel() }
        runners.removeAll(); queues.removeAll(); underWay.removeAll(); chosen.removeAll()
        for launch in chosenLaunches.values { launch.task.cancel() }
        chosenLaunches.removeAll()
        runsBackingOff.removeAll(); runFailures.removeAll(); baselineHeld.removeAll()
        for delivery in delivering.values { delivery.task.cancel() }
        delivering.removeAll(); refused.removeAll(); deliveryBackOff.removeAll()
    }

    // -- the runner -----------------------------------------------------------------
    private func startRunner(_ project: UUID) {
        guard runners[project] == nil, context.running(), context.ready(), queues[project]?.isEmpty == false else { return }
        let id = UUID()
        runners[project] = (id, work.start { [weak self] in
            await self?.run(project)
            // A runner stopped meanwhile leaves its successor's handle alone.
            if self?.runners[project]?.id == id { self?.runners[project] = nil }
        })
    }

    /// Takes `project`'s queue in order while the runtime runs and the helper and tabs are there; what is left waits for
    /// the next tick.
    private func run(_ project: UUID) async {
        while !Task.isCancelled, context.running(), context.ready(), let job = queues[project]?.first {
            queues[project]?.removeFirst()
            underWay[project] = job
            defer { underWay[project] = nil }
            switch job {
            case .create(let pickup):
                switch await create(pickup) {
                case .made(let id):
                    underWay[project] = .launch(id)
                    await launch(id)
                case .busy:
                    // The person, or another pick-up's create, holds the project: tried again at the next tick.
                    queues[project, default: []].insert(job, at: 0)
                    return
                case .ended: break
                }
            case .launch(let id): await launch(id)
            }
        }
    }

    /// The pick-up's task made, after checking again that it still should be: its signal exists, runs and is a project
    /// signal, its project exists, the item is not a fork's and no task holds it. A create that fails is recorded as the
    /// item's skip with its reason and not tried for `SignalPoller.failureBackOff`; a run's is queued again after it.
    private func create(_ pickup: ProjectPickup) async -> Created {
        guard stillWanted(pickup) != nil, let read = workspace.state.project(id: pickup.project) else {
            runFailures[pickup.key] = nil
            droppedRun(pickup)
            return .ended
        }
        let item = pickup.item.item
        let base = item.isTicket || item.isRun ? await ports.defaultBranch(read) : ""
        guard context.running(), let signal = stillWanted(pickup), let project = workspace.state.project(id: pickup.project),
              let kind = ItemRouter.pickupKind(pickup, signal: signal, baseBranch: base) else {
            runFailures[pickup.key] = nil
            if context.running() { droppedRun(pickup) }
            return .ended
        }
        let at = now()
        // Composed here, once: the descriptions' JSON is not the same text twice.
        let composed = TaskLauncher.UnattendedCreate(project: project, kind: kind, saving: { _, _ in }).prompt ?? ""
        let request = TaskLauncher.UnattendedCreate(project: project, kind: kind, saving: { state, id in
            state.updateSignalItem(id) { task in
                task.signalOrigin = SignalOrigin(signal: signal.id, name: signal.name, item: item, startedAt: at,
                                                 owed: OwedPrompt(text: composed, at: at, kind: .launch))
            }
            // A run's cursor keeps it from starting twice; an item's started record does.
            guard !item.isRun else { return }
            state.signalSeen.removeAll { $0.signal == signal.id && $0.item.identity == item.identity }
            state.signalSeen.append(SignalSeen(signal: signal.id, item: item, disposition: .started, at: at))
        })
        do {
            let id = try await ports.create(request)
            runFailures[pickup.key] = nil
            return .made(id)
        } catch is CreationBusy {
            return .busy
        } catch {
            guard context.running() else { return .ended }
            let reason = "Couldn’t start its task: " + OperationIssue.reason(of: error)
            if case .run(let run) = item {
                failedRun(pickup, run: run, reason: reason)
                return .ended
            }
            backingOff[pickup.key] = (pickup.identity, now().addingTimeInterval(SignalPoller.failureBackOff))
            if workspace.canChangeWorkspace {
                workspace.mutate { state in
                    state.signalSeen.removeAll { $0.signal == signal.id && $0.item.identity == item.identity }
                    state.signalSeen.append(SignalSeen(signal: signal.id, item: item, disposition: .skipped, at: now(), reason: reason))
                }
                workspace.flush()
            }
            changed(signal.id, "Skipped " + pickup.identity + ": " + reason)
            return .ended
        }
    }

    /// A run's create failed: queued again by a tick after the back-off, or, after `runRetries` tries again, skipped for
    /// good with `reason` as the signal's run skip (the next scheduled time is a new run).
    private func failedRun(_ pickup: ProjectPickup, run: SignalRunRef, reason: String) {
        let failures = runFailures[pickup.key, default: 0] + 1
        guard failures > Self.runRetries else {
            runFailures[pickup.key] = failures
            runsBackingOff[pickup.key] = (pickup, now().addingTimeInterval(SignalPoller.failureBackOff))
            changed(pickup.signal, "Couldn’t start the run of " + pickup.item.title + ", tried again later: " + reason)
            return
        }
        runFailures[pickup.key] = nil
        if workspace.canChangeWorkspace {
            workspace.mutate { ItemRouter.recordRunSkip(signal: pickup.signal, run: run, reason: reason, at: now(), in: &$0) }
            workspace.flush()
        }
        changed(pickup.signal, "Skipped the run of " + pickup.item.title + ": " + reason)
    }

    /// A queued run the re-check dropped, recorded as its signal's run skip with the reason, so the person sees why it
    /// did not start. Nothing is recorded for a removed signal, or for a run whose task exists.
    private func droppedRun(_ pickup: ProjectPickup) {
        guard case .run(let run) = pickup.item.item, workspace.canChangeWorkspace,
              let signal = workspace.state.signal(id: pickup.signal) else { return }
        let state = workspace.state
        let reason: String
        if (state.tasks + state.archive.map(\.task)).contains(where: { MatchDecision.matchesItem(pickup.item.item, task: $0) }) { return }
        else if state.project(id: pickup.project) == nil { reason = ScheduleDecision.projectGone }
        else if !signal.enabled { reason = Self.switchedOffReason }
        else { reason = Self.changedReason }
        workspace.mutate { ItemRouter.recordRunSkip(signal: signal.id, run: run, reason: reason, at: now(), in: &$0) }
        workspace.flush()
        changed(signal.id, "Skipped the run of " + pickup.item.title + ": " + reason)
    }
    static let switchedOffReason = "Its signal was switched off before its task was made."
    static let changedReason = "Its signal changed before its task was made."

    /// The pick-up's signal when it should still be made: a runnable project signal that still makes it (reading from the
    /// same source, and its project mapping, or a run's schedule, still naming the pick-up's project), its project there,
    /// the item not a fork's, a run not timed before the schedule was last saved anew (`scheduledFrom`: its cron edited
    /// while the run was queued), and no task, in the sidebar or archived, holding it.
    private func stillWanted(_ pickup: ProjectPickup) -> Signal? {
        let state = workspace.state
        guard let signal = state.signal(id: pickup.signal), signal.isProject, signal.isRunnable, signal.start.source == pickup.source,
              !Self.predatesSchedule(pickup, signal),
              // The mapping must still name this project alone: with a second candidate the first decision would have
              // skipped the item rather than guess, so a queued pick-up does not guess either.
              ItemProjectMapper.projects(for: pickup.item.item, in: state.projects, signals: state.signals).map(\.id) == [pickup.project],
              pickup.item.mergeRequest?.forkHead == nil else { return nil }
        let branch = pickup.item.mergeRequest?.sourceBranch
        let held = (state.tasks + state.archive.map(\.task)).contains { task in
            MatchDecision.matchesItem(pickup.item.item, task: task)
                || (branch != nil && task.branch == branch && task.projectId == pickup.project)
        }
        return held ? nil : signal
    }

    /// Whether `pickup` is a run timed before `signal`'s schedule was last saved anew: a time of the cron it had then.
    private static func predatesSchedule(_ pickup: ProjectPickup, _ signal: Signal) -> Bool {
        guard case .run(let run) = pickup.item.item else { return false }
        return run.at < (signal.scheduledFrom ?? signal.createdAt)
    }

    /// Task `id`'s window, opened behind with its owed prompt once the person has paused, in the one window turn (shared
    /// with the Operator), with a last look at the pause in the turn and no await of this owner between it and the open.
    /// Choosing the row ends the wait. The window's id, the cleared debt and the turn's start land in one change.
    private func launch(_ id: UUID) async {
        while !Task.isCancelled, context.running(), context.ready() {
            guard let task = workspace.state.task(id: id), let owed = task.signalOrigin?.owed, owed.kind == .launch,
                  !switchedOff(task) else { chosen.remove(id); return }
            if launched(task) { markLaunched(id); chosen.remove(id); return }
            // The Done baseline is saved before any window opens; a read that fails holds the launch.
            guard await baseline(id) else { chosen.remove(id); return }
            if !pause.isQuiet && !chosen.contains(id) {
                await pause.quiet(while: { [weak self] in self?.waitsForPause(id) == true })
                continue
            }
            let pause = pause
            let done: Bool = await pause.turn.take {
                guard pause.isQuiet || self.chosen.contains(id) else { return false }
                guard self.context.running(), let current = self.workspace.state.task(id: id),
                      current.signalOrigin?.owed == owed, !self.switchedOff(current) else { return true }
                do {
                    // The pause, and the signal still on, looked at once more after the open's own awaits, none between
                    // that look and the window.
                    guard try await self.ports.open(id, owed.text, {
                        (pause.isQuiet || self.chosen.contains(id)) && self.workspace.state.task(id: id).map { !self.switchedOff($0) } == true
                    },
                                                    { state in Self.clearLaunch(id, in: &state, at: self.now()) }) else { return false }
                    self.workspace.flush()
                    // Working seen while the open awaited its reply, its prompt still owed then, counts for the turn.
                    self.watchTurns()
                } catch {
                    // Tried again by a tick after the back-off, or at once when the person chooses the row.
                    self.launchBackOff[id] = self.now().addingTimeInterval(SignalPoller.failureBackOff)
                    self.changed(current.signalOrigin?.signal ?? id, "Couldn’t open " + current.title + ": " + OperationIssue.reason(of: error))
                }
                return true
            }
            if done { chosen.remove(id); return }
        }
    }

    /// Reads and saves task `id`'s Done baseline, its `doneKey` and `doneMatched` in one change, before a prompt of its
    /// signal reaches its worker: the launch calls it before its pause wait, a re-match's delivery before it types. A
    /// baseline already read for the signal's current Done, a removed signal and a Done the person decides read nothing.
    /// A read that fails holds the prompt, the reason as the item's skipped record (its started record kept), for
    /// `SignalPoller.failureBackOff`; the task keeps owing its prompt. Whether the prompt may go on.
    func baseline(_ id: UUID) async -> Bool {
        guard let task = workspace.state.signalItem(id: id), let origin = task.signalOrigin else { return false }
        guard let signal = workspace.state.signal(id: origin.signal), signal.isProject else { return true }
        let key = SignalOrigin.doneKey(signal.done)
        if origin.doneKey == key { return true }
        if let until = baselineHeld[id], until > now() { return false }
        var matched: Bool?
        if signal.done.source != .person {
            do { matched = try await readDone(task, signal.done, origin.item).doneMatches }
            catch {
                guard context.running(), workspace.canChangeWorkspace, unchanged(id, origin: origin, done: signal.done) else { return false }
                baselineHeld[id] = now().addingTimeInterval(SignalPoller.failureBackOff)
                let reason = "Its Done trigger could not be read: " + OperationIssue.reason(of: error)
                workspace.mutate { state in Self.recordHold(origin, reason: reason, at: now(), in: &state) }
                workspace.flush()
                changed(signal.id, "Held " + task.title + ": " + reason)
                return false
            }
        }
        // A read the task or its signal's Done changed under is not its baseline: the next try reads again.
        guard context.running(), workspace.canChangeWorkspace, unchanged(id, origin: origin, done: signal.done) else { return false }
        baselineHeld[id] = nil
        workspace.mutate { state in
            state.updateSignalItem(id) { $0.signalOrigin?.doneKey = key; $0.signalOrigin?.doneMatched = matched }
            state.signalSeen.removeAll { $0.signal == origin.signal && $0.item.identity == origin.item.identity && $0.disposition == .skipped }
        }
        return workspace.flush()
    }

    /// Task `id` still carries `origin` as it was read, owing the same prompt, and its signal's Done is still `done`.
    private func unchanged(_ id: UUID, origin: SignalOrigin, done: SignalTrigger) -> Bool {
        guard let current = workspace.state.signalItem(id: id)?.signalOrigin else { return false }
        return current.signal == origin.signal && current.item == origin.item && current.startedAt == origin.startedAt
            && current.owed == origin.owed && workspace.state.signal(id: origin.signal)?.done == done
    }

    /// A held baseline's reason as the signal's skipped record of the task's item, beside its started record, which keeps
    /// the item from being decided again; a run's as the signal's run skip.
    private static func recordHold(_ origin: SignalOrigin, reason: String, at: Date, in state: inout AppState) {
        if case .run(let run) = origin.item {
            ItemRouter.recordRunSkip(signal: origin.signal, run: run, reason: reason, at: at, in: &state)
            return
        }
        state.signalSeen.removeAll { $0.signal == origin.signal && $0.item.identity == origin.item.identity && $0.disposition == .skipped }
        state.signalSeen.append(SignalSeen(signal: origin.signal, item: origin.item, disposition: .skipped, at: at, reason: reason))
    }

    private func waitsForPause(_ id: UUID) -> Bool {
        context.running() && !chosen.contains(id) && workspace.state.task(id: id)?.signalOrigin?.owed?.kind == .launch
    }

    /// Whether task `id` is queued or under way, by its project's runner or the person's choosing.
    private func holds(_ id: UUID) -> Bool {
        chosenLaunches[id] != nil || (queues.values.flatMap { $0 } + Array(underWay.values)).contains(.launch(id))
    }

    /// A task's launch already happened: an agent of its own is listed, or it has a saved conversation.
    private func launched(_ task: TaskItem) -> Bool {
        !task.conversations.isEmpty
            || (context.ready() && live.sessions.contains { $0.taskUUID == task.id && $0.agent.agentKind != nil })
    }

    /// Its signal exists and is switched off: the launch waits until it is on.
    private func switchedOff(_ task: TaskItem) -> Bool {
        task.signalOrigin.flatMap { workspace.state.signal(id: $0.signal) }.map { !$0.enabled } ?? false
    }

    /// A launch whose answer was lost, taken as done: no second prompt.
    private func markLaunched(_ id: UUID) {
        guard workspace.canChangeWorkspace else { return }
        workspace.mutate { Self.clearLaunch(id, in: &$0, at: now()) }
        workspace.flush()
    }

    /// Task `id`'s launch done in `state`: its debt cleared and its turn started at `at`. A delivery owed is never cleared here.
    private static func clearLaunch(_ id: UUID, in state: inout AppState, at: Date) {
        state.updateSignalItem(id) { task in
            guard task.signalOrigin?.owed?.kind == .launch else { return }
            task.signalOrigin?.owed = nil
            task.signalOrigin?.turn = SignalTurn(sentAt: at)
        }
    }
}

// -- re-match delivery ------------------------------------------------------------------
extension ProjectSignals {
    /// Where a task's owed delivery goes now: nowhere yet, typed into its first worker, or a window or tab opened for it.
    private enum Route: Equatable { case wait, type(SessionInfo), open }

    /// Task `id` owes a re-match's prompt the router just wrote: its delivery is tried now.
    func deliverSoon(_ id: UUID) { startDelivery(id) }

    /// The tabs changed: a task owing a delivery whose worker may now take it is tried, an archived one waits for the tick.
    private func sessionsChanged() {
        guard context.running(), context.ready() else { return }
        for task in workspace.state.tasks where task.signalOrigin?.owed?.kind == .delivery && !switchedOff(task) && route(task.id) != .wait {
            startDelivery(task.id)
        }
        watchTurns()
    }

    private func startDelivery(_ id: UUID) {
        guard context.running(), context.ready(), delivering[id] == nil, !refused.contains(id), deliveryBackOff[id] == nil else { return }
        let token = UUID()
        delivering[id] = (token, work.start { [weak self] in
            await self?.deliver(id)
            // A delivery stopped meanwhile leaves its successor's handle alone.
            if self?.delivering[id]?.id == token { self?.delivering[id] = nil }
        })
    }

    /// Task `id`'s owed delivery, once: a removed signal's is cleared; a switched-off one's waits; an archived task is
    /// restored first; the baseline is read before anything is typed, the route looked at again after it.
    private func deliver(_ id: UUID) async {
        guard context.running(), let task = workspace.state.signalItem(id: id), let origin = task.signalOrigin,
              let owed = origin.owed, owed.kind == .delivery else { return }
        guard let signal = workspace.state.signal(id: origin.signal) else {
            // Nobody asks for the prompt any more.
            settle(id, owed: owed, turn: nil)
            return
        }
        guard signal.enabled, signal.isRunnable else { return }
        if workspace.state.archived(id: id) != nil {
            do { try await ports.restore(id) } catch {
                guard context.running() else { return }
                deliveryBackOff[id] = now().addingTimeInterval(SignalPoller.failureBackOff)
                hold(id, origin, reason: "Couldn’t restore its task: " + OperationIssue.reason(of: error))
                return
            }
            guard context.running(), workspace.state.task(id: id) != nil else { return }
        }
        guard route(id) != .wait, await baseline(id) else { return }
        guard context.running(), context.ready(), stillOwed(id, owed), let current = workspace.state.task(id: id) else { return }
        switch route(id) {
        case .wait: return
        case .open: await open(id, owed: owed)
        case .type(let session):
            let sent: Delivery
            do { sent = try await ports.deliver(session.sessionId, owed.text, current.worktreePath) } catch {
                // The helper went away or failed: tried again at the next tick.
                refused.insert(id)
                return
            }
            guard context.running(), workspace.state.task(id: id)?.signalOrigin?.owed == owed else { return }
            switch sent.result {
            case .delivered: settle(id, owed: owed, turn: SignalTurn(sentAt: now())); watchTurns()
            // The text waits in the input for the person: the turn starts when they send it.
            case .partial: settle(id, owed: owed, turn: SignalTurn(pastedAt: now())); watchTurns()
            case .refused:
                refused.insert(id)
                if let code = sent.code, !Self.waits.contains(code) {
                    hold(id, origin, reason: "Its prompt couldn’t be typed: " + (sent.reason ?? "the helper refused it."))
                }
            }
        }
    }

    /// The refusals that say only that the worker or the person is busy now: the prompt waits without a word.
    private static let waits: Set<DeliveryCode> = [.typing, .unsentInput, .prompt, .screenUnread, .sessionClosed, .replaced,
                                                   .itermDisconnected, .itermRefused]

    /// Where task `id`'s delivery goes, as its tabs are listed: any agent of its at work, asking, holding its turn or
    /// running your own prompt waits; a first worker whose turn ended is typed into; no agent listed opens one.
    private func route(_ id: UUID) -> Route {
        guard let task = workspace.state.task(id: id) else { return .wait }
        let agents = live.sessions.filter { $0.taskUUID == id && $0.agent.agentKind != nil }
        if agents.contains(where: { $0.state == .working || $0.state == .needsInput || $0.work.contains(where: \.holdsTurn)
            || $0.yourPrompt != nil || $0.testActivity?.isActive == true }) { return .wait }
        if let worker = task.firstWorker(in: live.sessions) { return worker.state.turnEnded ? .type(worker) : .wait }
        return .open
    }

    /// Task `id`'s agent started on the owed prompt behind the person's work, in their pause and the one window turn: its
    /// window opened resuming its first conversation, or a background tab in its open window. A window that fails is
    /// tried again after `SignalPoller.failureBackOff`.
    private func open(_ id: UUID, owed: OwedPrompt) async {
        while !Task.isCancelled, context.running(), context.ready() {
            guard stillOwed(id, owed), route(id) == .open else { return }
            if !pause.isQuiet {
                await pause.quiet(while: { [weak self] in
                    self.map { $0.context.running() && $0.asks(id, owed) && $0.route(id) == .open } == true
                })
                continue
            }
            let pause = pause
            let done: Bool = await pause.turn.take {
                guard pause.isQuiet else { return false }
                // Switched off or removed while the turn was awaited: the loop's first look keeps it owed or clears it.
                guard self.asks(id, owed) else { return false }
                guard self.context.running(), let current = self.workspace.state.task(id: id), self.route(id) == .open else { return true }
                do {
                    guard try await self.ports.open(id, owed.text, { pause.isQuiet && self.asks(id, owed) },
                                                    { state in Self.clearDelivery(id, owed: owed, turn: SignalTurn(sentAt: self.now()), in: &state) }) else { return false }
                    self.workspace.flush()
                    self.watchTurns()
                } catch {
                    self.deliveryBackOff[id] = self.now().addingTimeInterval(SignalPoller.failureBackOff)
                    self.changed(current.signalOrigin?.signal ?? id, "Couldn’t open " + current.title + ": " + OperationIssue.reason(of: error))
                }
                return true
            }
            if done { return }
        }
    }

    /// Whether task `id` still owes `owed` and its signal still asks for it: a runnable project signal, switched on. Looked
    /// at again after every await of a delivery and last before its window, so a signal switched off meanwhile keeps the
    /// prompt owed until it is on again.
    private func asks(_ id: UUID, _ owed: OwedPrompt) -> Bool {
        guard let origin = workspace.state.signalItem(id: id)?.signalOrigin, origin.owed == owed,
              let signal = workspace.state.signal(id: origin.signal) else { return false }
        return signal.isProject && signal.isRunnable
    }

    /// `asks`, clearing the prompt first when its signal was removed meanwhile: nobody asks for it any more.
    private func stillOwed(_ id: UUID, _ owed: OwedPrompt) -> Bool {
        if let origin = workspace.state.signalItem(id: id)?.signalOrigin, origin.owed == owed, workspace.state.signal(id: origin.signal) == nil {
            settle(id, owed: owed, turn: nil)
            return false
        }
        return asks(id, owed)
    }

    /// The owed delivery done (`turn` its start, nil for a removed signal's), in one saved change.
    private func settle(_ id: UUID, owed: OwedPrompt, turn: SignalTurn?) {
        guard workspace.canChangeWorkspace else { return }
        workspace.mutate { Self.clearDelivery(id, owed: owed, turn: turn, in: &$0) }
        workspace.flush()
    }

    /// Task `id`'s delivery of `owed` done in `state`: the debt cleared, the turn it started, the notification for that
    /// turn still to come (O5), and a reason it waited taken down. A newer prompt owed meanwhile is left as it is.
    private static func clearDelivery(_ id: UUID, owed: OwedPrompt, turn: SignalTurn?, in state: inout AppState) {
        guard let origin = state.signalItem(id: id)?.signalOrigin, origin.owed == owed else { return }
        state.updateSignalItem(id) { task in
            task.signalOrigin?.owed = nil
            guard let turn else { return }
            task.signalOrigin?.turn = turn
            task.signalOrigin?.notifiedAt = nil
        }
        state.signalSeen.removeAll { $0.signal == origin.signal && $0.item.identity == origin.item.identity && $0.disposition == .skipped }
    }

    /// Why task `id`'s prompt waits, as its signal's skipped record of the item beside its started one, said once.
    private func hold(_ id: UUID, _ origin: SignalOrigin, reason: String) {
        guard workspace.canChangeWorkspace, !workspace.state.signalSeen.contains(where: {
            $0.signal == origin.signal && $0.item.identity == origin.item.identity && $0.disposition == .skipped && $0.reason == reason
        }) else { return }
        workspace.mutate { state in Self.recordHold(origin, reason: reason, at: now(), in: &state) }
        workspace.flush()
        changed(origin.signal, "Held " + (workspace.state.signalItem(id: id)?.title ?? id.uuidString) + ": " + reason)
    }
}

private extension ItemRef {
    var isTicket: Bool { if case .ticket = self { true } else { false } }
    var isRun: Bool { if case .run = self { true } else { false } }
}

// -- the turn's notification ------------------------------------------------------------
extension ProjectSignals {
    /// Each turn a project signal's prompt started, as the tabs show it now. A task marked by a project signal, owing
    /// nothing and not yet notified for its turn: a session of its own seen working after the prompt was sent (or, pasted,
    /// once the person sent it) saves `seenWorking`, since a session that ended its turn before the prompt is no evidence.
    /// Only such a turn notifies: its worker asking, or every agent of the task with its turn ended and nothing holding it
    /// (background work, a test run). `notifiedAt` is saved before the note is posted: a crash never posts twice.
    func watchTurns() {
        guard context.running(), context.ready(), workspace.canChangeWorkspace else { return }
        for task in workspace.state.tasks {
            let state = workspace.state
            guard task.signalTask == nil, !task.takenOver, let origin = task.signalOrigin, origin.owed == nil, origin.notifiedAt == nil,
                  let turn = origin.turn, turn.sentAt != nil || turn.pastedAt != nil,
                  state.signal(id: origin.signal)?.isProject != false else { continue }
            let agents = live.sessions.filter { $0.taskUUID == task.id && $0.agent.agentKind != nil }
            if turn.seenWorking != true {
                guard agents.contains(where: { $0.state == .working }) else { continue }
                workspace.mutate { $0.updateSignalItem(task.id) { $0.signalOrigin?.turn?.seenWorking = true } }
                workspace.flush()
            }
            guard let reason = Self.turnEnd(agents) else { continue }
            workspace.mutate { $0.updateSignalItem(task.id) { $0.signalOrigin?.notifiedAt = now() } }
            workspace.flush()
            guard let current = workspace.state.task(id: task.id),
                  let note = SignalTurnNotification.make(task: current, reason: reason, state: workspace.state) else { continue }
            noted.insert(task.id)
            notifications?.requestAuthorization()
            notifications?.post(note)
        }
    }

    /// What a seen turn's agents say now: one asking, or all with their turn ended and nothing holding it; else nothing yet.
    private static func turnEnd(_ agents: [SessionInfo]) -> SignalTurnNotification.Reason? {
        if agents.contains(where: { $0.state == .needsInput }) { return .asks }
        guard !agents.isEmpty, agents.allSatisfy({ $0.state.turnEnded && !$0.work.contains(where: \.holdsTurn)
            && $0.testActivity?.isActive != true }) else { return nil }
        return .ready
    }

    /// The person chose task `id`'s row: its turn's note, if one was posted, is taken back.
    func rowChosen(_ id: UUID) {
        guard workspace.state.task(id: id)?.signalOrigin?.notifiedAt != nil || noted.contains(id) else { return }
        notifications?.withdraw(ids: [SignalTurnNotification.id(id)])
    }

    /// A task whose note was posted went (removed or archived): its note goes too.
    private func withdrawGone() {
        let tasks = workspace.state.tasks
        let present = Set(tasks.map(\.id))
        let gone = noted.subtracting(present)
        noted = noted.intersection(present).union(tasks.filter { $0.signalOrigin?.notifiedAt != nil }.map(\.id))
        guard !gone.isEmpty else { return }
        notifications?.withdraw(ids: gone.sorted { $0.uuidString < $1.uuidString }.map(SignalTurnNotification.id))
    }
}
