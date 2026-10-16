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

    /// The tasks of `run` among `startable(in:maxParallel:)`: what this operation may start now,
    /// its turn with the others taken into account.
    public static func startable(in state: AppState, run id: UUID, maxParallel: Int) -> [UUID] {
        let mine = Set(state.tasks(inRun: id).map(\.id))
        return startable(in: state, maxParallel: maxParallel).filter(mine.contains)
    }

    /// The run's queued tasks whose dependencies are satisfied, in plan order, slots aside.
    static func ready(in state: AppState, run id: UUID) -> [UUID] {
        let byId = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) })
        return state.tasks(inRun: id).filter { task in
            guard let o = task.operated, o.state == .queued, !o.takenOver else { return false }
            return o.dependsOn.allSatisfy { dependency in
                guard let parent = byId[dependency.task]?.operated?.state else { return false }
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
