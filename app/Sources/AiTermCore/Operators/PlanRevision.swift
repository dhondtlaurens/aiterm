import Foundation

/// One task in the plan waiting for your approval, and whether the plan adds it or changes it —
/// the overview's `+` and `~`.
public struct PlanChange: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case added, changed }
    public var task: UUID
    public var kind: Kind
    public init(task: UUID, kind: Kind) { self.task = task; self.kind = kind }
}

/// An operation's plan, in numbered revisions (spec §6 `submit_plan`, §8 "Plan revisions").
///
/// `OperatorRun.planRevision` is the last submitted revision, 0 while none is. The operator adds
/// and changes unstarted tasks in the open revision (`openRevision`, one past it); `submit_plan`
/// closes that. In a gated run (Ask first, Routine) a plan waits for you while
/// `planRevision > (approvedRevision ?? 0)`, and you approve exactly `planRevision`, which releases
/// its new and changed tasks; a click on a revision that is no longer the latest fails and
/// releases nothing. In an ungated run a submitted revision releases its tasks at once, and is
/// recorded, not approved.
public enum PlanRevision {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownRun(UUID)
        case unknownTask(UUID)
        case runIs(OperatorRunState)
        case unknownRevision(open: Int, asked: Int)
        case stale(asked: Int, latest: Int)
        case nothingSubmitted
        case notGated
        case unsupportedEnd(key: String, TaskEnd)
        case tooManyCodeParents(key: String)
        case codeParentInAnotherProject(key: String)
        case unknownDependency(key: String)
        case cycle(keys: [String])
        case started(key: String)

