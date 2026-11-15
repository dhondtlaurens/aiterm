import Foundation
import AiTermCore

extension AppController {
    func attempt(_ title: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in await attemptNow(title, work) }
    }

    @discardableResult
    func attemptNow(_ title: String, _ work: @MainActor () async throws -> Void) async -> Bool {
        do { try await work(); return true } catch { notices.report(OperationIssue(title: title + ".", error: error)); return false }
    }

    func checkSignalReadiness() async {
        let planned = ModelChoice.pair.filter(agents.availableAgents.contains), harness = agents.harnessSettingsModel()
        async let probes: Void = harness.load(planned)
        async let watch: Void = messaging.watch()
        _ = await (probes, watch)
    }

    func presentAgentSettings(for agent: AgentKind) {
        sheets.presentSettings(tab: .agents, agent: agent)
    }

    @discardableResult
    func bringTab(task id: UUID, sessionId: String) -> Task<Void, Never> {
        let raising = focus.select(.task(id))
        return Task { @MainActor [helper] in
            await raising?.value
            try? await helper.daemon?.activate(sessionId: sessionId)
        }
    }

    @discardableResult
    func openProjectsAttention() -> Task<Void, Never>? {
        guard let first = rows.projectsNeedingAttention.first else { return nil }
        reveal(RowSelection(first))
        return focus.peek(RowSelection(first), force: true)
    }

    var signalReadiness: SignalReadiness {
        let messaging = self.messaging
        return .of(installed: agents.availableAgents, snapshots: agents.harnessSettingsModel().snapshots,
                   messaging: { messaging.readiness(of: $0) }, iterm: messaging.iterm)
    }

    func reveal(_ row: RowSelection) {
        guard canChangeWorkspace else { return }
        if case .task(let id) = row, let task = state.task(id: id), let record = task.signalTask, !record.takenOver,
           let signal = state.signal(id: record.signal), signal.collapsed { toggleCollapsed(signal) }
        else if case .task(let id) = row, let task = state.task(id: id),
                let project = state.project(id: task.projectId), project.collapsed { projects.toggleCollapsed(project) }
    }
}
