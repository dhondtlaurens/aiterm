import Foundation

/// Which queued tasks AiTerm may start now (spec §6, last paragraph): AiTerm starts them, never
/// the operator. Stateless and pure: the caller starts what this returns, saving each launch intent
/// first (`OperatedAction.start`), and asks again when anything changes.
///
/// The slots are AiTerm's, not an operator's (`OperatorMilestone.maxParallel`): the cap counts
/// every operation's working tasks — one taken over still holds its slot, as its agent still runs;
/// a blocked one holds none. The cap limits starts only: `resume_task` may take a blocked task
/// back over it. Operations take turns for free slots, oldest first, one task each per turn.
public enum RunScheduler {
    /// Every task that may start now, across all operations, in the order to start them.
    ///
    /// A task may start when its run is active, it is queued and not taken over, each `order`
    /// parent is accepted, published or ended with no change, and each `code` parent is accepted
    /// or published — a `code` child branches from that accepted SHA (`baseCommit`).
    public static func startable(in state: AppState, maxParallel: Int) -> [UUID] {
        var free = maxParallel - state.tasks.filter { $0.operated?.state == .working }.count
        guard free > 0 else { return [] }
        let runs = state.runs.enumerated().filter { $0.element.state == .active }
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        var queues = runs.map { ready(in: state, run: $0.id) }
        var picked: [UUID] = []
        while free > 0, queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where free > 0 && !queues[i].isEmpty {
                picked.append(queues[i].removeFirst())
                free -= 1
            }
        }
        return picked
    }

    /// `startable(in:maxParallel:)` with the queued tasks `excluding` names left out — ones whose window the
    /// caller is opening or has just opened: the turns and the slots are dealt as if they were not there. A
    /// task left out holds no slot, and a dependent of it is not ready; nothing else changes.
    public static func startable(in state: AppState, maxParallel: Int, excluding: Set<UUID>) -> [UUID] {
        guard !excluding.isEmpty else { return startable(in: state, maxParallel: maxParallel) }
        var view = state
        view.tasks.removeAll { excluding.contains($0.id) && $0.operated?.state == .queued }
        return startable(in: view, maxParallel: maxParallel)
    }

    /// The tasks of `run` among `startable(in:maxParallel:)`: what this operation may start now,
    /// its turn with the others taken into account.
    public static func startable(in state: AppState, run id: UUID, maxParallel: Int) -> [UUID] {
        let mine = Set(state.tasks(inRun: id).map(\.id))
        return startable(in: state, maxParallel: maxParallel).filter(mine.contains)
    }

    /// The run's queued tasks whose dependencies are satisfied, in plan order, slots aside.
    static func ready(in state: AppState, run id: UUID) -> [UUID] {
        let byId = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        return state.tasks(inRun: id).filter { task in
            // A task id held twice starts once: never a second worktree or window for the same task.
            guard let o = task.operated, o.state == .queued, !o.takenOver, seen.insert(task.id).inserted else { return false }
            return o.dependsOn.allSatisfy { dependency in
                guard let operated = byId[dependency.task]?.operated,
                      operated.publication?.mergedSHA == nil || operated.publication?.merged == true else { return false }
                let parent = operated.state
                switch dependency.kind {
                case .order: return [.accepted, .noChange, .published].contains(parent)
                case .code: return [.accepted, .published].contains(parent)
                }
            }
        }.map(\.id)
    }

    /// The commit a task's worktree starts from: its `code` parent's accepted SHA, or nil to start
    /// from the project's base branch as a task you make does.
    public static func baseCommit(for id: UUID, in state: AppState) -> String? {
        guard let code = state.task(id: id)?.operated?.dependsOn.first(where: { $0.kind == .code }) else { return nil }
        return state.task(id: code.task)?.operated?.acceptance?.resultSHA
    }

    /// Whether `run` is done (spec §9): every task at its end and no question open. A task ends at
    /// `accepted` or `noChange` when the plan ends it at a commit; a draft MR or a merge ends at
    /// `published`; a stopped task is ended too. A run with no tasks is not done — it has not
    /// planned yet.
    public static func isComplete(_ run: OperatorRun, in state: AppState) -> Bool {
        let tasks = state.tasks(inRun: run.id).compactMap(\.operated)
        guard !tasks.isEmpty, run.questions.allSatisfy({ $0.resolution != nil }) else { return false }
        return tasks.allSatisfy { task in
            switch task.state {
            case .noChange, .published, .stopped: return true
            case .accepted: return task.end == .commit
            default: return false
            }
        }
    }
}

extension RunScheduler {
    /// How many of AiTerm's slots are taken: every operated task at work, in every operation, taken
    /// over or not — a worker you drive is still an agent running. A blocked task holds none:
    /// `resume_task` continues its live session at once, even over the cap, and new starts wait
    /// until the count is back under it.
    public static func occupiedSlots(in state: AppState) -> Int {
        state.tasks.reduce(0) { $0 + ($1.operated?.state == .working ? 1 : 0) }
    }

    /// What `maxParallel` leaves free now. Never negative, so a lowered cap starts nothing and stops nothing.
    public static func freeSlots(in state: AppState, maxParallel: Int) -> Int {
        max(0, maxParallel - occupiedSlots(in: state))
    }
}

extension RunScheduler {
    /// Every task that may start now, claimed: `startable(in:maxParallel:)`'s list — every operation's
    /// working tasks against the cap, operations taking turns oldest first — each moved `queued →
    /// working` by the `.start` transition with its launch intent (the next attempt, at `now`), all in
    /// this one synchronous change, before anything is launched (spec §8, §11). Two tasks finishing
    /// at once each end in a call to this; whichever runs second counts the first's claims, so the cap
    /// holds and no task is claimed twice — nor is an id the state holds twice (F3).
    ///
    /// `excluding` names queued tasks the caller may already have a window for (`startable(in:maxParallel:excluding:)`).
    public static func claim(in state: inout AppState, maxParallel: Int, now: Date, excluding: Set<UUID> = []) -> [UUID] {
        // A foreign merge holds its children even though the parent still has an acceptance.
        for task in state.tasks where task.operated?.state == .queued {
            guard let parent = task.operated?.dependsOn.compactMap({ state.task(id: $0.task)?.operated }).first(where: {
                $0.publication?.mergedSHA != nil && $0.publication?.merged != true
            }) else { continue }
            let reason = parent.publication?.problem ?? "\(parent.key) was merged on the host outside its accepted publication"
            _ = try? OperatedTransitions.apply(.block(reason: reason), toTask: task.id, in: &state, by: .aiterm)
        }
        var claimed: [UUID] = []
        for id in startable(in: state, maxParallel: maxParallel, excluding: excluding) where !claimed.contains(id) {
            let attempt = LaunchAttempt(number: (state.task(id: id)?.operated?.launch?.number ?? 0) + 1, requestedAt: now)
            // A refusal, or a repeat that changed nothing, is no claim: it is left for the next pass.
            guard let changed = try? OperatedTransitions.apply(.start(attempt), toTask: id, in: &state, by: .aiterm),
                  changed.first == id else { continue }
            claimed.append(id)
        }
        return claimed
    }
}
