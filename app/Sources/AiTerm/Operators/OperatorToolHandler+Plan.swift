import Foundation
import AiTermCore

/// The plan (spec §6, §8): unstarted tasks added and changed in the open revision, and a revision
/// submitted. A task gets its row at once and its worktree only when AiTerm starts it.
extension OperatorToolHandler {
    func createTask(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key")
        if let existing = state.tasks(inRun: run.id).first(where: { $0.operated?.key == key }) { return Self.taskAnswer(existing, created: false) }
        try acceptsPlanChanges(run)
        let title = try call.string("title"), brief = try call.string("brief")
        let project = try self.project(call, in: run), agent = try self.agent(call), model = try self.model(call, for: agent)
        let end = try self.end(call) ?? .commit
        let dependencies = try self.dependencies(call, in: run, project: project)
        let ticket = call.optionalString("ticket")
        var task = TaskItem(id: UUID(), projectId: project.id, title: title,
                            branch: unusedBranch(BranchType.feat.rawValue + "/" + BranchNaming.branchSlug(key: ticket, summary: title), in: project),
                            worktreePath: "", baseBranch: "",
                            jira: ticket.map { JiraRef(key: $0, summary: title, url: Self.ticketURL($0, in: project)) },
                            agent: agent, model: model.model, reasoning: model.reasoning, firstPrompt: brief, appendTicket: false,
                            createdAt: ports.now(), windowId: nil)
        task.operated = OperatedTask(runId: run.id, key: key, state: .planned, end: end, brief: brief, dependsOn: dependencies,
                                     stackedOn: dependencies.first { $0.kind == .code }?.task, revision: run.openRevision)
        workspace.mutate { $0.tasks.append(task) }
        return Self.taskAnswer(task, created: true)
    }

    /// Only an unstarted task changes here; a started one is steered with `message_task` (spec §6).
    /// A change joins the open revision, and a queued task waits for that revision again.
    func updateTask(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let task = try self.task(call, in: run)
        guard let operated = task.operated, operated.state == .planned || operated.state == .queued, operated.launch == nil else {
            throw ToolRefusal("\(task.operated?.key ?? task.title) has started: steer it with message_task, and log the steer with log_decision.")
        }
        try acceptsPlanChanges(run)
        let project = state.project(id: task.projectId)
        let brief = call.optionalString("brief")
        let agent = try call.optionalString("agent").map { _ in try self.agent(call) }
        let model = call.optionalString("model")
        let end = try self.end(call)
        let dependencies = try call.arguments["dependsOn"].map { _ in try self.dependencies(call, in: run, project: project) }
        if let dependencies, dependencies.contains(where: { $0.task == task.id }) { throw ToolRefusal("A task can’t depend on itself.") }
        do {
            try workspace.mutate { state in
                guard let i = state.tasks.firstIndex(where: { $0.id == task.id }), var record = state.tasks[i].operated else { return }
                if let brief { record.brief = brief; state.tasks[i].firstPrompt = brief }
                if let agent { state.tasks[i].agent = agent }
                if let model { state.tasks[i].model = model; state.tasks[i].reasoning = nil }
                if let end { record.end = end }
                if let dependencies { record.dependsOn = dependencies; record.stackedOn = dependencies.first { $0.kind == .code }?.task }
                state.tasks[i].operated = record
                // Into the open revision, waiting for it again (spec §8).
                try PlanRevision.markChanged(task: task.id, in: &state)
            }
        } catch let failure as PlanRevision.Failure {
            throw ToolRefusal(failure.description)
        }
        return Self.taskAnswer(state.task(id: task.id) ?? task, created: false)
    }

    /// Closes the open revision through `PlanRevision.submit` — the plan-validation step, where the
    /// milestone check refuses an end this milestone does not carry out (M1: anything but a commit, spec
    /// §13) with the reason. Ungated, its tasks are released at once and the operation is active; gated,
    /// they wait for Approve plan. A revision already submitted changes nothing and says so: it carries no
    /// `released` count, which would read as "nothing was released".
    func submitPlan(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        guard let revision = call.arguments["revision"]?.intValue else {
            throw ToolRefusal("submit_plan needs `revision`, the open revision run_status shows.")
        }
        try acceptsPlanChanges(run)
        let submitted: PlanRevision.Submitted
        do {
            submitted = try workspace.mutate { try PlanRevision.submit(revision, run: run.id, in: &$0, milestone: ports.milestone) }
        } catch let failure as PlanRevision.Failure {
            throw ToolRefusal(failure.description)
        }
        let current = state.run(id: run.id) ?? run
        if submitted.awaitingApproval, !submitted.repeated { notifier.planWaiting(current) }
        var answer: JSONValue = ["revision": .int(submitted.revision), "openRevision": .int(current.openRevision), "submitted": true,
                                 "waitingForApproval": .bool(submitted.awaitingApproval), "repeated": .bool(submitted.repeated)]
        if submitted.repeated {
            let waiting = submitted.awaitingApproval ? " It is waiting for the person’s approval." : ""
            answer = answer.adding("note", .string("Revision \(submitted.revision) was already submitted; nothing changed.\(waiting)"))
        } else {
            answer = answer.adding("released", .int(submitted.released.count))
        }
        return answer
    }

