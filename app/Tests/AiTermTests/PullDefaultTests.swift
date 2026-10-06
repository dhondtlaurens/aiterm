import Foundation
import Observation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm

/// "Pull main" from a project's context menu: a toast says what it did, a banner why it could not.
extension AppControllerTests {
    @Test func pullDefaultSaysWhatItPulled() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let remote = fixture.root.appendingPathComponent("remote.git").path, other = fixture.root.appendingPathComponent("other").path
        try fixture.git.run(["init", "-q", "--bare", "-b", "main", remote], in: fixture.root.path)
        try fixture.git.run(["remote", "add", "origin", remote], in: fixture.repo.path)
        try fixture.git.run(["push", "-q", "origin", "main"], in: fixture.repo.path)
        try fixture.git.run(["clone", "-q", remote, other], in: fixture.root.path)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "upstream"], in: other)
        try fixture.git.run(["push", "-q", "origin", "main"], in: other)

        let pull = fixture.controller.pullDefault(project: fixture.project)
        #expect(fixture.controller.changingDefaultBranch == [fixture.project.id])
        #expect(fixture.controller.pullDefault(project: fixture.project) == nil, "one pull at a time")
        await pull?.value

        #expect(fixture.controller.toastState.toast?.message == "main updated with 1 new commit.")
        #expect(fixture.controller.changingDefaultBranch.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(try fixture.git.run(["rev-parse", "main"], in: fixture.repo.path) == fixture.git.run(["rev-parse", "main"], in: other))
    }

    /// The project's Pull item greys while its pull runs: its own row hears of it, and no other.
    @Test func aPullGreysItsOwnProjectsPullAlone() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller, other = UUID()
        let ownHeard = Mutex(false), otherHeard = Mutex(false)
        withObservationTracking { _ = controller.isChangingDefaultBranch(fixture.project.id) } onChange: { ownHeard.withLock { $0 = true } }
        withObservationTracking { _ = controller.isChangingDefaultBranch(other) } onChange: { otherHeard.withLock { $0 = true } }

        let pull = controller.pullDefault(project: fixture.project)
        #expect(controller.isChangingDefaultBranch(fixture.project.id))
        #expect(ownHeard.withLock { $0 })
        #expect(!controller.isChangingDefaultBranch(other))
        #expect(!otherHeard.withLock { $0 })
        await pull?.value
        #expect(!controller.isChangingDefaultBranch(fixture.project.id))
    }

    @Test func pullDefaultReportsWhyItCouldNot() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        await fixture.controller.pullDefault(project: fixture.project)?.value

        #expect(fixture.controller.issue == OperationIssue(title: "Couldn’t pull the default branch.",
                                                           reason: "This project has no origin to pull from."))
        #expect(fixture.controller.toastState.toast == nil)
        #expect(fixture.controller.changingDefaultBranch.isEmpty)
    }

    /// Diverged, the banner says by how much and offers the rebase; the rebase says what it left.
    @Test func pullDefaultOffersToRebaseADivergedBranch() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let remote = fixture.root.appendingPathComponent("remote.git").path, other = fixture.root.appendingPathComponent("other").path
        let repo = fixture.repo.path
        try fixture.git.run(["init", "-q", "--bare", "-b", "main", remote], in: fixture.root.path)
        try fixture.git.run(["remote", "add", "origin", remote], in: repo)
        try fixture.git.run(["push", "-q", "origin", "main"], in: repo)
        try fixture.git.run(["clone", "-q", remote, other], in: fixture.root.path)
        for (dir, message) in [(other, "upstream"), (repo, "local")] {
            try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message], in: dir)
        }
        try fixture.git.run(["push", "-q", "origin", "main"], in: other)
        try fixture.git.run(["config", "user.name", "t"], in: repo)
        try fixture.git.run(["config", "user.email", "t@t"], in: repo)

        await fixture.controller.pullDefault(project: fixture.project)?.value
        #expect(fixture.controller.issue == OperationIssue(
            title: "Couldn’t pull the default branch.",
            reason: "Your local “main” has 1 commit that isn’t on origin, and origin has 1 commit it doesn’t. "
                + "Rebase puts yours on top of origin’s; nothing is pushed.",
            actions: [.rebaseDefault(fixture.project.id)]))
        #expect(OperationIssue.Action.rebaseDefault(fixture.project.id).title == "Rebase")

        let rebase = fixture.controller.perform(.rebaseDefault(fixture.project.id))
        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.changingDefaultBranch == [fixture.project.id], "the menu's Pull main waits for it")
        await rebase?.value

        #expect(fixture.controller.toastState.toast?.message == "main rebased onto origin: 1 commit ahead, not pushed.")
        #expect(fixture.controller.changingDefaultBranch.isEmpty)
        #expect(try fixture.git.run(["rev-parse", "main~1"], in: repo) == fixture.git.run(["rev-parse", "main"], in: other))
    }

    /// The banner's Rebase while a pull of the same branch runs does nothing, and the banner stays.
    @Test func rebaseWaitsForAPullInFlight() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let banner = OperationIssue(title: "Couldn’t pull the default branch.", actions: [.rebaseDefault(fixture.project.id)])
        fixture.controller.report(banner)

        let pull = fixture.controller.pullDefault(project: fixture.project)
        #expect(fixture.controller.perform(.rebaseDefault(fixture.project.id)) == nil)
        #expect(fixture.controller.issue == banner)
        await pull?.value
    }

    /// A rebase that hits a conflict aborts, and the banner says it was left as it was.
    @Test func aRebaseThatConflictsSaysSo() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let remote = fixture.root.appendingPathComponent("remote.git").path, other = fixture.root.appendingPathComponent("other").path
        let repo = fixture.repo.path
        try fixture.git.run(["init", "-q", "--bare", "-b", "main", remote], in: fixture.root.path)
        try fixture.git.run(["remote", "add", "origin", remote], in: repo)
        try fixture.git.run(["push", "-q", "origin", "main"], in: repo)
        try fixture.git.run(["clone", "-q", remote, other], in: fixture.root.path)
        for (dir, text) in [(other, "upstream\n"), (repo, "local\n")] {
            try text.write(toFile: dir + "/same.txt", atomically: true, encoding: .utf8)
            try fixture.git.run(["add", "same.txt"], in: dir)
            try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", text], in: dir)
        }
        try fixture.git.run(["push", "-q", "origin", "main"], in: other)
        try fixture.git.run(["config", "user.name", "t"], in: repo)
        try fixture.git.run(["config", "user.email", "t@t"], in: repo)
        await fixture.controller.pullDefault(project: fixture.project)?.value
        try #require(fixture.controller.issue?.actions == [.rebaseDefault(fixture.project.id)])

        await fixture.controller.perform(.rebaseDefault(fixture.project.id))?.value

        #expect(fixture.controller.issue == OperationIssue(
            title: "Couldn’t rebase the default branch.",
            reason: "Rebasing “main” onto origin’s hit a conflict, so it was left as it was. Rebase it by hand."))
        #expect(fixture.controller.changingDefaultBranch.isEmpty)
    }

    /// A project removed while its pull runs gets neither a toast nor a banner.
    @Test func aPullOnAProjectRemovedMeanwhileSaysNothing() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Remove"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }

        let pull = fixture.controller.pullDefault(project: fixture.project)
        fixture.controller.confirmRemove(project: fixture.project)
        await pull?.value

        #expect(fixture.controller.state.projects.isEmpty)
        #expect(fixture.controller.issue == nil)
        #expect(fixture.controller.toastState.toast == nil)
    }
}
