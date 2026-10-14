import AppKit
import SwiftUI
import Testing
import Foundation
import AiTermUI
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
        model.draft.setBranch("feat/x")
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
        model.draft.setBranch("feat/x")
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
    /// the sheet stays up, nothing is announced, and the failure says where the branch as it was
    /// is kept.
    @Test func aCreateAfterTheFixThatFailsAgainShowsTheNewFailure() async throws {
        var landed = 0, kept = 0
        let model = ReviewCreationModelTests.makeModel(create: { _ in
            throw WorktreeError.rebaseConflicted("feat/x", detail: "CONFLICT")
        }, fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal)), fixLanded: { _, _ in landed += 1 },
           backupKept: { _ in kept += 1 })
        model.draft.setBranch("feat/x")
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
        let note = "The fix is in; your branch as it was is kept as aiterm/backup/feat/x."
        #expect(model.error?.afterFix == note)
        #expect(model.error?.fix?.reason?.contains("aiterm/backup") == false, "the next fix's problem is git's alone")
        let offered = "Rebasing “feat/x” onto origin’s hit a conflict, so it was left as it was. " + note
        #expect(FixFooterPresentation(error: model.error, state: second.state, fixer: .claude, lastProposal: nil).lead
                == .failure(offered, help: offered))
        let byHand = "Rebasing “feat/x” onto origin’s hit a conflict, so it was left as it was. Rebase it by hand. " + note
        #expect(FixFooterPresentation(error: model.error, state: nil, fixer: nil, lastProposal: nil).lead == .failure(byHand, help: byHand))
        #expect(kept == 0, "said in the failure, not a toast as well")
    }

    /// A landed fix whose create cannot start — the workspace locked meanwhile — lets its session
    /// go, so the footer is the sheet's again rather than a finished Apply that never ends.
    @Test func aCreateThatCannotStartAfterTheFixLetsTheSessionGo() async throws {
        var locked = false, kept: [FixLanding] = []
        let model = ReviewCreationModelTests.makeModel(create: { _ in throw WorktreeError.rebaseConflicted("feat/x", detail: nil) },
                                                       fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal)),
                                                       backupKept: { kept.append($0) }, canChangeWorkspace: { !locked })
        model.draft.setBranch("feat/x")
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        session.start(); await session.settled()
        locked = true
        model.applyFix(); await session.settled()
        #expect(session.state == .proposal(proposal), "no Apply while the create after it could not run")
        locked = false
        model.applyFix()
        locked = true   // locked while the fix lands
        await session.settled()
        #expect(model.fixSession == nil)
        #expect(!model.createdAfterFix)
        #expect(model.error == nil, "the failure the fix answered goes with it")
        #expect(kept.map(\.backup) == ["aiterm/backup/feat/x"], "the toast says where the branch as it was is kept")
    }

    /// A fix that lands once the draft has moved to another branch creates nothing — that create
    /// was for the old branch — and drops the old branch's failure; the toast names the backup.
    @Test func aFixThatLandsAfterTheBranchChangedCreatesNothingAndNamesTheBackup() async throws {
        var created = 0, kept: [FixLanding] = []
        let model = ReviewCreationModelTests.makeModel(create: { _ in
            created += 1
            throw WorktreeError.rebaseConflicted("feat/x", detail: nil)
        }, fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal)), backupKept: { kept.append($0) })
        model.draft.setBranch("feat/x")
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        session.start(); await session.settled()
        model.applyFix()
        model.draft.setBranch("feat/y")   // while it applies: the failure is held until it lands
        #expect(model.fixSession === session && model.error != nil)
        await session.settled()
        #expect(created == 1)
        #expect(model.fixSession == nil && model.error == nil)
        #expect(kept.map(\.backup) == ["aiterm/backup/feat/x"])
    }

    /// Going back and picking another branch drops the failure and its offer: both were about the
    /// branch the draft has left, and a Fix would land on it while the create ran for the new one.
    @Test func aNewBranchDropsTheFailureAndItsFix() async throws {
        let model = ReviewCreationModelTests.makeModel(create: { _ in throw WorktreeError.rebaseConflicted("feat/x", detail: nil) },
                                                       fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal)))
        model.draft.setBranch("feat/x")
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        session.start(); await session.settled()
        model.draft.setBranch("feat/y")
        #expect(model.fixSession == nil)
        #expect(model.error == nil)
        #expect(session.state == .offered, "the proposal left up was declined")
    }

    /// A proposal about another branch than the draft's is never applied, nor is its create run.
    @Test func applyRefusesAProposalForAnotherBranch() async throws {
        var created = 0
        let model = ReviewCreationModelTests.makeModel(create: { _ in
            created += 1
            throw WorktreeError.rebaseConflicted("feat/y", detail: nil)
        }, fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal)))
        model.draft.setBranch("feat/x")
        await model.loadAgentCatalogue()
        _ = await model.create()
        let session = try #require(model.fixSession)
        session.start(); await session.settled()
        model.applyFix(); await session.settled()
        #expect(session.state == .proposal(proposal))
        #expect(created == 1)
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
        model.draft.setBranch("feat/x")
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
        model.draft.setBranch("feat/x")
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

    /// A new failure replaces the offer — and a Look still running for the old one is stopped, not
    /// left working in a clone nobody shows.
    @Test func aNewFailureStopsTheLookItReplaces() async throws {
        let model = ReviewCreationModelTests.makeModel(create: { _ in throw WorktreeError.rebaseConflicted("feat/x", detail: nil) },
                                                       fixer: .ready(.claude), pipeline: .stub(look: .fix(proposal), slowLook: true))
        model.draft.setBranch("feat/x")
        await model.loadAgentCatalogue()
        _ = await model.create()
        let looking = try #require(model.fixSession)
        looking.start()
        _ = await model.create()
        #expect(model.fixSession !== looking)
        #expect(looking.state == .offered, "cancelled")
        await looking.settled()
    }
}

