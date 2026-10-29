import Foundation
import AiTermCore

/// `open_tab`: another worker on a running task, in its window, on its worktree and branch. The tab is part of the
/// task, which keeps one card and one branch and is accepted once. Its agent and model follow `create_task`'s rules.
extension OperatorToolHandler {
    /// The checks run again after the reads off the main actor: another call may have recorded this key meanwhile, or
    /// the task moved on. The record is saved before the tab is asked for (`TabOpener`). The same key returns what the
    /// first call did, even once the task moved on; with other arguments it is refused.
    func openTab(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let task = try self.task(call, in: run), key = try call.string("key")
        guard key != WorkerTab.firstKey else {
            throw ToolRefusal("The key \(key) names \(task.operated?.key ?? task.title)’s first worker in run_status. Call open_tab with another key.")
        }
        let role: TabRole
        if let raw = call.optionalString("role") {
            guard let requested = TabRole(rawValue: raw) else { throw ToolRefusal("A tab’s role is work or review.") }
            role = requested
        } else {
            role = .work
        }
        let agent = try self.agent(call), modelReason = try call.string("modelReason")
        let brief = try role == .review ? (call.optionalString("brief") ?? "") : call.string("brief")
        let pinned = call.arguments["agentPinned"]?.boolValue ?? false
        if let recorded = try recordedTab(key, of: task, call, agent: agent, modelReason: modelReason,
                                          brief: brief, pinned: pinned, role: role, checksReasoning: true) {
            return recorded
        }
        try tabRefusal(task, in: run)
        let delivery = await deliveryStatus()
        let model = try self.model(call, for: agent, in: run)
        let warning = try deliveryWarning(for: agent, pinned: pinned, delivery: delivery, in: run)
        guard let current = state.task(id: task.id), let fresh = state.run(id: run.id) else {
            throw ToolRefusal("This task is no longer in this broadcast.")
        }
        if let recorded = try recordedTab(key, of: current, call, agent: agent, modelReason: modelReason,
                                          brief: brief, pinned: pinned, role: role, checksReasoning: true) {
            return recorded
        }
        try tabRefusal(current, in: fresh)
        var tab = ExtraTab(key: key, agent: agent, model: model.model, reasoning: model.reasoning, modelReason: modelReason, brief: brief,
                           agentPinned: pinned, launch: LaunchAttempt(number: 1, requestedAt: ports.now()), role: role)
        tab.requestedLaunch = LaunchRequest(model: call.optionalString("model"), reasoning: call.optionalString("reasoning"))
        mutate(in: run.id) { $0.updateOperated(task.id) { $0.extraTabs.append(tab) } }
        // On disk before the daemon is asked: a restart then finds the tab it opened, and opens no second one.
        guard workspace.flush() else {
            mutate(in: run.id) { $0.updateOperated(task.id) { $0.extraTabs.removeAll { $0.key == key } } }
            throw ToolRefusal("AiTerm couldn’t save the tab before opening it; call open_tab again.")
        }
        var outcome = await tabs.open(TabOpener.ID(task: task.id, key: key), attempt: tab.launch)
        if case .failed(let reason) = outcome { throw ToolRefusal(Self.tabFailure(reason)) }
        // A request that ended with no answer may have been overtaken: the reconciler found its tab meanwhile.
        let recorded = state.task(id: task.id)?.operated?.extraTabs.first { $0.key == key } ?? tab
        if outcome == .opening { outcome = TabOpener.outcome(of: recorded) == .opened ? .opened : .opening }
        let answer = Self.tabAnswer(recorded, of: current, outcome: outcome)
        return warning.map { answer.adding("warning", .string($0)) } ?? answer
    }

    /// The tab `key` names on the task already, as the first call left it; refused when this call asks for another.
    private func recordedTab(_ key: String, of task: TaskItem, _ call: ToolCall, agent: AgentKind, modelReason: String, brief: String,
                             pinned: Bool, role: TabRole, checksReasoning: Bool) throws(ToolRefusal) -> JSONValue? {
        guard let tab = task.operated?.extraTabs.first(where: { $0.key == key }) else { return nil }
        let model = call.optionalString("model")
        guard tab.agent == agent, model == nil || model == tab.model, tab.modelReason == modelReason, tab.brief == brief,
              tab.agentPinned == pinned, tab.role == role,
              !checksReasoning || call.optionalString("reasoning") == nil || tab.reasoning == call.optionalString("reasoning") else {
            throw ToolRefusal("\(task.operated?.key ?? task.title) already has a tab \(key), opened with other arguments. "
                              + "Call open_tab with another key for another tab.")
        }
        let outcome = TabOpener.outcome(of: tab)
        if case .failed(let reason) = outcome { throw ToolRefusal(Self.tabFailure(reason)) }
        return Self.tabAnswer(tab, of: task, outcome: outcome)
    }

    /// Why `task` may not have a tab opened now, in the words the other tools' refusals use.
    private func tabRefusal(_ task: TaskItem, in run: OperatorRun) throws(ToolRefusal) {
        let operated = try self.operated(task, in: run)
        guard [.working, .inReview].contains(operated.state) else {
            throw ToolRefusal("\(operated.key) is \(operated.state.rawValue): only a working task, or one in review, takes another tab.")
        }
        guard task.hasCheckout else { throw ToolRefusal("\(operated.key) hasn’t started: it has no worktree yet.") }
        guard task.windowId != nil else { throw ToolRefusal("\(operated.key)’s window isn’t open right now, so there is nowhere to add a tab.") }
    }

    static func tabFailure(_ reason: String) -> String {
        "AiTerm couldn’t open the tab: \(reason) Call open_tab with another key to try again."
    }

    static func tabAnswer(_ tab: ExtraTab, of task: TaskItem, outcome: TabOpener.Outcome) -> JSONValue {
        ["task": .string(task.operated?.key ?? ""), "key": .string(tab.key), "agent": .string(tab.agent.rawValue), "model": .string(tab.model),
         "reasoning": tab.reasoning.map(JSONValue.string) ?? .null,
         "state": .string(outcome == .opened ? "opened" : "opening")]
    }
}
