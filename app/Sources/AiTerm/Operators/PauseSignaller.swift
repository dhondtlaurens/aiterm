import Foundation
import AiTermCore

/// The notes Pause and Resume type into a broadcast's workers (spec §9): each new batch waits for the one before it, so the
/// workers read them in the order you pressed the controls. Pause tells each worker still at work, or whose ended turn left
/// work running, to wrap up and stop (`pauseNote`); Resume tells each one Pause told to carry on (`carryOnNote`). Every
/// worker told is recorded on the run first, with its task's ownership, so a Resume after a restart still tells it.
@MainActor
final class PauseSignaller {
    /// What Pause types into a worker at work, or one whose ended turn left work running that will wake it.
    static let pauseNote = "[AiTerm] The person paused this broadcast. Finish the step you are on, then end your turn "
        + "without starting anything new. If background work wakes you before you hear more, end your turn again. "
        + "You will be told when to carry on."
    /// What Resume types into each worker Pause told to stop.
    static let carryOnNote = "[AiTerm] The broadcast is resumed. Carry on with your task where you left off."
    /// Why a note could not be typed that passes as the tab settles: its agent still drawing its screen, or iTerm2 away.
    static let notReadyYet: Set<DeliveryCode> = [.unrecognisedScreen, .screenUnread, .itermDisconnected]

    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// Told of each worker a carry-on reached: the turn the pause ended never reads as ready for the Operator.
    private let turns: WorkerTurnReader
    /// The notes being typed into each broadcast's workers, by run: each new batch waits for the one before it.
    private var signalling: [UUID: Task<Void, Never>] = [:]
    /// The workers this pause has tried to tell to stop, by run, told or not: none is tried twice while it lasts, so a
    /// worker whose window is listed only after Pause is told once it is (`pauseLateWorkers`), and one that refused is
    /// not asked again on every change of the tabs.
    private var attempted: [UUID: Set<PausedWorker>] = [:]
    private var isStopped = false

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         turns: WorkerTurnReader) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.daemon = daemon
        self.turns = turns
    }

    func start() { isStopped = false }

    /// The notes still to be typed are not: each batch ends with the note under way.
    func stop() {
        isStopped = true
        for notes in signalling.values { notes.cancel() }
        signalling = [:]
    }

    private func run(_ id: UUID) -> OperatorRun? { workspace.state.run(id: id) }

    private func mutateRun(_ id: UUID, _ change: (inout OperatorRun) -> Void) {
        workspace.mutate { $0.updateRun(id: id, change) }
    }

    /// The broadcast was paused: every worker it may steer that is at work is told to stop, behind the notes queued.
    func paused(_ id: UUID) {
        attempted[id] = []
        queue(id) { [weak self] in await self?.signalPause(id) }
    }

    /// The broadcast resumes: each worker Pause told to stop is told to carry on, behind the notes queued. How many could
    /// not be told.
    func resumed(_ id: UUID) async -> Int {
        let missed = await queue(id) { [weak self] in await self?.signalCarryOn(id) ?? 0 }.value
        attempted[id] = nil
        return missed
    }

    /// The broadcast ended: the notes being typed stop at the end, once the one under way is.
    func ended(_ id: UUID) async {
        await signalling[id]?.value
        attempted[id] = nil
    }

    /// A worker of a broadcast you paused that is at work and was neither told nor tried yet — its window listed only
    /// after Pause, its launch having passed its last check before it — is told to stop now, behind the notes queued.
    func pauseLateWorkers() {
        for run in workspace.state.runs where run.youAsked == .pause && !run.hasEnded {
            let tried = attempted[run.id] ?? [], now = ports.now()
            let late = Self.pauseTargets(of: run.id, in: workspace.state, sessions: live.sessions, now: now)
                .filter { !tried.contains($0) && !run.pausedWorkers.contains($0) }
            guard !late.isEmpty else { continue }
            queue(run.id) { [weak self] in await self?.signalPause(run.id) }
        }
    }

    /// `work`, once every note queued before it for broadcast `id` is typed.
    @discardableResult
    private func queue<Value: Sendable>(_ id: UUID, _ work: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let before = signalling[id]
        let task = ports.work.start {
            await before?.value
            return await work()
        }
        signalling[id] = ports.work.start { _ = await task.value }
        return task
    }

    /// The pause note to every worker of the broadcast's driven working tasks that is at work, or whose ended turn left
    /// work running, and that this pause has not tried yet (`attempted`) nor told already: each recorded on the run,
    /// with its task's ownership, before anything is typed, so a Resume after a restart still tells it to carry on. Each
    /// is looked at again right before its note (`steerable`): one you stopped or took over meanwhile, or the note did not
    /// reach, is dropped again. A worker whose turn ended with nothing running has stopped already and is told nothing.
    private func signalPause(_ id: UUID) async {
        guard let run = run(id), run.youAsked == .pause, !run.hasEnded, let daemon = daemon() else { return }
        let tried = attempted[id] ?? []
        let workers = Self.pauseTargets(of: id, in: workspace.state, sessions: live.sessions, now: ports.now())
            .filter { !tried.contains($0) && !run.pausedWorkers.contains($0) }
        guard !workers.isEmpty else { return }
        attempted[id, default: []].formUnion(workers)
        mutateRun(id) { $0.pausedWorkers += workers }
        // On disk before the first note goes: a restart mid-way still tells each to carry on. A save that fails is
        // logged by the store and tried again with the next change; the notes still go.
        _ = workspace.flush()
        for worker in workers {
            // Ended meanwhile, its tasks yours, or AiTerm's Operators stopped: told nothing more.
            guard !isStopped, self.run(id)?.hasEnded == false else { break }
            guard let place = steerable(worker, in: id) else {
                mutateRun(id) { $0.pausedWorkers.removeAll { $0 == worker } }
                continue
            }
            let delivery = try? await daemon.deliver(sessionId: place.sessionId, text: Self.pauseNote,
                                                     ownership: worker.ownership, wake: false, worktree: place.worktree)
            if delivery?.result != .delivered {
                Log.daemon.info("The pause note did not reach a worker of task \(worker.task.uuidString, privacy: .public): \(delivery?.reason ?? "no helper", privacy: .public)")
                mutateRun(id) { $0.pausedWorkers.removeAll { $0 == worker } }
                // Not ready yet — its screen shows no input box, could not be read, or iTerm2 is away: tried again as its
                // tabs change (`pauseLateWorkers`). A prompt open waits on you, and is not asked again.
                if let code = delivery?.code, Self.notReadyYet.contains(code) { attempted[id]?.remove(worker) }
            }
        }
    }

    /// The workers a pause tells to stop: those of the broadcast's driven working tasks at work, or whose ended turn
    /// left work running (`WorkerTab.isStillAtWork`), the ones that keep their task `pausing`. As of `now`, a first worker
    /// whose launch is under way counts as at work: its first prompt is on its way, though Codex reads idle until its first
    /// hook. One whose window iTerm2 does not list yet is told once it is (`pauseLateWorkers`).
    static func pauseTargets(of id: UUID, in state: AppState, sessions: [SessionInfo], now: Date) -> [PausedWorker] {
        state.tasks(inRun: id).flatMap { task -> [PausedWorker] in
            guard let operated = task.operated, !operated.takenOver, operated.state == .working else { return [] }
            // An agent to type into: an extra tab still listed as the shell its command is typed into waits for its agent.
            return task.workerTabs(in: sessions, now: now).filter { $0.session?.agent.agentKind != nil && $0.isStillAtWork }.map { tab in
                PausedWorker(task: task.id, tab: tab.key, ownership: operated.ownership)
            }
        }
    }

    /// Where `worker` is typed into while broadcast `id` may still steer it: its task still the broadcast's, not taken
    /// over, working, at the ownership it was paused with, its tab listed. Nil once any of that changed.
    private func steerable(_ worker: PausedWorker, in id: UUID) -> (sessionId: String, worktree: String)? {
        guard let task = workspace.state.task(id: worker.task), let operated = task.operated, operated.runId == id,
              !operated.takenOver, operated.state == .working, operated.ownership == worker.ownership,
              let session = task.workerTab(worker.tab, in: live.sessions)?.session else { return nil }
        return (session.sessionId, task.worktreePath)
    }

    /// The carry-on note to each worker Pause told to stop, in the order they were stopped, once the notes before it are
    /// typed. Each is let go from the run as it is handled; one that is no longer the broadcast's to steer — its task
    /// taken over, stopped or moved on, its ownership changed, its tab gone — is let go without a word. An End meanwhile
    /// stops the rest. Each worker told is answered (`WorkerTurnReader.messaged`), so the turn the pause ended never reads
    /// as ready for the Operator. Returns how many could not be told.
    private func signalCarryOn(_ id: UUID) async -> Int {
        guard let daemon = daemon() else { return run(id)?.pausedWorkers.count ?? 0 }
        var missed = 0
        for worker in run(id)?.pausedWorkers ?? [] {
            guard !isStopped, self.run(id)?.hasEnded == false else { break }
            defer { mutateRun(id) { $0.pausedWorkers.removeAll { $0 == worker } } }
            guard let place = steerable(worker, in: id) else { continue }
            let delivery = try? await daemon.deliver(sessionId: place.sessionId, text: Self.carryOnNote,
                                                     ownership: worker.ownership, wake: false, worktree: place.worktree)
            guard delivery?.result == .delivered else { missed += 1; continue }
            turns.messaged(worker.task, tab: worker.tab)
        }
        return missed
    }
}
