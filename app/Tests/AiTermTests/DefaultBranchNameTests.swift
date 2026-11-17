import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite(.blocking) struct DefaultBranchNameTests {
    @Test func loadingReadsEveryTimeAndAFailureLeavesTheLastNameStanding() async throws {
        let git = FlakyGitRunner()
        let fixture = try await RaceFixture(controllerGit: git)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let actions = fixture.controller.projects, project = fixture.project
        await actions.loadDefaultBranchName(of: project)
        #expect(actions.defaultBranchName(project.id) == "main")
        try fixture.git.run(["branch", "-m", "main", "master"], in: project.path)
        git.failing = true
        await actions.loadDefaultBranchName(of: project)
        #expect(actions.defaultBranchName(project.id) == "main")
        git.failing = false
        await actions.loadDefaultBranchName(of: project)
        #expect(actions.defaultBranchName(project.id) == "master")
    }

    @Test func aFirstFailedReadLeavesTheNameUnknown() async throws {
        let git = FlakyGitRunner()
        let fixture = try await RaceFixture(controllerGit: git)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        git.failing = true
        await fixture.controller.projects.loadDefaultBranchName(of: fixture.project)
        #expect(fixture.controller.projects.defaultBranchName(fixture.project.id) == nil)
    }

    @Test func anAnsweredReadWithoutANameUsesTheFallback() async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try fixture.git.run(["branch", "-m", "main", "topic"], in: fixture.project.path)
        await fixture.controller.projects.loadDefaultBranchName(of: fixture.project)
        #expect(fixture.controller.projects.defaultBranchName(fixture.project.id) == Repository.fallbackDefaultBranch)
    }

    @Test(arguments: [false, true]) func aFinishedGitOperationReadsTheNameAgain(rebase: Bool) async throws {
        let fixture = try await RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let actions = fixture.controller.projects, project = fixture.project
        await actions.loadDefaultBranchName(of: project)
        try fixture.git.run(["branch", "-m", "main", "master"], in: project.path)
        // No origin: even a refused pull or rebase refreshes the name.
        await (rebase ? actions.rebaseDefault(project: project) : actions.pullDefault(project: project))?.value
        #expect(actions.defaultBranchName(project.id) == "master")
    }

    @Test(arguments: [false, true]) func editingReadsItsBranchWhenAsked(failing: Bool) async throws {
        let git = FlakyGitRunner()
        let fixture = try await RaceFixture(controllerGit: git)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        try fixture.git.run(["branch", "-m", "main", "master"], in: fixture.project.path)
        let model = fixture.controller.projects.makeProjectSheet(ProjectPreparation(project: fixture.project), editing: true)
        #expect(model.preparation.defaultBranch == nil)
        git.failing = failing
        await model.loadDefaultBranchName()
        #expect(model.preparation.defaultBranch == (failing ? nil : "master"))
    }
}
