import Foundation
import AiTermCore

extension AppController {
    var canPresentNewSignal: Bool { canUseFileMenu }
    func presentNewSignal(editing signal: Signal? = nil) {
        guard canPresentNewSignal else { return }
        let controller = signalController, ports = controller.ports
        let installed = ports.installedAgents(), models = ports.agentModels, remembered = state.lastModelByAgent
        nonisolated(unsafe) let defaults = ports.preferences
        let home = ports.home, config = ports.claudeConfig, paths = state.projects.map(\.path)
        Task { [weak self] in
            let context = await BackgroundWork.run {
                SignalContext.read(installed: installed, models: models, remembered: remembered, preferences: defaults)
            }
            guard let self, self.canPresentNewSignal else { return }
            let model = SignalModel(signal: signal, projects: self.state.projects, context: context, seen: self.state.signalSeen,
                at: ports.now(), preview: { trigger in
                    let links = await controller.connections()
                    return try await links.reader(for: trigger).poll(since: nil, full: true)
                }, save: { [weak self] value in
                    try await controller.save(value)
                    // A new signal opens the Operator's section, where its tasks will be.
                    if signal == nil { self?.setOperatorOpen(true) }
                })
            // What the query writer is told, read once as the sheet opens; a part that cannot be read is left out.
            let projects = self.state.projects, readProfile = ports.profile, headless = ports.queryWriter
            let writerContext = Task { await controller.connections().writerContext(projects: projects) }
            model.writeQuery = { trigger, start in
                let links = await controller.connections(), context = await writerContext.value
                let profile = await BackgroundWork.run(readProfile)
                let runner = QueryWriterRunner(headless: headless, check: { await links.check($0, start: $1, query: $2) },
                                               model: profile.model, reasoning: profile.reasoning)
                return await runner.write(source: trigger.source, start: start, description: trigger.description, context: context)
            }
            model.readiness = { [weak self] in self?.signalReadiness(for: $0) ?? .ready }
            model.checkReadiness = { [weak self] in await self?.checkSignalReadiness() }
            model.loadCompletions = { [weak model] in
                let found = await BackgroundWork.run {
                    OperatorSkills.listed(at: paths.isEmpty ? [nil] : paths.map(Optional.some)) {
                        SkillCatalog.discover(agent: $0, projectPath: $1, home: home, claudeConfig: config)
                    }
                }
                guard !Task.isCancelled else { return }; model?.completions.all = found
            }
            self.sheets.present(signal: model)
        }
    }
    /// The person's Take Over of a driven task (`TaskLauncher.takeOver`), said in a toast once it is theirs.
    func takeOver(_ id: UUID) async {
        guard let task = state.task(id: id), task.isUnderOperator else { return }
        await launcher.takeOver(id)
        if state.task(id: id)?.takenOver == true {
            notices.showToast((task.jira?.key ?? task.title) + " is yours. The Operator let go of it.")
        }
    }
    func toggleCollapsed(_ signal: Signal) {
        guard canChangeWorkspace else { return }
        if let index = state.signals.firstIndex(where: { $0.id == signal.id }) {
            workspace.mutate { $0.signals[index].collapsed.toggle() }
        } else {
            rows.toggleRemovedSignal(signal.id)
            refreshRows()
        }
    }

    /// Moves a signal's heading one place among the live signals, which also changes its priority for
    /// items several signals match. The neighbour is the current one, so a stale menu at a new edge does nothing.
    @discardableResult
    func moveSignal(_ id: UUID, _ step: MoveStep) -> Bool {
        guard canChangeWorkspace else { return false }
        return workspace.mutate { $0.move(signalId: id, step) }
    }

    func toggleEnabled(_ signal: Signal) {
        guard canChangeWorkspace, var current = state.signal(id: signal.id) else { return }
        current.enabled.toggle()
        attempt("Couldn’t save the signal") { try await self.signalController.save(current) }
    }
    func removeSignal(_ signal: Signal) {
        guard canChangeWorkspace else { return }
        Task {
            guard await prompter.ask(AlertPrompt(message: "Remove “\(signal.name)”?",
                detail: "It stops watching for new matches. Its existing tasks carry on with their saved instructions.",
                buttons: ["Remove Signal", "Cancel"], defaultDeletes: true)).confirmed else { return }
            workspace.mutate { $0.removeSignal(id: signal.id) }
        }
    }

    // -- dividers among the signals ---------------------------------------------------------
    /// A label only, as a project divider is: workspace state, no daemon call, and no change to priority.
    func addSignalDivider(name: String) {
        guard canChangeWorkspace, !state.signals.isEmpty else { return }
        let divider = SignalDivider(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        workspace.mutate { $0.append(signalDivider: divider) }
    }

    /// An empty name is a real choice: the row draws a plain rule.
    func renameSignalDivider(_ id: UUID, to name: String) {
        guard canChangeWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.mutate { $0.renameSignalDivider(id: id, to: trimmed) }
    }

    /// The neighbour is the current one, so a stale menu at a new edge does nothing.
    @discardableResult
    func moveSignalDivider(_ id: UUID, _ step: MoveStep) -> Bool {
        guard canChangeWorkspace else { return false }
        return workspace.mutate { $0.move(signalDividerId: id, step) }
    }

    func removeSignalDivider(_ id: UUID) {
        guard canChangeWorkspace else { return }
        workspace.mutate { $0.removeSignalDivider(id: id) }
    }

    /// File ▸ Add Divider… (⌘D): into the open section. With the Operator's open and no signal to stand between, nothing.
    func presentNewDividerInOpenSection() {
        guard rows.operatorOpen else { return sheets.presentNewDivider(in: .projects) }
        if canAddSignalDivider { sheets.presentNewDivider(in: .operator) }
    }

    /// Whether Add Divider… can add one among the signals: a divider with no signal to stand between draws nothing.
    var canAddSignalDivider: Bool { canChangeWorkspace && !state.signals.isEmpty }
}
