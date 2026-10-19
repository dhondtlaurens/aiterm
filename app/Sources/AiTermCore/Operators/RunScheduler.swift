import Foundation

/// Which queued tasks AiTerm may start now (spec §6, last paragraph): AiTerm starts them, never
/// the operator. Stateless and pure: the caller starts what this returns, saving each launch intent
/// first (`OperatedAction.start`), and asks again when anything changes.
///
/// There is no cap: every ready task of every active operation starts, operations oldest first,
/// each in its plan order. A blocked task is resumed by `resume_task`, not by this.
public enum RunScheduler {
    /// Every task that may start now, across all operations, in the order to start them.
    ///
    /// A task may start when its run is active, it is queued and not taken over, each `order`
    /// parent is accepted, published or ended with no change, and each `code` parent is accepted
    /// or published — a `code` child branches from that accepted SHA (`baseCommit`).
    public static func startable(in state: AppState) -> [UUID] {
        state.runs.enumerated().filter { $0.element.state == .active }
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .flatMap { ready(in: state, run: $0.element.id) }
    }

    /// `startable(in:)` with the queued tasks `excluding` names left out: ones whose window the caller
    /// is opening or has just opened. A dependent of a task left out is not ready; nothing else changes.
    public static func startable(in state: AppState, excluding: Set<UUID>) -> [UUID] {
        guard !excluding.isEmpty else { return startable(in: state) }
        var view = state
        view.tasks.removeAll { excluding.contains($0.id) && $0.operated?.state == .queued }
        return startable(in: view)
    }

    /// The tasks of `run` among `startable(in:)`: what this operation may start now.
    public static func startable(in state: AppState, run id: UUID) -> [UUID] {
        let mine = Set(state.tasks(inRun: id).map(\.id))
        return startable(in: state).filter(mine.contains)
    }

    /// The run's queued tasks whose dependencies are satisfied, in plan order.
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
    /// Every task that may start now, claimed: `startable(in:)`'s list, each moved `queued → working`
    /// by the `.start` transition with its launch intent (the next attempt, at `now`), all in this one
    /// synchronous change, before anything is launched (spec §8, §11). Two tasks finishing at once each
    /// end in a call to this; whichever runs second finds the first's claims taken, so no task is
    /// claimed twice — nor is an id the state holds twice (F3).
    ///
    /// `excluding` names queued tasks the caller may already have a window for (`startable(in:excluding:)`).
    public static func claim(in state: inout AppState, now: Date, excluding: Set<UUID> = []) -> [UUID] {
        // A foreign merge holds its children even though the parent still has an acceptance.
        for task in state.tasks where task.operated?.state == .queued {
            guard let parent = task.operated?.dependsOn.compactMap({ state.task(id: $0.task)?.operated }).first(where: {
                $0.publication?.mergedSHA != nil && $0.publication?.merged != true
            }) else { continue }
            let reason = parent.publication?.problem ?? "\(parent.key) was merged on the host outside its accepted publication"
            _ = try? OperatedTransitions.apply(.block(reason: reason), toTask: task.id, in: &state, by: .aiterm)
        }
        var claimed: [UUID] = []
        for id in startable(in: state, excluding: excluding) where !claimed.contains(id) {
            let attempt = LaunchAttempt(number: (state.task(id: id)?.operated?.launch?.number ?? 0) + 1, requestedAt: now)
            // A refusal, or a repeat that changed nothing, is no claim: it is left for the next pass.
            guard let changed = try? OperatedTransitions.apply(.start(attempt), toTask: id, in: &state, by: .aiterm),
                  changed.first == id else { continue }
            claimed.append(id)
        }
        return claimed
    }
}
