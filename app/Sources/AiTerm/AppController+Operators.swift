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

    /// A chip on the folded OPERATOR or PROJECTS heading: the section opens, folding the other, at the row the chip
    /// stands for (`SidebarProjection.firstRow(in:chip:)`), whose project unfolds in that section, and the row is selected, its window shown as the arrows show one.
    @discardableResult
    func openSection(_ section: SidebarSection, at chip: ChipTarget) -> Task<Void, Never>? {
        guard let first = rows.firstRow(in: section, chip: chip) else { return nil }
        reveal(RowSelection(first))
        return focus.peek(RowSelection(first), force: true)
    }

    /// A click on the OPERATOR or PROJECTS heading: the folded one opens, folding the other. Kept with
    /// the workspace, as a project's fold is.
    func toggleOperatorOpen() {
        guard rows.operatorHeading.folds else { return }
        setOperatorOpen(!rows.operatorOpen)
    }

    /// ↓ on the Operator's last row, or ↑ on the first project: the arrow crosses the fold, opening the other
    /// section, folding this one, and peeking at the row it reaches as the list's own arrows do. False where the
    /// list moves on its own (`SidebarProjection.crossing(from:down:)`).
    @discardableResult
    func crossSections(down: Bool) -> Bool {
        guard canChangeWorkspace, let selection = focus.selection,
              let target = rows.crossing(from: selection, down: down) else { return false }
        reveal(target)
        focus.peek(target)
        return true
    }

    /// A project's heading in the Operator's section, clicked or ↩: it folds or unfolds there, apart from the
    /// project's own fold (`AppState.operatorFolded`). Nothing while the Operator runs no task of it.
    func toggleOperatorFold(_ project: Project) {
        guard canChangeWorkspace, state.project(id: project.id) != nil,
              state.tasks.contains(where: { $0.projectId == project.id && $0.isUnderOperator }) else { return }
        workspace.mutate { state in
            if !state.operatorFolded.insert(project.id).inserted { state.operatorFolded.remove(project.id) }
        }
    }

    /// Stored even while there is nothing to fold, when the projection ignores it: a new signal opens the
    /// section before its rows are derived.
    func setOperatorOpen(_ open: Bool) {
        guard canChangeWorkspace, state.operatorOpen != open else { return }
        workspace.mutate { $0.operatorOpen = open }
    }

    func signalReadiness(for signalAgents: [AgentKind]) -> SignalReadiness {
        let messaging = self.messaging
        return .of(agents: signalAgents, installed: agents.availableAgents, snapshots: agents.harnessSettingsModel().snapshots,
                   messaging: { messaging.readiness(of: $0) }, iterm: messaging.iterm)
    }

    /// A row selected through a notification, Focus View or a folded heading's chip opens its section, folding the
    /// other, then its project there: a task under the Operator unfolds its project in the Operator's section and
    /// leaves the project's own fold, any other task or a terminal its project.
    func reveal(_ row: RowSelection) {
        guard canChangeWorkspace else { return }
        if rows.operatorHeading.folds {
            let underOperator = switch row {
            case .operatorChat, .operatorProject: true
            case .task(let id): state.task(id: id)?.isUnderOperator == true
            case .project, .terminal: false
            }
            if underOperator != rows.operatorOpen { setOperatorOpen(underOperator) }
        }
        if case .task(let id) = row, let task = state.task(id: id), task.isUnderOperator {
            if state.operatorFolded.contains(task.projectId) { workspace.mutate { _ = $0.operatorFolded.remove(task.projectId) } }
        } else if case .task(let id) = row, let task = state.task(id: id),
                let project = state.project(id: task.projectId), project.collapsed { projects.toggleCollapsed(project) }
        else if case .terminal(let id) = row, let terminal = state.terminal(id: id),
                let project = state.project(id: terminal.projectId), project.collapsed { projects.toggleCollapsed(project) }
    }
}