/// What New Review's footer draws for each of a Fix's states (design 1A–4A, footer states 1–9),
/// decided without rendering.
@MainActor struct FixFooterPresentationTests {
    let conflict = CreationFailure(WorktreeError.rebaseConflicted("feat/x", detail: "CONFLICT"), projectPath: "/tmp/p")
    let diverged = CreationFailure(WorktreeError.branchDiverged("feat/x", local: 2, remote: 4), projectPath: "/tmp/p")
    let proposal = FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil)
    let conflictSentence = "Rebasing “feat/x” onto origin’s hit a conflict, so it was left as it was."

    private func footer(_ failure: CreationFailure?, _ state: FixSession.State?, fixer: FixerAgent? = .claude,
                        last: FixProposal? = nil) -> FixFooterPresentation {
        FixFooterPresentation(error: failure, state: state, fixer: fixer, lastProposal: last)
    }

    /// States 1 and 2: offered beside Rebase, or alone with “Rebase it by hand.” gone.
    @Test func offeredFollowsTheRecoveryAndDropsByHand() {
        let alone = footer(conflict, .offered)
        #expect(alone.lead == .failure(conflictSentence, help: conflictSentence))
        #expect(alone.offer == .init(title: "Fix with Claude", isEnabled: true, retries: false,
                                     help: "Claude reads the problem and proposes a fix; nothing changes until you press Apply."))
        #expect(!alone.showsRecovery)
        #expect(alone.buttons == .sheet)

        let beside = footer(diverged, .offered, fixer: .codex)
        #expect(beside.showsRecovery)
        #expect(beside.offer?.title == "Fix with Codex")
        #expect(beside.lead == .failure(diverged.reason, help: diverged.reason))
    }

    /// State 3: the agent's line in the failure's place, Cancel, and the create held.
    @Test func lookingHoldsTheCreateBehindCancel() {
        let looking = footer(conflict, .looking)
        #expect(looking.lead == .busy("Claude is looking at the conflict…"))
        #expect(looking.offer == nil && !looking.showsRecovery)
        #expect(looking.buttons == .looking)
        #expect(footer(diverged, .looking, fixer: .codex).lead == .busy("Codex is looking at the branch…"))
    }

    /// States 4 and 5: the plan where the failure was, Apply in the primary's place; while it is
    /// applied the plan stays, Cancel is off and the sheet cannot close.
    @Test func aProposalTakesTheButtonsAndStaysWhileApplied() {
        let up = footer(diverged, .proposal(proposal))
        #expect(up.lead == .proposal(.claude, proposal))
        #expect(up.buttons == .proposal)
        #expect(up.offer == nil && !up.showsRecovery)

        let applying = footer(diverged, .applying, last: proposal)
        #expect(applying.lead == .proposal(.claude, proposal))
        #expect(applying.buttons == .applying)
        #expect(!applying.canClose)
        #expect(footer(diverged, .done(FixLanding(branch: "feat/x", old: "a", new: "b")), last: proposal).buttons == .applying,
                "landed, the create runs as part of the same press")
        #expect(up.canClose && footer(conflict, .looking).canClose)
    }

    /// State 7: the agent's reason, “Rebase it by hand.” back, the original buttons and no second offer.
    @Test func noFixPutsByHandBackAndOffersNothing() {
        let none = footer(conflict, .noFix("Claude found no fix it can stand behind: both rewrite it."))
        #expect(none.lead == .failure("Claude found no fix it can stand behind: both rewrite it. Rebase it by hand.",
                                      help: "Claude found no fix it can stand behind: both rewrite it. Rebase it by hand."))
        #expect(none.offer == nil)
        #expect(none.buttons == .sheet)
        #expect(footer(diverged, .noFix("No.")).showsRecovery, "Rebase is one of the original buttons")
    }

    /// State 8: the reason, and Try Again.
    @Test func aFailedFixOffersTryAgain() {
        let failed = footer(conflict, .failed("pnpm typecheck failed (status 2) after the fix, so nothing was changed."))
        #expect(failed.lead == .failure("pnpm typecheck failed (status 2) after the fix, so nothing was changed.",
                                        help: "pnpm typecheck failed (status 2) after the fix, so nothing was changed."))
        #expect(failed.offer == .init(title: "Try Again", isEnabled: true, retries: true,
                                      help: "Asks Claude for a new fix, told why this one failed."))
        #expect(failed.buttons == .sheet)
    }

    /// State 9: greyed with its reason; with Fix turned off, no button at all — and either way the
    /// sentence keeps “Rebase it by hand.”, as it does with no session.
    @Test func anAgentThatCannotRunIsGreyedOrAbsent() {
        let why = "Claude Code isn’t installed. Install it in Settings › Agents, or choose another agent there."
        let missing = footer(conflict, .unavailable(why))
        #expect(missing.offer == .init(title: "Fix with Claude", isEnabled: false, retries: false, help: why))
        #expect(missing.lead == .failure(conflictSentence + " Rebase it by hand.", help: conflictSentence + " Rebase it by hand."))
        let off = footer(conflict, .unavailable(""), fixer: nil)
        #expect(off.offer == nil)
        #expect(off.lead == missing.lead)
        #expect(footer(conflict, nil, fixer: nil).lead == missing.lead, "no pipeline, no offer")
    }

    /// A git failure keeps git's whole output as the tooltip; nothing failed, nothing drawn.
    @Test func aPlainFailureIsAsBefore() {
        let git = CreationFailure(GitError(args: ["worktree", "add"], code: 128, stderr: "fatal: nope"), projectPath: "/tmp/p")
        #expect(footer(git, nil).lead == .failure("Nope.", help: "git worktree add failed:\nfatal: nope"))
        #expect(footer(nil, nil).lead == nil)
        #expect(footer(nil, nil).buttons == .sheet)
    }
}

