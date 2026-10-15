import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The banner's Fix for Pull main: what it draws in each of a session's states (banner states 1–5
/// of the picked design), decided without rendering, and the whole run through a controller — a
/// pull refused, the Fix offered, its proposal applied, and the pull run again.
@MainActor @Suite(.serialized) struct BannerFixTests {
    let project = UUID()
    let proposal = FixProposal(headline: "Rebase main, keeping both new scripts.", why: "w", steps: ["s"], moves: ["main"],
                               drops: [], verify: nil)
    var conflict: OperationIssue {
        OperationIssue.rebaseRefused(WorktreeError.rebaseConflicted("main", detail: "CONFLICT x"), in: project, projectPath: "/p")
    }
    var diverged: OperationIssue {
        OperationIssue.pullRefused(WorktreeError.branchDiverged("main", local: 1, remote: 3), in: project, projectPath: "/p")
    }

    private func shown(_ issue: OperationIssue, _ state: FixSession.State?, fixer: FixerAgent? = .claude) -> BannerFixPresentation {
        BannerFixPresentation(issue: issue, state: state, fixer: fixer)
    }

    // -- what the banner draws ----------------------------------------------------------------

    /// 1 · offered: after the issue's own actions, before Dismiss; git's words in the tooltip.
    @Test func offeredFollowsTheIssuesOwnActions() {
        let alone = shown(conflict, .offered)
        #expect(alone.content == .text("Couldn’t rebase the default branch.",
                                       detail: "Rebasing “main” onto origin’s hit a conflict, so it was left as it was.", help: "CONFLICT x"))
        #expect(alone.links.map(\.title) == ["Fix with Claude", "Dismiss"])
        let beside = shown(diverged, .offered, fixer: .codex)
        #expect(beside.links.map(\.title) == ["Rebase", "Fix with Codex", "Dismiss"])
        #expect(beside.links[0] == .action(.rebaseDefault(project)))
    }

    /// 2 · looking: the agent's line names the issue; Cancel puts the issue back.
    @Test func lookingNamesTheIssue() {
        let looking = shown(conflict, .looking)
        #expect(looking.content == .busy("Claude is looking at “Couldn’t rebase the default branch”…"))
        #expect(looking.links == [.cancel(isEnabled: true)])
        #expect(!looking.canDismiss)
    }

    /// 3 · proposal: Apply and Cancel take the issue's links' place.
    @Test func aProposalOffersApplyAndCancel() {
        let shown = shown(diverged, .proposal(proposal))
        #expect(shown.content == .proposal(.claude, proposal))
        #expect(shown.links.map(\.title) == ["Apply", "Cancel"])
        #expect(shown.links[0] == .apply(help: "Applies Claude’s fix, then pulls main again."))
    }

    /// 4 · applying: the line, and Cancel greyed — a half-made fix is not left behind. The moment
    /// between landing and the pull is drawn the same, so the old issue does not flash back.
    @Test(arguments: [FixSession.State.applying, .done(FixLanding(branch: "main", old: "a", new: "b"))])
    func applyingGreysCancel(_ state: FixSession.State) {
        let applying = shown(conflict, state)
        #expect(applying.content == .busy("Applying Claude’s fix…"))
        #expect(applying.links == [.cancel(isEnabled: false)])
        #expect(!applying.canDismiss)
    }

    /// 5 · no fix: the agent's reason is the detail, “Rebase it by hand.” back, the issue's own
    /// actions back and no second offer.
    @Test func noFixPutsTheByHandSentenceBack() {
        let none = shown(conflict, .noFix("Claude found no fix it can stand behind: both change the version."))
        #expect(none.content == .text("Couldn’t rebase the default branch.",
                                      detail: "Claude found no fix it can stand behind: both change the version. Rebase it by hand.",
                                      help: "CONFLICT x"))
        #expect(none.links == [.dismiss])
        #expect(shown(diverged, .noFix("No.")).links.map(\.title) == ["Rebase", "Dismiss"])
    }

    /// The fix failed: why, and Try Again before Dismiss.
    @Test func aFailedFixOffersTryAgain() {
        let failed = shown(conflict, .failed("pnpm typecheck failed."))
        #expect(failed.content == .text("Couldn’t rebase the default branch.", detail: "pnpm typecheck failed.", help: "CONFLICT x"))
        #expect(failed.links.map(\.title) == ["Try Again", "Dismiss"])
    }

    /// The agent missing greys the offer, saying why; Off offers nothing. Either way “Rebase it by
    /// hand.” is back, since no fix can help.
    @Test func anAgentThatCannotRunGreysOrDropsTheOffer() {
        let missing = shown(conflict, .unavailable("Claude Code isn’t installed."))
        #expect(missing.links == [.fix(title: "Fix with Claude", isEnabled: false, help: "Claude Code isn’t installed."), .dismiss])
        #expect(missing.content == .text("Couldn’t rebase the default branch.",
                                         detail: "Rebasing “main” onto origin’s hit a conflict, so it was left as it was. Rebase it by hand.",
                                         help: "CONFLICT x"))
        let off = shown(conflict, .unavailable(""), fixer: nil)
        #expect(off.links == [.dismiss])
        #expect(shown(conflict, nil, fixer: nil) == off, "no session reads as Off")
    }

    /// An issue with nothing to fix draws as it always has.
    @Test func anIssueWithoutAFixIsUnchanged() {
        let plain = OperationIssue(title: "Couldn’t pull the default branch.", reason: "Unable to access 'origin'.")
        #expect(shown(plain, nil, fixer: nil).content == .text(plain.title, detail: plain.reason, help: nil))
        #expect(shown(plain, nil, fixer: nil).links == [.dismiss])
    }

    // -- the run, through a controller ----------------------------------------------------------

    /// A diverged pull offers the Fix; its proposal applied, the banner goes and the pull runs
    /// again — still diverged here, since the stub's fix moves nothing, so the new failure names
    /// where the branch as it was is kept.
    @Test func aFixThatLandsPullsAgainAndAFailedPullNamesTheBackup() async throws {
        let fixture = try divergedFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.fixPipeline = { _ in .stub(look: .fix(proposal)) }

        await controller.pullDefault(project: fixture.project)?.value
        let session = try #require(controller.notices.fixSession)
        #expect(session.state == .offered)
        #expect(controller.issue?.fix?.retry == .pullDefault(fixture.project.id))

        session.start(); await session.settled()
        #expect(session.state == .proposal(proposal))
        session.apply(); await session.settled()
        await eventually(describing: "the pull to run again") { !controller.isChangingDefaultBranch(fixture.project.id) && controller.issue != nil }

        #expect(controller.notices.fixSession !== session)
        #expect(controller.issue?.reason?.hasSuffix(" The fix is in; your branch as it was is kept as aiterm/backup/main.") == true)
        #expect(controller.issue?.fix?.reason?.contains("aiterm/backup") == false, "the next fix's problem is git's alone")
    }

    /// A pull that succeeds after the fix says so, and where the old commits are.
    @Test func aPullAfterTheFixSaysWhereTheOldCommitsAre() async throws {
        let fixture = try divergedFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.fixPipeline = { _ in .stub(look: .fix(proposal)) }
        await controller.pullDefault(project: fixture.project)?.value
        let session = try #require(controller.notices.fixSession)
        session.start(); await session.settled()
        // What the fix would have done: main now on origin's.
        try fixture.git.run(["fetch", "-q", "origin"], in: fixture.repo.path)
        try fixture.git.run(["reset", "-q", "--hard", "origin/main"], in: fixture.repo.path)

        session.apply(); await session.settled()
        await eventually(describing: "the pull's toast") { controller.toastState.toast?.message.hasPrefix("main is") == true }

        #expect(controller.toastState.toast?.message
                == "main is already up to date. Claude’s fix is in; your branch as it was is kept as aiterm/backup/main.")
        #expect(controller.issue == nil)
        #expect(controller.notices.fixSession == nil)
    }

    /// A pull after a fix that cannot start — another pull of the branch is running — still says
    /// where the branch as it was is kept.
    @Test func aPullAfterTheFixThatCannotStartNamesTheBackup() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let running = fixture.controller.pullDefault(project: fixture.project)
        let landing = FixLanding(branch: "main", old: "a", new: "b")

        #expect(fixture.controller.projects.pullDefault(project: fixture.project, after: (landing, .claude)) == nil)
        #expect(fixture.controller.toastState.toast?.message == "The fix is in; your branch as it was is kept as aiterm/backup/main.")
        await running?.value
    }

    /// The banner's session takes the fixer Settings names: Off makes one that offers nothing.
    @Test func theBannersSessionTakesTheFixerSettingsNames() async throws {
        let fixture = try divergedFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.agents.fixerChoice = .off()
        await fixture.controller.pullDefault(project: fixture.project)?.value
        #expect(fixture.controller.notices.fixSession?.state == .unavailable(""))
    }

    /// A fix that landed on a branch that is no longer the project's default pulls nothing — that
    /// pull was for the old one — and the toast says where the branch as it was is kept.
    @Test func aFixForABranchNoLongerTheDefaultPullsNothing() async throws {
        let fixture = try divergedFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        var pipeline = FixPipeline.stub(look: .fix(proposal))
        pipeline.land = { _, _ in FixLanding(branch: "release", old: "a", new: "b") }
        controller.fixPipeline = { [pipeline] _ in pipeline }
        await controller.pullDefault(project: fixture.project)?.value
        let session = try #require(controller.notices.fixSession)
        session.start(); await session.settled()
        session.apply(); await session.settled()

        #expect(controller.toastState.toast?.message == "The fix is in; your branch as it was is kept as aiterm/backup/release.")
        #expect(!controller.isChangingDefaultBranch(fixture.project.id), "no pull")
        #expect(controller.issue == nil, "a pull would have found main diverged again")
    }

    /// Two projects: while A's fix holds the banner, B's refusal waits; once A's fix lands it comes
    /// up with a Fix of its own, and A's pull, run again, leaves it be.
    @Test func anotherProjectsIssueWaitsForTheFixAndIsLeftAlone() async throws {
        let fixture = try divergedFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.fixPipeline = { _ in .stub(look: .fix(proposal)) }
        let other = Project(id: UUID(), name: "Other", path: fixture.root.appendingPathComponent("other").path, provider: .git,
                            remoteUrl: nil, addedAt: Date(), collapsed: false)
        controller.workspace.mutate { $0.append(project: other) }
        await controller.pullDefault(project: fixture.project)?.value
        let session = try #require(controller.notices.fixSession)
        session.start(); await session.settled()

        let otherIssue = OperationIssue.pullRefused(WorktreeError.branchDiverged("main", local: 1, remote: 2), in: other.id,
                                                    projectPath: other.path)
        controller.report(otherIssue)
        #expect(controller.issue?.fix?.retry == .pullDefault(fixture.project.id), "held while the proposal is up")

        // What the fix would have done: A's main on origin's, so its pull succeeds.
        try fixture.git.run(["fetch", "-q", "origin"], in: fixture.repo.path)
        try fixture.git.run(["reset", "-q", "--hard", "origin/main"], in: fixture.repo.path)
        session.apply(); await session.settled()
        await eventually(describing: "A's pull to end") { !controller.isChangingDefaultBranch(fixture.project.id) }

        #expect(controller.toastState.toast?.message == "main is already up to date. Claude’s fix is in; your branch as it was is kept as aiterm/backup/main.")
        #expect(controller.issue == otherIssue)
        let othersFix = try #require(controller.notices.fixSession)
        #expect(othersFix !== session && othersFix.state == .offered)
        #expect(othersFix.request.retry == .pullDefault(other.id))
    }

    /// Quitting stops a Look: its agent's process group would outlive the app.
    @Test func shutdownStopsALook() async throws {
        let fixture = try divergedFixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.fixPipeline = { _ in .stub(look: .none("n"), slowLook: true) }
        await controller.pullDefault(project: fixture.project)?.value
        let session = try #require(controller.notices.fixSession)
        session.start()
        await session.waitForClone()
        let clone = try #require(session.clonePath)

        let started = ContinuousClock.now
        controller.shutdown()
        await session.settled()
        #expect(ContinuousClock.now - started < .seconds(10), "not the stub's 30 s Look")
        #expect(!FileManager.default.fileExists(atPath: clone))
    }

    /// A repository whose `main` has one commit origin lacks while origin has one it lacks.
    private func divergedFixture() throws -> RaceFixture {
        let fixture = try RaceFixture()
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
        return fixture
    }
}
