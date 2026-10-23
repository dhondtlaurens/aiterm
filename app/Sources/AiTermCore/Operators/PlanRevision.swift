import Foundation

/// A broadcast's plan, in numbered revisions (spec §6 `submit_plan`, §8 "Plan revisions").
///
/// `OperatorRun.planRevision` is the last submitted revision, 0 while none is. The operator adds
/// and changes unstarted tasks in the open revision (`openRevision`, one past it); `submit_plan`
/// closes that, and a submitted revision releases its planned tasks at once: there is no approval.
public enum PlanRevision {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownRun(UUID)
        case unknownTask(UUID)
        case runIs(OperatorRunState)
        case unknownRevision(open: Int, asked: Int)
        /// A stacked task's end its parent's end cannot carry (`PlanEndRules`), in its own words.
        case endsDisagree(String)
        case tooManyCodeParents(key: String)
        case codeParentInAnotherProject(key: String)
        case unknownDependency(key: String)
        case cycle(keys: [String])
        case started(key: String)
        case duplicateTask(key: String)

        public var description: String {
            switch self {
            case .unknownRun(let id): return "There's no broadcast \(id.uuidString)."
            case .unknownTask(let id): return "There's no task \(id.uuidString) in this broadcast."
            case .runIs(let state): return "The broadcast is \(state.rawValue)."
            case .unknownRevision(let open, let asked): return "Revision \(asked) isn't open; the open revision is \(open)."
            case .endsDisagree(let why): return why
            case .tooManyCodeParents(let key): return "\(key) builds on more than one task's code; a task can stack on one."
            case .codeParentInAnotherProject(let key): return "\(key) builds on code in another project; a code dependency stays in one project."
            case .unknownDependency(let key): return "\(key) depends on a task that isn't in this broadcast."
            case .cycle(let keys): return "The dependencies go round in a circle: \(keys.joined(separator: ", "))."
            case .started(let key): return "\(key) has started; steer it with message_task instead."
            case .duplicateTask(let key): return "\(key) appears twice in this broadcast under one task id; the plan can't be read until that is fixed."
            }
        }
    }

    /// What `submit_plan` did. `repeated` is a submission of a revision already closed, which
    /// returns the earlier result and changes nothing.
    public struct Submitted: Equatable, Sendable {
        public var revision: Int
        public var released: [UUID]
        public var repeated: Bool
        public init(revision: Int, released: [UUID] = [], repeated: Bool = false) {
            self.revision = revision; self.released = released; self.repeated = repeated
        }
    }

    /// Closes the open revision `revision` (spec §6 `submit_plan`). Refused, with the reason, when
    /// its dependencies or its ends cannot work. Its
    /// planned tasks are released at once and the run is active (a complete run reopens, spec §9);
    /// the first submit also records how many tasks the plan had, `firstPlanSize`.
    @discardableResult
    public static func submit(_ revision: Int, run id: UUID, in state: inout AppState) throws(Failure) -> Submitted {
        guard let run = state.run(id: id) else { throw .unknownRun(id) }
        guard [.planning, .active, .complete].contains(run.state) else { throw .runIs(run.state) }
        if revision >= 1, revision <= run.planRevision { return Submitted(revision: revision, repeated: true) }
        guard revision == run.openRevision else { throw .unknownRevision(open: run.openRevision, asked: revision) }
        try validate(state, run: id)

        let size = state.tasks(inRun: id).count
        state.updateRun(id: id) { run in
            run.planRevision = revision
            run.state = .active
            run.reopen()
            if run.firstPlanSize == nil { run.firstPlanSize = size }
        }
        let released = release(revision, run: id, in: &state)
        return Submitted(revision: revision, released: released)
    }

    /// `submit(_:run:in:)` for the open revision.
    @discardableResult
    public static func submit(run id: UUID, in state: inout AppState) throws(Failure) -> Submitted {
        guard let run = state.run(id: id) else { throw .unknownRun(id) }
        return try submit(run.openRevision, run: id, in: &state)
    }

    /// `update_task` on an unstarted task: the change belongs to the open revision, and a queued
    /// task stays queued, since the next submit releases only what is planned. A started task is
    /// steered with `message_task`.
    public static func markChanged(task id: UUID, in state: inout AppState) throws(Failure) {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }), let task = state.tasks[index].operated
        else { throw .unknownTask(id) }
        guard let run = state.run(id: task.runId) else { throw .unknownRun(task.runId) }
        guard !task.started, task.state == .planned || task.state == .queued else { throw .started(key: task.key) }
        state.tasks[index].operated?.revision = run.openRevision
    }

    /// Whether the run's plan can be carried out: at most one `code` parent per task and in its own project, every
    /// dependency inside the run, no circle, and every stacked end one its parent's can carry (`PlanEndRules`, over every
    /// revision's tasks of the run).
    public static func validate(_ state: AppState, run id: UUID) throws(Failure) {
        let tasks = state.tasks(inRun: id)
        // One id twice is a corrupt state: reading only the first of them could hide a circle or a bad parent in the other.
        var seen: Set<UUID> = []
        for task in tasks where !seen.insert(task.id).inserted { throw .duplicateTask(key: task.operated?.key ?? task.title) }
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for task in tasks {
            guard let o = task.operated else { continue }
            let code = o.dependsOn.filter { $0.kind == .code }
            if code.count > 1 { throw .tooManyCodeParents(key: o.key) }
            for dependency in o.dependsOn {
                guard let parent = byId[dependency.task] else { throw .unknownDependency(key: o.key) }
                if dependency.kind == .code, parent.projectId != task.projectId { throw .codeParentInAnotherProject(key: o.key) }
            }
        }
        if let loop = cycle(in: tasks) { throw .cycle(keys: loop) }
        if let why = PlanEndRules.refusal(for: tasks) { throw .endsDisagree(why) }
    }

    /// The keys of the tasks on a dependency circle, sorted; nil when there is none.
    static func cycle(in tasks: [TaskItem]) -> [String]? {
        let parents = Dictionary(tasks.map { ($0.id, $0.operated?.dependsOn.map(\.task) ?? []) }, uniquingKeysWith: { first, _ in first })
        let keys = Dictionary(tasks.map { ($0.id, $0.operated?.key ?? $0.title) }, uniquingKeysWith: { first, _ in first })
        var done: Set<UUID> = [], path: [UUID] = []
        func visit(_ id: UUID) -> [UUID]? {
            if let start = path.firstIndex(of: id) { return Array(path[start...]) }
            guard !done.contains(id) else { return nil }
            path.append(id)
            for parent in parents[id] ?? [] where parents[parent] != nil {
                if let loop = visit(parent) { return loop }
            }
            path.removeLast()
            done.insert(id)
            return nil
        }
        for task in tasks {
            if let loop = visit(task.id) { return loop.compactMap { keys[$0] }.sorted() }
        }
        return nil
    }

    /// Moves the run's planned tasks of `revision` or older to queued, through the transition table.
    private static func release(_ revision: Int, run id: UUID, in state: inout AppState) -> [UUID] {
        let planned = state.tasks(inRun: id).filter { $0.operated?.state == .planned && ($0.operated?.revision ?? .max) <= revision }
        return planned.flatMap { task in (try? OperatedTransitions.apply(.release(revision: revision), toTask: task.id, in: &state, by: .aiterm)) ?? [] }
    }
}
