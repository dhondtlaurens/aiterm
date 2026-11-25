import Foundation
import AiTermCore

extension AppController {
    var canPresentNewSignal: Bool { canUseFileMenu }
    /// New Signal… makes the kind of the place it was chosen in (an Operator signal from the Operator's heading and
    /// sheet, a project signal from the projects'); Edit Signal… keeps the signal's own kind.
    func presentNewSignal(kind: Signal.Kind = .operator, editing signal: Signal? = nil) {
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
            let model = SignalModel(signal: signal, kind: kind, projects: self.state.projects, context: context, seen: self.state.signalSeen,
                at: ports.now(), preview: { trigger in
                    let links = await controller.connections()
                    return try await links.reader(for: trigger).poll(since: nil, full: true)
                }, save: { [weak self] value in
                    try await controller.save(value)
                    // A new Operator signal opens the Operator's section, where its tasks will be; a project signal's start
                    // in their projects.
                    if signal == nil, !value.isProject { self?.setOperatorOpen(true) }
                })
            // What the query writer is told, read once as the sheet opens; a part that cannot be read is left out.
            let projects = self.state.projects, readProfile = ports.profile, headless = ports.queryWriter
            let writerContext = Task { await controller.connections().writerContext(projects: projects) }
            model.writeQuery = { trigger, start in
                let links = await controller.connections()
                // Write cron's "now" is the moment Write is pressed, not when the sheet opened.
                var context = await writerContext.value
                context.now = ports.now(); context.timeZone = .current
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
    // -- the signals sheet ------------------------------------------------------------------------
    /// `section`'s signals sheet (the heading's signals icon): its rows read the workspace and the failing reads
    /// whenever it draws. Edit Signal… and New Signal… take its place in the one sheet slot, and it does not reopen.
    func presentSignals(_ section: SidebarSection) {
        let controller = signalController
        sheets.presentSignals(SignalsSheetModel(section: section, rows: { [weak self] in
            guard let self else { return [] }
            let issues = controller.readIssues
            return SignalsSheetModel.rows(state: self.state, section: section, failure: { issues.issue(for: $0) },
                                          now: controller.ports.now())
        }, actions: .init(
            edit: { [weak self] id in
                guard let self, let current = self.state.signal(id: id) else { return }
                self.replaceSignalsSheet { $0.presentNewSignal(editing: current) }
            },
            switchOnOff: { [weak self] id in if let self, let current = self.state.signal(id: id) { self.toggleEnabled(current) } },
            move: { [weak self] id, step in self?.moveSignalPriority(id, step) },
            remove: { [weak self] id in if let self, let current = self.state.signal(id: id) { self.removeSignal(current) } },
            new: { [weak self] in self?.replaceSignalsSheet { $0.presentNewSignal(kind: section.signalKind) } },
            canChange: { [weak self] in self?.canChangeWorkspace ?? false },
            canEdit: { [weak self] in self?.canChangeWorkspace ?? false })))
    }

    /// Empties the slot the signals sheet holds and opens `next` in it (O8: one sheet slot; the list does not reopen).
    private func replaceSignalsSheet(_ next: (AppController) -> Void) {
        guard canChangeWorkspace, case .signals = sheet else { return }
        sheet = nil
        next(self)
    }

    /// Moves a signal one place in its kind's priority, past any divider on the way: what the signals sheet's Move Up and
    /// Move Down do, where dividers are not drawn. Nothing when no signal of its kind lies that way.
    @discardableResult
    func moveSignalPriority(_ id: UUID, _ step: MoveStep) -> Bool {
        guard canChangeWorkspace, let signal = state.signal(id: id) else { return false }
        func kin(_ state: AppState) -> [UUID] { state.signals.filter { $0.isProject == signal.isProject }.map(\.id) }
        let before = kin(state)
        guard let index = before.firstIndex(of: id), before.indices.contains(index + (step == .up ? -1 : 1)) else { return false }
        return workspace.mutate { state in
            while kin(state) == before, state.move(signalId: id, step) {}
            return kin(state) != before
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

    /// File › New Signal… (⌘S): the open section's kind (O4).
    func presentNewSignalInOpenSection() { presentNewSignal(kind: rows.operatorOpen ? .operator : .project) }
}

extension SidebarSection {
    /// The kind of signal New Signal… makes in this section.
    var signalKind: Signal.Kind { self == .operator ? .operator : .project }
}
