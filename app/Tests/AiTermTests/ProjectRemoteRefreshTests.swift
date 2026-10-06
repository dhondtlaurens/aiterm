import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport
@testable import AiTerm

extension AppControllerTests {
    @Test func remoteAddedAfterTheProjectWasAddedUpdatesItsProviderAndIsPersisted() async throws {
        let fixture = try RemoteFixture(provider: .git, remoteUrl: nil)
        defer { fixture.cleanUp() }
        try fixture.git.run(["remote", "add", "origin", "git@gitlab.example.com:group/app.git"], in: fixture.repo.path)

        await fixture.controller.checkouts.refresh().value

        #expect(fixture.controller.state.projects.first?.provider == .gitlab)
        #expect(fixture.controller.state.projects.first?.remoteUrl == "git@gitlab.example.com:group/app.git")
        let saved = try fixture.controller.savedWorkspace().projects.first
        #expect(saved?.provider == .gitlab)
        #expect(saved?.remoteUrl == "git@gitlab.example.com:group/app.git")
    }

    /// An unreachable checkout — an unmounted volume, a folder being moved — is not evidence that
    /// the project stopped being a GitLab repository, so its badge and its remote are left alone.
    @Test func unreachableCheckoutKeepsTheProviderItWasAddedWith() async throws {
        let fixture = try RemoteFixture(provider: .gitlab, remoteUrl: "git@gitlab.example.com:group/app.git")
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.repo)

        await fixture.controller.checkouts.refresh().value

        #expect(fixture.controller.state.projects.first?.provider == .gitlab)
        #expect(fixture.controller.state.projects.first?.remoteUrl == "git@gitlab.example.com:group/app.git")
    }

    /// The refresh runs every two seconds; a pass that finds the same remote must not rewrite
    /// `state.json`.
    @Test func refreshDoesNotRewriteStateWhenTheRemoteIsUnchanged() async throws {
        let fixture = try RemoteFixture(provider: .git, remoteUrl: nil)
        defer { fixture.cleanUp() }
        try fixture.git.run(["remote", "add", "origin", "git@gitlab.example.com:group/app.git"], in: fixture.repo.path)
        await fixture.controller.checkouts.refresh().value
        try #require(fixture.controller.state.projects.first?.provider == .gitlab)
        #expect(fixture.controller.workspace.flush())
        let written = try fixture.stateModified()

        await fixture.controller.checkouts.refresh().value

        // A save the pass asked for would be written now rather than a moment later.
        #expect(fixture.controller.workspace.flush())
        #expect(try fixture.stateModified() == written)
    }
}

private struct RemoteFixture {
    let root: URL
    let repo: URL
    let git = GitRunner.hermetic()
    let controller: AppController
    private let stateURL: URL

    @MainActor
    init(provider: Provider, remoteUrl: String?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], in: repo.path)
        stateURL = root.appendingPathComponent("state.json")
        controller = AppController(store: StateStore(url: stateURL), preferences: .scratch())
        try controller.loadWorkspace()
        controller.workspace.mutate { $0.append(project: Project(id: UUID(), name: "Repo", path: repo.path, provider: provider,
                                                                  remoteUrl: remoteUrl, addedAt: Date(), collapsed: false)) }
        #expect(controller.workspace.flush())
    }

    func stateModified() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: stateURL.path)[.modificationDate] as? Date
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
