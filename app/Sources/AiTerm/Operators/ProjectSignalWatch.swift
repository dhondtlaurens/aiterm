import Foundation
import AiTermCore

/// A project signal's Done and Then for the tasks it marked, one pass each reconcile interval, whatever the Operator's
/// pause. Done is an edge, as the Operator's watch reads it (`RequestWatch`): the Done query matching where it did not at
/// the last complete read, or the task's request merged or closed. The baseline is read before the signal's prompt
/// reaches the worker (`ProjectSignals.baseline`), so a task still owing a prompt is not read; a `doneKey` that no longer
/// names the signal's Done (the person edited it) makes the read a new baseline. A failed read is unknown and changes
/// nothing.
///
/// Once done, `doneAt` is saved and Then is pending until `thenApplied`, retried every pass, after a restart too: Keep
/// finishes at once; Archive goes through the app's teardown, refusing rather than asking, once no session of the task
/// works, asks, holds a turn or may hold unsent input (`inputHeld`): closing its tab would lose the person's words. That,
/// a turn that started meanwhile, or the helper gone (`ClosingWait`), leaves it pending;
/// any other refusal (unsaved work) is kept in `thenNote` and not tried again, as `ThenRunner` does.
///
/// Only a live, switched-on project signal's tasks are read: a switched-off signal's wait, and the first read once it is
/// back compares with the last, so a Done reached meanwhile counts; a removed signal's are never read again.
@MainActor final class ProjectSignalWatch {
    struct Ports {
        /// The task's Done facts for the signal's Done and the matched item (`SignalHostIO.doneFacts`).
        var facts: @MainActor (TaskItem, SignalTrigger, ItemRef) async throws -> DoneCheck.Facts
        /// The task archived without asking (`TaskTeardown.archive(_, consent: .refuse(stillAllowed:))`).
        var archive: @MainActor (TaskItem, @escaping @MainActor () -> Bool) async throws -> Void
        /// Whether a session of the task may hold unsent input (`ProjectSignalWatch.inputHeld`).
        var inputHeld: @MainActor (TaskItem) async -> Bool
    }
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let now: () -> Date
    var ports: Ports
    /// A task's Done reached or its Then refused, the person's and never the Operator's.
    var changed: (UUID, String) -> Void = { _, _ in }

    init(workspace: WorkspaceStore, live: LiveSessions, now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.live = live; self.now = now; self.ports = ports
    }

    /// One pass over the marked tasks in the sidebar: each one not done is read, and each one done whose Then is pending
    /// gets it. A task with a session at work or asking is skipped this pass.
    func pass() async {
        let ids = workspace.state.tasks.filter { $0.signalOrigin != nil && $0.signalTask == nil }.map(\.id)
        for id in ids where !Task.isCancelled {
            guard let first = watched(id), !atWork(first.task) else { continue }
            if first.task.signalOrigin?.doneAt == nil { await read(first.task, signal: first.signal) }
            if let next = watched(id), let origin = next.task.signalOrigin, origin.doneAt != nil, origin.thenApplied != true {
                await then(next.task, signal: next.signal)
            }
        }
    }

    /// Task `id` in the sidebar with its live, switched-on project signal: the only tasks a pass reads or finishes.
    private func watched(_ id: UUID) -> (task: TaskItem, signal: Signal)? {
        guard workspace.canChangeWorkspace, let task = workspace.state.task(id: id), task.signalTask == nil,
              let origin = task.signalOrigin, let signal = workspace.state.signal(id: origin.signal),
              signal.isProject, signal.isRunnable else { return nil }
        return (task, signal)
    }

    /// Whether a session of the task is at work, asking, or holding the person's turn.
    private func atWork(_ task: TaskItem) -> Bool {
        live.sessions.contains { $0.taskUUID == task.id && ($0.state == .working || $0.state == .needsInput || $0.yourPrompt != nil) }
    }

    /// Whether a session of the task left work running that holds its turn (`WorkItem.holdsTurn`, an active test run),
    /// as `ProjectSignals.watchTurns` reads a turn that has not ended: Archive would close it mid-way.
    private func holdsTurn(_ task: TaskItem) -> Bool {
        live.sessions.contains { $0.taskUUID == task.id && ($0.work.contains(where: \.holdsTurn) || $0.testActivity?.isActive == true) }
    }