        public var description: String {
            switch self {
            case .unknownRun(let id): return "There's no operation \(id.uuidString)."
            case .unknownTask(let id): return "There's no task \(id.uuidString) in this operation."
            case .runIs(let state): return "The operation is \(state.rawValue)."
            case .unknownRevision(let open, let asked): return "Revision \(asked) isn't open; the open revision is \(open)."
            case .stale(let asked, let latest): return "Revision \(asked) isn't the latest plan; revision \(latest) is. Nothing was released."
            case .nothingSubmitted: return "No plan has been submitted yet."
            case .notGated: return "This operation's plans start without approval."
            case .unsupportedEnd(let key, let end):
                return "\(key) ends in a \(end.displayName), which this version of AiTerm can't carry out yet; end it at a commit."
            case .tooManyCodeParents(let key): return "\(key) builds on more than one task's code; a task can stack on one."
            case .codeParentInAnotherProject(let key): return "\(key) builds on code in another project; a code dependency stays in one project."
            case .unknownDependency(let key): return "\(key) depends on a task that isn't in this operation."
            case .cycle(let keys): return "The dependencies go round in a circle: \(keys.joined(separator: ", "))."
            case .started(let key): return "\(key) has started; steer it with message_task instead."
            }
        }
    }

    /// What `submit_plan` did. `repeated` is a submission of a revision already closed, which
    /// returns the earlier result and changes nothing.
    public struct Submitted: Equatable, Sendable {
        public var revision: Int
        public var released: [UUID]
        public var awaitingApproval: Bool
        public var repeated: Bool
        public init(revision: Int, released: [UUID] = [], awaitingApproval: Bool, repeated: Bool = false) {
            self.revision = revision; self.released = released; self.awaitingApproval = awaitingApproval; self.repeated = repeated
        }
    }

    /// Whether a plan waits for your approval: a gated run with a submitted revision newer than
    /// the approved one.
    public static func awaitsApproval(_ run: OperatorRun) -> Bool {
        run.persona.autonomy.gatesPlans && run.planRevision > (run.approvedRevision ?? 0)
    }

    /// The unstarted tasks submitted since the approved revision — what an approval releases — in
    /// plan order, each `added` when the approved plan did not have it and `changed` when it did.
    public static func pending(in state: AppState, run id: UUID) -> [PlanChange] {
        guard let run = state.run(id: id) else { return [] }
        let approved = run.approvedRevision ?? 0
        return state.tasks(inRun: id).compactMap { task in
            guard let o = task.operated, !o.started, o.state == .planned || o.state == .queued,
                  o.revision > approved, o.revision <= run.planRevision else { return nil }
            return PlanChange(task: task.id, kind: o.firstRevision > approved ? .added : .changed)
        }
    }

    /// Closes the open revision `revision` (spec §6 `submit_plan`). Refused, with the reason, when
    /// the plan asks for more than this milestone supports or its dependencies cannot work.
    /// Ungated, its planned tasks are released and the run is active; gated, they wait for your
    /// approval. Either way a complete run reopens as active (spec §9).
    @discardableResult
    public static func submit(_ revision: Int, run id: UUID, in state: inout AppState,
                              milestone: OperatorMilestone = .current) throws(Failure) -> Submitted {
        guard let run = state.run(id: id) else { throw .unknownRun(id) }
        guard [.planning, .active, .complete].contains(run.state) else { throw .runIs(run.state) }
        let gated = run.persona.autonomy.gatesPlans
        if revision <= run.planRevision {
            let waiting = gated && revision > (run.approvedRevision ?? 0)
            return Submitted(revision: revision, awaitingApproval: waiting, repeated: true)
        }
        guard revision == run.openRevision else { throw .unknownRevision(open: run.openRevision, asked: revision) }
        try validate(state, run: id, milestone: milestone)

        state.updateRun(id: id) { run in
            run.planRevision = revision
            if !gated || run.state == .complete { run.state = .active }
        }
        guard !gated else { return Submitted(revision: revision, awaitingApproval: true) }
        let released = release(revision, run: id, in: &state, action: .release(revision: revision), by: .aiterm)
        return Submitted(revision: revision, released: released, awaitingApproval: false)
    }

    /// You, **Approve plan** on revision `revision` of a gated run: releases what `pending` lists
    /// and makes the run active. Approving a revision that is no longer the latest submitted fails
    /// and releases nothing; approving the approved one again changes nothing.
    @discardableResult
    public static func approve(_ revision: Int, run id: UUID, in state: inout AppState) throws(Failure) -> [UUID] {
        guard let run = state.run(id: id) else { throw .unknownRun(id) }
        guard run.persona.autonomy.gatesPlans else { throw .notGated }
        guard run.state != .stopped else { throw .runIs(run.state) }
        guard run.planRevision > 0 else { throw .nothingSubmitted }
        guard revision == run.planRevision else { throw .stale(asked: revision, latest: run.planRevision) }
        if run.approvedRevision == revision { return [] }
        let released = release(revision, run: id, in: &state, action: .approve(revision: revision), by: .you)
        state.updateRun(id: id) { run in
            run.approvedRevision = revision
            if run.state == .planning { run.state = .active }
        }
        return released
    }

    /// `update_task` on an unstarted task: the change belongs to the open revision, and in a gated
    /// run a queued task goes back to planned — a changed brief, agent, end or dependency is
    /// approved like any other change (spec §8). A started task is steered with `message_task`.
    public static func markChanged(task id: UUID, in state: inout AppState) throws(Failure) {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }), let task = state.tasks[index].operated
        else { throw .unknownTask(id) }
        guard let run = state.run(id: task.runId) else { throw .unknownRun(task.runId) }
        guard !task.started, task.state == .planned || task.state == .queued else { throw .started(key: task.key) }
        state.tasks[index].operated?.revision = run.openRevision
        if run.persona.autonomy.gatesPlans { state.tasks[index].operated?.state = .planned }
    }

    /// Whether the run's plan can be carried out: every end supported by `milestone`, at most one
    /// `code` parent per task and in its own project, every dependency inside the run, no circle.
    public static func validate(_ state: AppState, run id: UUID, milestone: OperatorMilestone = .current) throws(Failure) {
        let tasks = state.tasks(inRun: id)
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for task in tasks {
            guard let o = task.operated else { continue }
            if !o.started, !milestone.supports(o.end) { throw .unsupportedEnd(key: o.key, o.end) }
            let code = o.dependsOn.filter { $0.kind == .code }
            if code.count > 1 { throw .tooManyCodeParents(key: o.key) }
            for dependency in o.dependsOn {
                guard let parent = byId[dependency.task] else { throw .unknownDependency(key: o.key) }
                if dependency.kind == .code, parent.projectId != task.projectId { throw .codeParentInAnotherProject(key: o.key) }
            }
        }
        if let loop = cycle(in: tasks) { throw .cycle(keys: loop) }
    }

    /// The keys of the tasks on a dependency circle, sorted; nil when there is none.
    static func cycle(in tasks: [TaskItem]) -> [String]? {
        let parents = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.operated?.dependsOn.map(\.task) ?? []) })
        let keys = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.operated?.key ?? $0.title) })
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
    private static func release(_ revision: Int, run id: UUID, in state: inout AppState, action: OperatedAction,
                                by actor: OperatedActor) -> [UUID] {
        let planned = state.tasks(inRun: id).filter { $0.operated?.state == .planned && ($0.operated?.revision ?? .max) <= revision }
        return planned.flatMap { task in (try? OperatedTransitions.apply(action, toTask: task.id, in: &state, by: actor)) ?? [] }
    }
}
