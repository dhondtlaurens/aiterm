import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The creation sheets read their models through the app's `ModelCatalogue`, as
/// `SheetCoordinator.makeCreationModel` wires them.
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

    /// The sheet is handed the reading its draft was built from, failure and all: a PI that
    /// fails to launch is not launched a second time for the same opening.
    @Test func aHandedFailureIsShownWithoutReadingAgain() async {
        let reads = Mutex(0)
        let model = sheet(catalogue: { _ in reads.withLock { $0 += 1 }; return [] },
                          initialCatalogue: [], initialCatalogueFailure: "PI couldn’t be launched.")
        await model.loadAgentCatalogue()
        #expect(reads.withLock { $0 } == 0)
        #expect(model.catalogueFailure == "PI couldn’t be launched.")
    }

    @Test func slowSkillsDoNotHoldModelReadinessOrPublishAfterSwitchingHarness() async throws {
        let home = try ScratchFolder.make(), entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        var context = CreationContext.scratch(home: home, catalogue: { _ in [AgentModel(id: "demo", label: "Demo", detail: nil, efforts: [], defaultEffort: nil)] })
        context.nativeSkills = NativeSkills { _, _, _ in
            entered.continuation.yield()
            entered.continuation.finish()
            _ = release.wait(timeout: .now() + 10)
            return #"[{"name":"example","enabled":true,"skills":["debug"]}]"#
        }
        let model = TaskCreationModel(project: .make(name: "Repo", path: home.path, addedAt: Date()),
                                     draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .agy, model: "demo", reasoning: nil),
                                     context: context, searchIssues: { _ in [] }, createTask: { _ in })
        let pending = Task { await model.loadSkills() }
        for await _ in entered.stream { break }
        await model.loadAgentCatalogue()
        #expect(model.agentIsReady)
        model.selectAgent(.codex)
        release.signal()
        await pending.value
        #expect(model.completions.all.isEmpty)
    }

    @Test func aSlowReviewReadCannotReplaceTheCurrentCheckoutsSuggestions() async throws {
        let home = try ScratchFolder.make(), first = try ScratchFolder.make(), second = try ScratchFolder.make()
        let release = DispatchSemaphore(value: 0), started = Mutex(false)
        var context = CreationContext.scratch(home: home)
        context.nativeSkills = NativeSkills { _, cwd, _ in
            if cwd?.path == first.path {
                started.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 60)
            }
            let name = cwd?.path == second.path ? "current" : "previous"
            return #"{"type":"response","command":"get_commands","id":"aiterm-skills","success":true,"data":{"commands":[{"name":"skill:\#(name)","source":"skill","sourceInfo":{"scope":"user"}}]}}"#
        }
        let model = ReviewCreationModel(project: .make(name: "Repo", path: home.path, addedAt: Date()),
                                        draft: ReviewDraft(mr: nil, agent: .pi, model: "demo", reasoning: nil), context: context,
                                        searchMergeRequests: { _ in [] }, createReview: { _ in }, recover: { _ in })
        let previous = Task { await model.loadSkills(existingWorktree: first.path) }
        defer { release.signal() }
        try #require(await eventually { started.withLock { $0 } })
        await model.loadSkills(existingWorktree: second.path)
        release.signal()
        await previous.value
        #expect(model.completions.all.map(\.name) == ["skill:current"])
    }

    private func sheet(catalogue: @escaping @Sendable (AgentKind) throws -> [AgentModel],
                       initialCatalogue: [AgentModel]? = nil, initialCatalogueFailure: String? = nil) -> TaskCreationModel {
        let project = Project.make(name: "Repo", path: "/tmp/repo", addedAt: Date())
        let draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .pi, model: "", reasoning: nil)
        return TaskCreationModel(project: project, draft: draft,
                                 context: .scratch(catalogue: catalogue, initialCatalogue: initialCatalogue, initialCatalogueFailure: initialCatalogueFailure),
                                 searchIssues: { _ in [] }, createTask: { _ in })
    }
}
