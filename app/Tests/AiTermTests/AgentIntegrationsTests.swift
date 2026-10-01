import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// What AgentIntegrations hears from, and tells, the workspace it serves.
@MainActor
struct AgentIntegrationsTests {
    private func controller() throws -> (AppController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: root.appendingPathComponent("home"), bundledResourcesURL: nil)
        try controller.loadWorkspace()
        return (controller, root)
    }

    /// A CLI installed from Settings is offered by the New Task sheet already open, without a relaunch.
    @Test func anOpenCreationSheetOffersACLISettingsInstalled() throws {
        let (controller, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.agents.availableAgents = [.claude]
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let model = controller.makeCreationModel(
            project: project, draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil),
            catalogue: [], jira: nil)
        controller.sheet = .newTask(model)
        #expect(model.availableAgents == [.claude])

        controller.agents.harnessSettingsModel().cliInstalled(.pi)
        #expect(model.availableAgents == [.claude, .pi])
    }

    /// Settings' model pickers fall back on the model each agent last ran with, read from the
    /// workspace as it is when asked — tasks created while Settings is retained change the answer.
    @Test func theSettingsModelReadsTheWorkspacesRememberedModels() throws {
        let (controller, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = controller.agents.harnessSettingsModel()
        #expect(settings.rememberedModels().isEmpty)

        controller.state.lastModelByAgent[.codex] = "gpt-5.6"
        #expect(settings.rememberedModels() == [.codex: "gpt-5.6"])
    }
}