    /// The task's Done read: a baseline when its `doneKey` no longer names the signal's Done, otherwise an edge against
    /// `doneMatched`. Not read while a prompt is owed: its baseline belongs before that prompt is sent.
    private func read(_ task: TaskItem, signal: Signal) async {
        guard let origin = task.signalOrigin, origin.owed == nil else { return }
        let key = SignalOrigin.doneKey(signal.done)
        let baseline = origin.doneKey != key
        let facts: DoneCheck.Facts
        do { facts = try await ports.facts(task, signal.done, origin.item) }
        catch { return }
        // A read the task, its origin or its signal's Done changed under, or a turn started during, is left for the next pass.
        guard let latest = watched(task.id), let after = latest.task.signalOrigin, !atWork(latest.task),
              after.signal == origin.signal, after.item == origin.item, after.startedAt == origin.startedAt,
              after.owed == nil, after.doneAt == nil, after.doneKey == origin.doneKey, latest.signal.done == signal.done else { return }
        let matched: Bool? = signal.done.source == .person ? nil : facts.doneMatches
        let reached = DoneCheck.reached(facts, before: baseline ? nil : origin.doneMatched)
        let at = self.now()
        workspace.mutate { state in
            state.updateSignalItem(task.id) { task in
                if baseline { task.signalOrigin?.doneKey = key }
                if task.signalOrigin?.doneMatched != matched { task.signalOrigin?.doneMatched = matched }
                if reached { task.signalOrigin?.doneAt = at }
            }
        }
        workspace.flush()
        if reached { changed(signal.id, task.title + " is done.") }
    }

    /// Then for a done task: Keep finishes it; Archive archives it once nothing of it is at work. A turn started meanwhile
    /// or the helper gone leaves it for the next pass; any other refusal is kept in `thenNote`, for good.
    private func then(_ task: TaskItem, signal: Signal) async {
        guard let origin = task.signalOrigin else { return }
        switch signal.finish.then {
        case .keep: finish(task.id, note: nil)
        case .archive:
            // The input read awaits: the task is taken afresh after it, as the teardown refuses a task changed since.
            guard !atWork(task), !holdsTurn(task), !(await ports.inputHeld(task)), let current = watched(task.id)?.task,
                  Self.same(current.signalOrigin, origin), !atWork(current), !holdsTurn(current) else { return }
            let allowed: @MainActor () -> Bool = { [weak self] in
                guard let self, let current = self.workspace.state.task(id: task.id) else { return false }
                return Self.same(current.signalOrigin, origin) && !self.atWork(current) && !self.holdsTurn(current)
            }
            do {
                try await ports.archive(current, allowed)
                guard let archived = workspace.state.archived(id: task.id)?.task, Self.same(archived.signalOrigin, origin) else { return }
                finish(task.id, note: nil)
            } catch is ClosingWait {
                // A turn under way or the helper away: tried again next pass.
            } catch {
                guard allowed() else { return }
                let note = OperationIssue.reason(of: error)
                finish(task.id, note: note)
                changed(signal.id, "Couldn’t archive " + task.title + ": " + note)
            }
        // A project signal never saves Remove.
        case .remove: return
        }
    }

    /// Whether a session of the task may hold unsent input, as the daemon reads it without typing (`session.inputState`):
    /// text typed there and not sent, or, in an agent's tab, input nothing tells about; also when it cannot be asked. A
    /// plain shell's input it cannot tell about counts as empty, so a task whose agent has quit can still be archived.
    static func inputHeld(_ task: TaskItem, sessions: [SessionInfo], daemon: (any DaemonCommands)?) async -> Bool {
        guard let daemon else { return true }
        for session in sessions where session.taskUUID == task.id {
            guard let input = try? await daemon.inputState(sessionId: session.sessionId) else { return true }
            if input == .unsent || (input == .unknown && session.agent != .shell) { return true }
        }
        return false
    }

    /// Whether `current` is still the origin a Then started from: the same signal, item, start and Done.
    private static func same(_ current: SignalOrigin?, _ origin: SignalOrigin) -> Bool {
        guard let current else { return false }
        return current.signal == origin.signal && current.item == origin.item && current.startedAt == origin.startedAt
            && current.doneAt == origin.doneAt && current.thenApplied != true
    }

    private func finish(_ id: UUID, note: String?) {
        workspace.mutate { state in
            state.updateSignalItem(id) { task in
                task.signalOrigin?.thenApplied = true
                if let note { task.signalOrigin?.thenNote = note }
            }
        }
        workspace.flush()
    }
}