    // -- reading a call ------------------------------------------------------------------------
    /// The plan changes while the operation runs or plans — not while you have paused it.
    func acceptsPlanChanges(_ run: OperatorRun) throws(ToolRefusal) {
        switch run.state {
        case .planning, .active, .complete: return
        case .paused: throw ToolRefusal("The person paused this operation. Wait until they resume it.")
        case .operatorOffline: throw ToolRefusal("AiTerm has this operation offline; it resumes it first.")
        case .stopped: throw ToolRefusal("This operation was stopped; its tools no longer act.")
        }
    }

    /// The project a task goes in: one of the operation's. Another project of the workspace joins an
    /// ungated operation, recorded with the revision; a gated one refuses it, since adding a project
    /// is a plan change you approve (spec §5.3).
    private func project(_ call: ToolCall, in run: OperatorRun) throws(ToolRefusal) -> Project {
        let ref = try call.string("project")
        func named(_ project: Project) -> Bool {
            project.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame || project.name.caseInsensitiveCompare(ref) == .orderedSame
        }
        let projects = run.projectIds.compactMap(state.project(id:))
        if let project = projects.first(where: named) { return project }
        let list = projects.map(\.name).joined(separator: ", ")
        guard let project = state.projects.first(where: named) else {
            throw ToolRefusal("AiTerm has no project called \(ref). This operation’s projects are: \(list).")
        }
        guard !run.persona.autonomy.gatesPlans else {
            throw ToolRefusal("\(project.name) isn’t one of this operation’s projects: \(list). Adding a project needs the person’s approval: ask_you first.")
        }
        workspace.mutate { $0.updateRun(id: run.id) { $0.projectIds.append(project.id) } }
        return project
    }

    private func agent(_ call: ToolCall) throws(ToolRefusal) -> AgentKind {
        switch try call.string("agent").lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        default: throw ToolRefusal("An operator’s task runs claude or codex.")
        }
    }

    /// The model the call names, or the one Settings › Agents gives the agent.
    private func model(_ call: ToolCall, for agent: AgentKind) throws(ToolRefusal) -> (model: String, reasoning: String?) {
        if let model = call.optionalString("model") { return (model, nil) }
        let fallback = AgentIntegrations.fixerModels(remembered: state.lastModelByAgent)(agent == .codex ? .codex : .claude)
        guard !fallback.model.isEmpty else { throw ToolRefusal("Pass a model: AiTerm has no default model for \(agent.harness.displayName) yet.") }
        return fallback
    }

    private func end(_ call: ToolCall) throws(ToolRefusal) -> TaskEnd? {
        guard let raw = call.optionalString("end") else { return nil }
        guard let end = TaskEnd(rawValue: raw) else { throw ToolRefusal("A task’s end is commit, draftMR or merge.") }
        return end
    }

    /// `dependsOn`: a task for an order dependency, or `{task, kind}`. At most one code dependency, in
    /// the task's own project: a worktree branches from one parent of its own repository (spec §5.3).
    private func dependencies(_ call: ToolCall, in run: OperatorRun, project: Project?) throws(ToolRefusal) -> [TaskDependency] {
        var found: [TaskDependency] = []
        for item in call.arguments["dependsOn"]?.arrayValue ?? [] {
            guard let ref = item.stringValue ?? item["task"]?.stringValue else {
                throw ToolRefusal("Each dependsOn entry is a task, or {\"task\": …, \"kind\": \"order\" or \"code\"}.")
            }
            guard let parent = state.task(inRun: run.id, named: ref) else { throw ToolRefusal("dependsOn names \(ref), which isn’t a task of this operation.") }
            let kind = item["kind"]?.stringValue.flatMap(DependencyKind.init(rawValue:)) ?? .order
            if kind == .code, parent.projectId != project?.id {
                let name = state.project(id: parent.projectId)?.name ?? "another project"
                throw ToolRefusal("A code dependency stays in one project: \(parent.operated?.key ?? ref) is in \(name).")
            }
            found.append(TaskDependency(task: parent.id, kind: kind))
        }
        guard found.filter({ $0.kind == .code }).count <= 1 else {
            throw ToolRefusal("A task stacks on at most one code dependency: its worktree branches from one parent.")
        }
        return found
    }

    /// `branch`, or with `-2`, `-3`… once another task of the project has it.
    private func unusedBranch(_ branch: String, in project: Project) -> String {
        let taken = Set(state.tasks.filter { $0.projectId == project.id }.map(\.branch))
        guard taken.contains(branch) else { return branch }
        var n = 2
        while taken.contains("\(branch)-\(n)") { n += 1 }
        return "\(branch)-\(n)"
    }

    /// The ticket's page, from the Jira project of the operation's project it belongs to; none when no link says.
    static func ticketURL(_ key: String, in project: Project) -> String {
        project.jiraProjects.first { key.uppercased().hasPrefix($0.key.uppercased() + "-") }
            .map { $0.siteURL.appendingPathComponent("browse/\(key)").absoluteString } ?? ""
    }

    static func taskAnswer(_ task: TaskItem, created: Bool) -> JSONValue {
        ["task": .string(task.id.uuidString), "key": .string(task.operated?.key ?? ""), "state": .string(task.operated?.state.rawValue ?? ""),
         "revision": .int(task.operated?.revision ?? 0), "created": .bool(created)]
    }
}

private extension JSONValue {
    /// This object with `key` set; anything else unchanged.
    func adding(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var members) = self else { return self }
        members[key] = value
        return .object(members)
    }
}
