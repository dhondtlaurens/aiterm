import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
@Suite(.blocking) struct UnbornTaskCreationTests {
    @Test(arguments: ["main", "master", "team/trunk"])
    func consentInitializesAndRetriesTheRealCreationFlow(branch: String) async throws {
        let fixture = try Fixture(branch: branch)
        defer { fixture.cleanUp() }
        let model = try await fixture.model()
        model.promptText = "Keep this prompt"
        await model.loadBranches()
        #expect(model.branches == [branch])
        #expect(await model.create() == false)
        #expect(model.error?.recovery == .initializeRepository(on: branch))
        #expect(model.error?.reason.contains("no commits") == true)
        // Pressing Create again is not consent to initialize. The separate recovery is explicit.
        #expect(await model.create() == false)
        #expect(try Repository(fixture.path, git: fixture.git).commit("HEAD") == nil)
        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(fixture.daemon.requests("window.createTask").isEmpty)
        #expect(model.draft.title == "First task" && model.promptText == "Keep this prompt")

        #expect(await model.recoverAndCreate())

        let task = try #require(fixture.controller.state.tasks.first)
        #expect(task.baseBranch == branch && task.branch == "feat/first-task")
        #expect(task.firstPrompt == "Keep this prompt")
        #expect(task.windowId != nil)
        #expect(fixture.daemon.requests("window.createTask").count == 1)
        let repository = Repository(fixture.path, git: fixture.git)
        #expect(try repository.commit(branch) == repository.commit(task.branch))
        #expect(try fixture.git.run(["ls-tree", "-r", branch], in: fixture.path).isEmpty)
        #expect(try fixture.git.run(["rev-list", "--count", branch], in: fixture.path) == "1")
        #expect(try fixture.controller.savedWorkspace().tasks.map(\.id) == [task.id])
    }

    @Test func anIdentityFailureKeepsTheDraftAndOffersAnExplicitRetry() async throws {
        let environment = HermeticGit.environment.filter { !$0.key.hasPrefix("GIT_AUTHOR_") && !$0.key.hasPrefix("GIT_COMMITTER_") }
        let git = GitRunner(environment: environment, ignoringInherited: { $0.hasPrefix("GIT_") })
        let fixture = try Fixture(git: git)
        defer { fixture.cleanUp() }
        let model = try await fixture.model()
        model.promptText = "Remember me"
        #expect(await model.create() == false)
        #expect(await model.recoverAndCreate() == false)
        #expect(model.error?.reason.contains("git config user.name") == true)
        #expect(model.error?.reason.contains("git config user.email") == true)
        #expect(model.error?.detail?.contains("identity") == true)
        #expect(model.error?.recovery == .initializeRepository(on: "main"))
        #expect(model.draft.title == "First task" && model.promptText == "Remember me")
        #expect(fixture.controller.state.tasks.isEmpty)
        #expect(try Repository(fixture.path, git: git).commit("HEAD") == nil)
        try git.run(["config", "user.name", "Test Person"], in: fixture.path)
        try git.run(["config", "user.email", "person@example.invalid"], in: fixture.path)
        #expect(await model.recoverAndCreate())
        #expect(fixture.controller.state.tasks.count == 1)
    }

    @Test func changingTheBaseDropsTheInitializationOffer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try await fixture.model()
        #expect(await model.create() == false)
        #expect(model.error?.recovery != nil)
        model.draft.baseBranch = "missing"
        #expect(model.error == nil)
        #expect(await model.recoverAndCreate() == false)
        #expect(await model.create() == false)
        #expect(model.error?.recovery == nil)
        #expect(model.error?.reason.lowercased().contains("invalid reference") == true)
        #expect(try Repository(fixture.path, git: fixture.git).commit("HEAD") == nil)
    }

    @Test func aLockedWorkspaceCannotInitializeFromAnOldOffer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try await fixture.model()
        #expect(await model.create() == false)
        try fixture.controller.breakSaving()
        #expect(await model.recoverAndCreate() == false)
        #expect(try Repository(fixture.path, git: fixture.git).commit("HEAD") == nil)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let path: String
        let git: GitRunner
        let controller: AppController
        let daemon = RecordingDaemon()

        init(branch: String = "main", git: GitRunner = .hermetic()) throws {
            root = URL(fileURLWithPath: try GitFixture.folder("unborn-flow-"))
            path = root.appendingPathComponent("repo").path
            self.git = git
            try git.run(["init", "-b", branch, path], in: "/")
            controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")),
                                       preferences: .scratch(), git: git)
            try controller.workspace.load()
            controller.helper.setDaemonClient(daemon)
        }

        func model() async throws -> TaskCreationModel {
            await controller.projects.addProject(path: path)
            let project = try #require(controller.state.projects.first)
            var draft = TaskDraft.initial(project: project, state: controller.state, git: git,
                                          home: ScratchHome.bare, defaults: ScratchDefaults.make())
            draft.setTitle("First task")
            let model = controller.sheets.makeCreationModel(project: project, draft: draft,
                                                           catalogue: ScratchHome.catalogue(.claude), jira: nil)
            await model.loadAgentCatalogue()
            #expect(model.agentIsReady)
            return model
        }

        func cleanUp() {
            controller.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
