import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// New Review's Fix: which failures offer one, the session the model makes for it, Apply on ⌘↩
/// while a proposal is up, and the create run again once the fix has landed.
@MainActor struct ReviewFixTests {
    let project = Project(id: UUID(), name: "acme-web", path: "/tmp/p", provider: .gitlab,
                          remoteUrl: "git@git.example.net:web/acme-web.git", addedAt: Date(), collapsed: false)
    let proposal = FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil)

    @Test func aDivergedBranchOffersRebaseAndAFix() {
        let failure = CreationFailure(WorktreeError.branchDiverged("feat/x", local: 2, remote: 4), projectPath: "/tmp/p")
        #expect(failure.recovery == .rebase("feat/x"))
        #expect(failure.fix?.branch == "feat/x")
        #expect(failure.fix?.recreateRebase == false)
        #expect(failure.fix?.projectPath == "/tmp/p")
        #expect(failure.fix?.retry == .createReview)
        #expect(failure.byHand == nil, "its sentence never sent anyone to a terminal")
    }

    @Test func aConflictOffersTheFixAloneWithGitsWords() {
        let failure = CreationFailure(WorktreeError.rebaseConflicted("feat/x", detail: "CONFLICT (content): config.ts"), projectPath: "/tmp/p")
        #expect(failure.recovery == nil)
        #expect(failure.fix?.recreateRebase == true)
        #expect(failure.fix?.detail == "CONFLICT (content): config.ts")
        #expect(!failure.reason.contains("Rebase it by hand."), "the button is the way out now")
        #expect(failure.reason == "Rebasing “feat/x” onto origin’s hit a conflict, so it was left as it was.")
        #expect(failure.byHand == "Rebase it by hand.", "kept for when no fix can help")
    }

    @Test(arguments: [WorktreeError.branchNotOnOrigin("f"), .branchCheckedOut("f", at: "/x"),
                      .branchInProjectFolder("f", at: "/p", switchTo: "main", hasChanges: true)])
    func outOfScopeRefusalsOfferNoFix(_ error: WorktreeError) {
        #expect(CreationFailure(error, projectPath: "/tmp/p").fix == nil)
    }

    /// Ruling R2: `primaryAction()` is synchronous, so it is called without `await`.
    @Test func aFailureWithAFixGivesTheModelASessionAndApplyTakesCommandReturn() async throws {
        var created = 0
        let model = ReviewCreationModelTests.makeModel(create: { _ in
            created += 1
            if created == 1 { throw WorktreeError.rebaseConflicted("feat/x", detail: "CONFLICT") }
        }, fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal)))
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        #expect(model.primaryAction() == .advance, "offered: ⌘↩ is still the create")
        session.start(); await session.settled()
        #expect(session.state == .proposal(proposal))
        #expect(model.primaryAction() == .applyFix)
        model.applyFix(); await session.settled()
        #expect(created == 2, "the review is created again once the fix landed")
    }

    /// The sheet closes on a create the fix ran, as it does on its own, and the toast names the backup.
    @Test func aCreateAfterTheFixClosesTheSheetAndSaysWhereTheOldTipIs() async throws {
        var created = 0, landed: [(FixLanding, FixerAgent)] = []
        let model = ReviewCreationModelTests.makeModel(create: { _ in
            created += 1
            if created == 1 { throw WorktreeError.branchDiverged("feat/x", local: 2, remote: 4) }
        }, fixer: .ready(.codex), pipeline: .stub(look: .fix(proposal)), fixLanded: { landed.append(($0, $1)) })
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        #expect(!model.createdAfterFix)
        session.start(); await session.settled()
        model.applyFix(); await session.settled()
        #expect(model.createdAfterFix)
        #expect(model.error == nil)
        #expect(landed.map(\.0.backup) == ["aiterm/backup/feat/x"])
        #expect(landed.map(\.1) == [.codex])
    }

    /// A retried create that fails again shows its own failure, which may offer a Fix of its own;
    /// the sheet stays up and nothing is announced.
    @Test func aCreateAfterTheFixThatFailsAgainShowsTheNewFailure() async throws {
        var landed = 0
        let model = ReviewCreationModelTests.makeModel(create: { _ in
            throw WorktreeError.rebaseConflicted("feat/x", detail: "CONFLICT")
        }, fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal)), fixLanded: { _, _ in landed += 1 })
        await model.loadAgentCatalogue()
        _ = await model.create()
        let first = try #require(model.fixSession)
        first.start(); await first.settled()
        model.applyFix(); await first.settled()
        #expect(!model.createdAfterFix)
        #expect(landed == 0)
        #expect(model.error?.fix?.branch == "feat/x")
        let second = try #require(model.fixSession)
        #expect(second !== first)
        #expect(second.state == .offered, "a new offer for the new failure")
    }

    /// No pipeline — New Task, or a sheet built without one — and a failure with nothing to fix
    /// make no session.
    @Test func noPipelineOrNoFixMakesNoSession() async {
        let without = ReviewCreationModel(project: project, draft: ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil),
                                          home: ScratchHome.bare, catalogue: ScratchHome.catalogue, defaults: ScratchDefaults.make(),
                                          git: .hermetic(), searchMergeRequests: { _ in [] },
                                          createReview: { _ in throw WorktreeError.rebaseConflicted("feat/x", detail: nil) },
                                          recover: { _ in })
        await without.loadAgentCatalogue()
        _ = await without.create()
        #expect(without.error?.fix != nil)
        #expect(without.fixSession == nil)

        let unfixable = ReviewCreationModelTests.makeModel(create: { _ in throw WorktreeError.branchNotOnOrigin("feat/x") },
                                                           fixer: .ready(.claude))
        await unfixable.loadAgentCatalogue()
        _ = await unfixable.create()
        #expect(unfixable.fixSession == nil)
    }

    /// The session takes the fixer Settings names when the failure is shown: Off and a missing
    /// agent both make one that says so rather than none, so the footer can grey its button.
    @Test(arguments: [FixerResolution.off, .missing(.codex)])
    func aFixerThatCannotRunIsOfferedUnavailable(_ fixer: FixerResolution) async throws {
        let model = ReviewCreationModelTests.makeModel(create: { _ in throw WorktreeError.rebaseConflicted("feat/x", detail: nil) },
                                                       fixer: fixer)
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        guard case .unavailable = session.state else { Issue.record("expected unavailable, got \(session.state)"); return }
    }

    /// A create clears the failure and its offer with it — but never a session that is working:
    /// a Look in flight is the person's, and Cancel is its way out.
    @Test func aNewCreateDropsTheOfferButNotAWorkingSession() async throws {
        var created = 0
        let model = ReviewCreationModelTests.makeModel(create: { _ in
            created += 1
            if created == 1 { throw WorktreeError.rebaseConflicted("feat/x", detail: nil) }
        }, fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal), slowLook: true))
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        session.start()
        #expect(session.state == .looking)
        #expect(await model.create())
        #expect(model.fixSession === session, "a Look in flight is not dropped")
        session.cancel(); await session.settled()

        created = 0
        _ = await model.create()
        #expect(model.fixSession?.state == .offered)
        #expect(await model.create())
        #expect(model.fixSession == nil, "an offer goes with its failure")
    }
}
