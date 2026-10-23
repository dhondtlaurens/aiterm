import Foundation
import AiTermCore

/// The plan (spec §6, §8): unstarted tasks added and changed in the open revision, and a revision
/// submitted. A task gets its row at once and its worktree only when AiTerm starts it.
extension OperatorToolHandler {
    /// The tool's checks run again after each suspension: the repository's branches and the agent's model
    /// list are read off the main actor, and the Oracle may be asked about an addition past the backlog's
    /// threshold. Meanwhile another call may have made this key or taken a branch, or you may have paused or
    /// ended the broadcast. Everything after the last read runs without another suspension, so what it
    /// checked is what it changes, and two calls never pick one branch or make one key twice. An addition past
    /// the backlog's threshold comes here only with the Oracle's yes (the challenge gate's veto, `vettedCalls`).
    func createTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let key = try call.string("key")
        if let existing = existingTask(key, in: run) { return Self.taskAnswer(existing, created: false) }
        try acceptsPlanChanges(run)
        let agent = try self.agent(call), project = try self.project(call, in: run)
        // Every branch name the repository has, local and on origin (F7), and the agent's own models.
        let git = ports.git, path = project.path, models = agentModels
        let connected = try await hasCodeHost(project)
        let (repositoryBranches, catalogue) = await BackgroundWork.run { (Repository(path, git: git).branches(), models(agent)) }
        let delivery = await deliveryStatus()
        // Another call may have made this key while git was read: this one is its repeat.
        if let existing = existingTask(key, in: run) { return Self.taskAnswer(existing, created: false) }
        // The broadcast as it is now, not as the call began: a pause or an end since is the person's.
        guard let current = state.run(id: run.id), !current.hasEnded else {
            throw ToolRefusal("This broadcast has ended; its tools no longer act.")
        }
        if current.intent == .paused { throw ToolRefusal("The person paused this broadcast. Wait until they resume it.") }
        let draft = try self.draft(call, in: current, catalogue: catalogue, connected: connected, delivery: delivery)
        // Past the first plan, the backlog grows by a quarter of it on the Operator's word, then by the Oracle's yes (spec §4.1).
        switch vettedCalls.contains(Self.invocation(call)) ? .free : backlogVerdict(current) {
        case .free: break
        case .refused:
            let filing = await noteFind(call, in: current, why: "Past the backlog limit with the Oracle off.")
            throw ToolRefusal("Past the backlog limit with the Oracle off. AiTerm noted it for the summary" + Self.ending(filing))
        case .needsOracle:
            // Another addition took the last free place while git was read: this one needs the Oracle's check now.
            throw ToolRefusal("The backlog reached its limit while AiTerm read this: call create_task again for the Oracle’s check.")
        }
        let ticket = draft.ticket, title = draft.title, brief = draft.brief
        let branch = OperatedBranch.name(ticket: ticket, title: title, issueType: draft.issueType,
                                         taken: OperatedBranch.taken(in: state, project: draft.project.id, repositoryBranches: repositoryBranches))
        var task = TaskItem(id: UUID(), projectId: draft.project.id, title: title, branch: branch, worktreePath: "", baseBranch: "",
                            jira: ticket.map { JiraRef(key: $0, summary: title, url: Self.ticketURL($0, in: draft.project)) },
                            agent: draft.agent, model: draft.model.model, reasoning: draft.model.reasoning, firstPrompt: brief, appendTicket: false,
                            createdAt: ports.now(), windowId: nil)
        task.operated = OperatedTask(runId: current.id, key: key, state: .planned, end: draft.end, brief: brief, dependsOn: draft.dependencies,
                                     stackedOn: draft.dependencies.first { $0.kind == .code }?.task, revision: current.openRevision,
                                     modelReason: draft.modelReason, agentPinned: draft.agentPinned)
        mutate(in: run.id) { $0.tasks.append(task) }
        let answer = Self.taskAnswer(task, created: true)
        return draft.deliveryWarning.map { answer.adding("warning", .string($0)) } ?? answer
    }

    private func existingTask(_ key: String, in run: OperatorRun) -> TaskItem? {
        state.tasks(inRun: run.id).first { $0.operated?.key == key }
    }

    /// Where an addition stands against the backlog's budget: free while the first plan is open, then
    /// `BacklogBudget`'s word on the tasks added since. The first plan is revision 1, the first submitted.
    func backlogVerdict(_ run: OperatorRun) -> BacklogBudget.Verdict {
        guard let first = run.firstPlanSize else { return .free }
        let additions = state.tasks(inRun: run.id).filter { ($0.operated?.firstRevision ?? 1) > 1 }.count
        return BacklogBudget.verdict(firstPlanSize: first, additionsSoFar: additions, oracleIsOn: run.profile.oracle.isOn)
    }

    /// An addition past the backlog's limit, refused: AiTerm notes it for the summary (spec §4.2), once per key,
    /// as `report_find` would, and filed in Jira when the Jira slice is on.
    func noteFind(_ call: ToolCall, in run: OperatorRun, why: String) async -> Filing {
        guard let key = call.optionalString("key") else { return .notAttempted }
        if state.run(id: run.id)?.finds.contains(where: { $0.key == key }) == false {
            let find = OffBriefFind(key: key, title: call.optionalString("title") ?? key, why: why)
            mutate(in: run.id) { $0.updateRun(id: run.id) { $0.finds.append(find) } }
        }
        return await fileFind(key: key, in: run.id)
    }

    /// What the veto's call would be refused for, checked before the Oracle is asked: the plan open to
    /// changes, the agent, its model in the agent's list, the project, the end and the dependencies.
    func vetoPrecheck(_ call: ToolCall, in run: OperatorRun) async throws {
        try acceptsPlanChanges(run)
        let agent = try self.agent(call), models = agentModels
        let catalogue = await BackgroundWork.run { models(agent) }
        let project = try self.project(call, in: run)
        let connected = try await hasCodeHost(project)
        let delivery = await deliveryStatus()
        _ = try draft(call, in: state.run(id: run.id) ?? run, catalogue: catalogue, connected: connected, delivery: delivery)
    }

    /// What `create_task` asks for, checked against `run` as it is now: nothing is changed here.
    private struct NewTask {
        var title: String, brief: String, ticket: String?, issueType: String?
        var project: Project, agent: AgentKind, model: (model: String, reasoning: String?), end: TaskEnd
        var modelReason: String, agentPinned: Bool
        var dependencies: [TaskDependency]
        /// Said with the answer when its agent's workers can be messaged only by halves, or not at all.
        var deliveryWarning: String?
    }

    private func draft(_ call: ToolCall, in run: OperatorRun, catalogue: [AgentModel], connected: Bool,
                       delivery: [AgentKind: AgentDelivery]?) throws(ToolRefusal) -> NewTask {
        try acceptsPlanChanges(run)
        let title = try call.string("title"), brief = try call.string("brief")
        let project = try self.project(call, in: run), agent = try self.agent(call)
        let model = try self.model(call, for: agent, catalogue: catalogue), modelReason = try call.string("modelReason")
        let end = try self.end(call) ?? ((OperatorCommand.said(run.done) == nil && !connected) ? .commit : Self.defaultEnd(for: run))
        try validateEnd(end, in: run, project: project, connected: connected)
        let pinned = call.arguments["agentPinned"]?.boolValue ?? false
        let warning = try deliveryWarning(for: agent, pinned: pinned, delivery: delivery)
        return NewTask(title: title, brief: brief, ticket: call.optionalString("ticket"), issueType: call.optionalString("issueType"), project: project, agent: agent, model: model, end: end,
                       modelReason: modelReason, agentPinned: pinned,
                       dependencies: try dependencies(call, in: run, project: project), deliveryWarning: warning)
    }

    /// A task whose agent's workers can't be messaged can't be steered or get review fixes: refused while another
    /// installed agent's can be, unless the person's words pin this one; planned with a warning otherwise. A paste-only
    /// agent is planned with what that means for each message. Nothing is said while the helper can't tell.
    /// `open_tab` checks an extra tab's agent by it too.
    func deliveryWarning(for agent: AgentKind, pinned: Bool, delivery: [AgentKind: AgentDelivery]?) throws(ToolRefusal) -> String? {
        guard let mine = delivery?[agent], mine.messaging != .auto else { return nil }
        guard mine.messaging == .off else { return mine.note }
        let name = SidebarModel.agentName(agent), why = "\(name)’s workers can’t be messaged: \(mine.note ?? "")"
        let steerable = ModelChoice.pair.first { $0 != agent && (delivery?[$0]).map { $0.messaging != .off } == true }
        if !pinned, let other = steerable {
            throw ToolRefusal(why + " A task on it can’t be steered with message_task or get review fixes. "
                              + "Plan it on \(SidebarModel.agentName(other)), which can be messaged, or set agentPinned if the person’s words name \(name).")
        }
        return why + " This task can’t be steered with message_task or get review fixes."
    }

    /// A task with no end named ends at a draft MR, or at a commit when the broadcast's Done says a commit
    /// and names no merge request or merge.
    static func defaultEnd(for run: OperatorRun) -> TaskEnd {
        let done = OperatorCommand.said(run.done)?.lowercased() ?? ""
        let saysRequest = done.contains(/\b(mrs?|prs?|merge|merged|merges|merge requests?|pull requests?)\b/)
        return done.contains(/\bcommits?\b/) && !saysRequest ? .commit : .draftMR
    }

    /// Only an origin whose host AiTerm can connect to supports a remote publication end. Git saying there is no origin
    /// (exit 2), or no repository to have one (a folder that is none, or is gone), is no origin; any other failure of
    /// git's (a timeout, a config it can't read) is refused with git's own words, not read as no origin.
    private func hasCodeHost(_ project: Project) async throws(ToolRefusal) -> Bool {
        let git = ports.git, path = project.path
        let origin: String?
        do { origin = try await BackgroundWork.run({ try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) }) }
        catch let error as GitError where Self.isNoRepository(error) { return false }
        catch _ where !FileManager.default.fileExists(atPath: path) { return false }
        catch {
            throw ToolRefusal("AiTerm couldn’t read \(project.name)’s origin: \((error as? GitError)?.reason ?? error.localizedDescription)")
        }
        guard let origin else { return false }
        let remote = ProviderDetector.detect(remoteUrl: origin, repoPath: path)
        do { _ = try ports.publisher(remote); return true } catch { return false }
    }

    /// Git's answer that the folder is no repository, or is gone: in its own words, which `GitRunner` keeps English.
    private static func isNoRepository(_ error: GitError) -> Bool {
        !error.timedOut && error.code == 128 && (error.stderr.contains("not a git repository") || error.stderr.contains("cannot change to"))
    }

    private func validateEnd(_ end: TaskEnd, in run: OperatorRun, project: Project, connected: Bool) throws(ToolRefusal) {
        if end.merges, !run.profile.slices.merge {
            throw ToolRefusal("Merge is off for this broadcast: end it at a commit or a draft MR.")
        }
        if (end == .draftMR || end == .merge), !connected {
            throw ToolRefusal("\(project.name) has no connected code host: end it at a commit.")
        }
    }

    /// The agents' model lists, as the ports read them; none read is an empty list.
    var agentModels: @Sendable (AgentKind) -> [AgentModel] { ports.agentModels ?? { _ in [] } }

    /// The installed agents, as the ports say; every agent when nothing says.
    var installedAgents: Set<AgentKind> { ports.installedAgents?() ?? Set(AgentKind.allCases) }

    /// Only an unstarted task changes here; a started one is steered with `message_task` (spec §6).
    /// A change joins the open revision, and a queued task waits for that revision again.
    func updateTask(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run)
        guard let operated = task.operated, operated.state == .planned || operated.state == .queued, operated.launch == nil else {
            throw ToolRefusal("\(task.operated?.key ?? task.title) has started: steer it with message_task, and log the steer with log_decision.")
        }
        try acceptsPlanChanges(run)
        let project = state.project(id: task.projectId)
        // The origin is read only for an end it checks: a git that can't read it holds up no other change.
        let connected = if let project, call.arguments["end"] != nil { try await hasCodeHost(project) } else { false }
        let brief = call.optionalString("brief")
        let agent = try call.optionalString("agent").map { _ in try self.agent(call) }
        // A new agent with no model named takes that agent's default, not the old agent's model; a model named
        // is checked against its agent's own list, read off the main actor.
        let model: (model: String, reasoning: String?)?
        if (agent != nil && agent != task.agent) || call.optionalString("model") != nil {
            let target = agent ?? task.agent, models = agentModels
            let catalogue = await BackgroundWork.run { models(target) }
            model = try self.model(call, for: target, catalogue: catalogue)
        } else {
            model = nil
        }
        // The read may have let the task start, or you pause the broadcast: check both again.
        guard let current = state.task(id: task.id), let fresh = current.operated, fresh.state == .planned || fresh.state == .queued,
              fresh.launch == nil else {
            throw ToolRefusal("\(task.operated?.key ?? task.title) has started: steer it with message_task, and log the steer with log_decision.")
        }
        // Another update may have switched the agent meanwhile: a model checked against the old agent's list is not saved on it.
        if model != nil, current.agent != task.agent {
            throw ToolRefusal("The task’s agent changed while this update was checked: call update_task again.")
        }
        try acceptsPlanChanges(state.run(id: run.id) ?? run)
        let end = try self.end(call)
        if let end, let project { try validateEnd(end, in: state.run(id: run.id) ?? run, project: project, connected: connected) }
        let dependencies = try call.arguments["dependsOn"].map { _ in try self.dependencies(call, in: run, project: project) }
        if let dependencies, dependencies.contains(where: { $0.task == task.id }) { throw ToolRefusal("A task can’t depend on itself.") }
        do {
            try mutate(in: run.id) { state in
                guard let i = state.tasks.firstIndex(where: { $0.id == task.id }), var record = state.tasks[i].operated else { return }
                if let brief { record.brief = brief; state.tasks[i].firstPrompt = brief }
                if let agent { state.tasks[i].agent = agent }
                if let model { state.tasks[i].model = model.model; state.tasks[i].reasoning = model.reasoning }
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

    /// Closes the open revision through `PlanRevision.submit`, the plan-validation step, which refuses a plan whose
    /// dependencies or ends cannot work, with the reason. Its tasks are released at once and the broadcast is active.
    /// A revision already submitted changes nothing and says so: it carries no `released` count, which would read as
    /// "nothing was released".
    func submitPlan(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        guard let revision = call.arguments["revision"]?.intValue else {
            throw ToolRefusal("submit_plan needs `revision`, the open revision run_status shows.")
        }
        try acceptsPlanChanges(run)
        let submitted: PlanRevision.Submitted
        do {
            submitted = try mutate(in: run.id) { try PlanRevision.submit(revision, run: run.id, in: &$0) }
        } catch let failure as PlanRevision.Failure {
            throw ToolRefusal(failure.description)
        }
        let current = state.run(id: run.id) ?? run
        var answer: JSONValue = ["revision": .int(submitted.revision), "openRevision": .int(current.openRevision), "submitted": true,
                                 "repeated": .bool(submitted.repeated)]
        if submitted.repeated {
            answer = answer.adding("note", .string("Revision \(submitted.revision) was already submitted; nothing changed."))
        } else {
            answer = answer.adding("released", .int(submitted.released.count))
        }
        return answer
    }

    // -- reading a call ------------------------------------------------------------------------
    /// The plan changes while the broadcast runs or plans — not while you have paused it.
    func acceptsPlanChanges(_ run: OperatorRun) throws(ToolRefusal) {
        switch run.state {
        case .planning, .active, .complete: return
        case .paused: throw ToolRefusal("The person paused this broadcast. Wait until they resume it.")
        case .operatorOffline: throw ToolRefusal("AiTerm has this broadcast offline; it resumes it first.")
        case .stopped: throw ToolRefusal("This broadcast was stopped; its tools no longer act.")
        }
    }

    /// The project a task goes in: one of the broadcast's. No project joins a broadcast.
    private func project(_ call: ToolCall, in run: OperatorRun) throws(ToolRefusal) -> Project {
        let ref = try call.string("project")
        let projects = run.projectIds.compactMap(state.project(id:))
        guard let project = projects.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame || $0.name.caseInsensitiveCompare(ref) == .orderedSame
        }) else {
            throw ToolRefusal("\(ref) isn’t one of this broadcast’s projects: \(projects.map(\.name).joined(separator: ", ")).")
        }
        return project
    }

    func agent(_ call: ToolCall) throws(ToolRefusal) -> AgentKind {
        switch try call.string("agent").lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        default: throw ToolRefusal("The Operator’s task runs claude or codex.")
        }
    }

    /// The model the call names, which must be in the agent's own list in Settings › Agents (spec §15), or
    /// the default Settings › Agents gives the agent. The agent must be installed either way.
    func model(_ call: ToolCall, for agent: AgentKind, catalogue: [AgentModel]) throws(ToolRefusal) -> (model: String, reasoning: String?) {
        let requested = call.optionalString("model"), fallback = defaultModel(for: agent)
        if requested == nil, fallback.model.isEmpty, installedAgents.contains(agent) {
            throw ToolRefusal("Pass a model: AiTerm has no default model for \(agent.harness.displayName) yet.")
        }
        do {
            return try ModelChoice.resolve(agent: agent, requested: requested, installed: installedAgents, catalogue: catalogue,
                                           defaultModel: fallback)
        } catch {
            switch error {
            case .notInstalled(let agent):
                throw ToolRefusal("\(agent.harness.displayName) isn’t installed on this Mac. Choose an installed agent from run_status.")
            case .unknownModel(let model, let agent):
                let ids = catalogue.map(\.id)
                throw ToolRefusal("\(model) isn’t in \(agent.harness.displayName)’s model list in Settings › Agents. "
                                  + (ids.isEmpty ? "AiTerm could read no list for it, so leave model out to take its default."
                                                 : "Its models are: \(ids.joined(separator: ", "))."))
            }
        }
    }

    /// The model and reasoning Settings › Agents gives `agent`, else the model last picked for it.
    func defaultModel(for agent: AgentKind) -> (model: String, reasoning: String?) {
        Self.defaultModel(for: agent, remembered: state.lastModelByAgent)
    }

    /// `defaultModel(for:)` over the models remembered in `state`, for a launch that moves a task to the other agent.
    static func defaultModel(for agent: AgentKind, remembered: [AgentKind: String]) -> (model: String, reasoning: String?) {
        AgentIntegrations.taskModels(remembered: remembered)(agent)
    }

    private func end(_ call: ToolCall) throws(ToolRefusal) -> TaskEnd? {
        guard let raw = call.optionalString("end") else { return nil }
        guard let end = TaskEnd(rawValue: raw) else { throw ToolRefusal("A task’s end is commit, draftMR, merge or mergeLocal.") }
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
            guard let parent = state.task(inRun: run.id, named: ref) else { throw ToolRefusal("dependsOn names \(ref), which isn’t a task of this broadcast.") }
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

    /// The ticket's page, from the Jira project of the broadcast's project it belongs to; none when no link says.
    static func ticketURL(_ key: String, in project: Project) -> String {
        project.jiraProjects.first { key.uppercased().hasPrefix($0.key.uppercased() + "-") }
            .map { $0.siteURL.appendingPathComponent("browse/\(key)").absoluteString } ?? ""
    }

    static func taskAnswer(_ task: TaskItem, created: Bool) -> JSONValue {
        ["task": .string(task.id.uuidString), "key": .string(task.operated?.key ?? ""), "state": .string(task.operated?.state.rawValue ?? ""),
         "revision": .int(task.operated?.revision ?? 0), "created": .bool(created)]
    }
}

extension JSONValue {
    /// This object with `key` set; anything else unchanged.
    func adding(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var members) = self else { return self }
        members[key] = value
        return .object(members)
    }
}
