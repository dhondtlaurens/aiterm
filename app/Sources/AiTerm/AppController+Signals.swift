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
                at: ports.now(), preview: { source in
                    let links = await controller.connections()
                    return try await links.reader(for: source).poll(since: nil, full: true)
                }, metadata: {
                    let links = await controller.connections()
                    guard let connection = links.jira else { return SignalModel.Metadata() }
                    let jira = JiraClient(config: connection, session: links.session)
                    async let labels = jira.labels()
                    async let statuses = jira.statuses()
                    async let projects = jira.projects()
                    let users: [JiraUser]
                    if case .jira(let conditions)? = signal?.source, let id = conditions.assignee, id != "me" {
                        users = try await jira.signalUsers(accountId: id)
                    } else { users = [] }
                    return try await SignalModel.Metadata(users: users, labels: labels, statuses: statuses, projects: projects)
                }, users: { query in
                    let links = await controller.connections()
                    guard let connection = links.jira else { return [] }
                    return try await JiraClient(config: connection, session: links.session).signalUsers(query: query)
                }, ready: { [weak self] in self?.signalReadiness == .ready }, save: { value in try await controller.save(value) })
            model.readinessLines = { [weak self] in self?.signalReadiness.lines ?? [] }
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
    func takeOver(_ id: UUID) async {
        guard let task = state.task(id: id), task.signalTask?.takenOver == false else { return }
        await signalController.takeOver(id)
        if state.task(id: id)?.signalTask?.takenOver == true {
            notices.showToast((task.jira?.key ?? task.title) + " is yours. The Operator let go of it.")
        }
    }
    func toggleCollapsed(_ signal: Signal) {
        guard canChangeWorkspace else { return }
        workspace.mutate { state in
            if let index = state.signals.firstIndex(where: { $0.id == signal.id }) { state.signals[index].collapsed.toggle() }
            else { for task in state.tasks where task.signalTask?.signal == signal.id {
                state.updateSignalTask(task.id) { $0.configuration?.collapsed = !signal.collapsed }
            } }
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
            workspace.mutate { $0.signals.removeAll { $0.id == signal.id } }
        }
    }
}