/// The footer's keys follow the Fix, driven through a hosted window as `SheetFooterTests` drives
/// the plain footer: ⌘↩ is Apply while a proposal is up, ⎋ stops a Look or declines a proposal,
/// and neither key does anything while a fix is applied — the sheet's Back included.
@MainActor
@Suite(.serialized) struct CreationFooterFixKeysTests {
    private final class Calls { var backs = 0, advances = 0, applies = 0 }

    private struct Harness {
        let calls: Calls
        let session: FixSession
        let host: NSHostingView<CreationFooter>
        let window: NSWindow
    }

    private func harness(_ state: FixSession.State) -> Harness {
        let calls = Calls()
        let failure = CreationFailure(WorktreeError.rebaseConflicted("feat/x", detail: nil), projectPath: "/tmp/p")
        let proposal = FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil)
        let session = FixSession.snapshot(state, fixer: .ready(.claude), request: failure.fix!, proposal: proposal)
        let footer = CreationFooter(step: 3, error: failure, availableAgents: [.claude], createLabel: "Create Review", creating: false,
                                    canAdvance: true, closeList: { false }, back: { calls.backs += 1 },
                                    advance: { calls.advances += 1 }, recover: {}, fix: session, applyFix: { calls.applies += 1 })
        let host = NSHostingView(rootView: footer)
        host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        settle(host)
        return Harness(calls: calls, session: session, host: host, window: window)
    }

    private func press(_ keyCode: UInt16, _ character: String, _ modifiers: NSEvent.ModifierFlags = [], in h: Harness) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: h.window.windowNumber, context: nil, characters: character,
                                     charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)!
        _ = h.window.performKeyEquivalent(with: event)
        settle(h.host)
    }

    @Test func commandReturnAppliesTheProposal() {
        let h = harness(.proposal(FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil)))
        defer { h.window.orderOut(nil) }
        press(36, "\r", [.command], in: h)
        #expect(h.calls.applies == 1 && h.calls.advances == 0, "⌘↩ is Apply, not the create")
    }

    @Test func escapeDeclinesTheProposalWithoutSteppingBack() {
        let h = harness(.proposal(FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil)))
        defer { h.window.orderOut(nil) }
        press(53, "\u{1b}", in: h)
        #expect(h.session.state == .offered)
        #expect(h.calls.backs == 0)
    }

    @Test func escapeStopsALook() {
        let h = harness(.looking)
        defer { h.window.orderOut(nil) }
        press(36, "\r", [.command], in: h)
        #expect(h.calls.advances == 0 && h.calls.applies == 0, "the create waits while the agent looks")
        press(53, "\u{1b}", in: h)
        #expect(h.session.state == .offered)
        #expect(h.calls.backs == 0)
    }

    @Test func neitherKeyDoesAnythingWhileApplying() {
        let h = harness(.applying)
        defer { h.window.orderOut(nil) }
        press(53, "\u{1b}", in: h)
        #expect(h.session.state == .applying)
        #expect(h.calls.backs == 0)
        press(36, "\r", [.command], in: h)
        #expect(h.calls.advances == 0 && h.calls.applies == 0, "neither the create nor a second Apply")
    }
}
