import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The creation sheets read their models through the app's `ModelCatalogue`, as
/// `AppController.makeCreationModel` wires them.
@MainActor
struct CreationCatalogueTests {
    /// Every opening of a sheet with PI picked, and every switch back to PI, launched PI's CLI. Now
    /// the list read the first time stands while nothing PI reads has changed.
    @Test func reopeningASheetAndSwitchingAgentsLaunchesPiOnce() async {
        let launches = Mutex(0)
        let catalogue = ModelCatalogue(home: ScratchHome.bare, runner: HarnessCommandRunner(
            locate: { $0 == "pi" ? "/usr/bin/true" : nil },
            run: { _, _, _, _ in
                launches.withLock { $0 += 1 }
                return ProcessOutput(status: 0, stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n",
                                     stderr: "", timedOut: false)
            }))
        for _ in 0..<2 {
            let model = sheet(catalogue: { try catalogue.models(for: $0) })
            await model.loadAgentCatalogue()
            #expect(model.models.map(\.id) == ["openai/model-x"])
            model.selectAgent(.claude)
            await model.loadAgentCatalogue()
            model.selectAgent(.pi)
            await model.loadAgentCatalogue()
            #expect(model.models.map(\.id) == ["openai/model-x"])
        }
        #expect(launches.withLock { $0 } == 1)
    }

    /// PI's complaint takes the model picker's place, instead of a sign-in hint that may not help.
    @Test func aSheetSaysWhyPiHasNoModels() async {
        let catalogue = ModelCatalogue(home: ScratchHome.bare, runner: HarnessCommandRunner(
            locate: { _ in "/usr/bin/true" },
            run: { _, _, _, _ in ProcessOutput(status: 1, stdout: "", stderr: "No API key for openai\n", timedOut: false) }))
        let model = sheet(catalogue: { try catalogue.models(for: $0) })
        await model.loadAgentCatalogue()
        #expect(model.models.isEmpty)
        #expect(model.catalogueFailure == "The PI model catalogue is unavailable: No API key for openai")
        #expect(AgentStep.modelPlaceholder(agent: .pi, catalogueLoaded: true, failure: model.catalogueFailure)
                == "The PI model catalogue is unavailable: No API key for openai")

        model.selectAgent(.claude)
        #expect(model.catalogueFailure == nil)
        await model.loadAgentCatalogue()
        #expect(model.catalogueFailure == nil)
        #expect(!model.models.isEmpty)
    }

    private func sheet(catalogue: @escaping @Sendable (AgentKind) throws -> [AgentModel]) -> TaskCreationModel {
        let project = Project(id: UUID(), name: "Repo", path: "/tmp/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .pi, model: "", reasoning: nil)
        return TaskCreationModel(project: project, draft: draft, home: ScratchHome.bare, catalogue: catalogue,
                                 defaults: ScratchDefaults.make(), git: .hermetic(), searchIssues: { _ in [] }, createTask: { _ in })
    }
}
