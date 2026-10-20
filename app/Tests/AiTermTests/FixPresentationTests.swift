import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// Find a Fix (spec §13, §14; Help with problems option A): what the banner and New Review's footer
/// offer and say, decided without rendering.
@MainActor struct FixPresentationTests {
    let conflict = OperationIssue.rebaseRefused(WorktreeError.rebaseConflicted("main", detail: "CONFLICT x"), in: UUID(), projectPath: "/p")
    let footerConflict = CreationFailure(WorktreeError.rebaseConflicted("feat/x", detail: "CONFLICT"), projectPath: "/tmp/p")
    let conflictSentence = "Rebasing “feat/x” onto origin’s hit a conflict, so it was left as it was."

    /// The offer says what you get without naming who; its busy line is the same everywhere.
    @Test func theOfferIsFindAFix() {
        let banner = BannerFixPresentation(issue: conflict, state: .offered, fixer: .claude)
        #expect(banner.links.map(\.title) == ["Find a Fix", "Dismiss"])
        #expect(BannerFixPresentation(issue: conflict, state: .looking, fixer: .claude).content == .busy("Looking for a fix…"))

        let footer = FixFooterPresentation(error: footerConflict, state: .offered, fixer: .claude, lastProposal: nil)
        #expect(footer.offer?.title == "Find a Fix")
        #expect(FixFooterPresentation(error: footerConflict, state: .looking, fixer: .claude, lastProposal: nil).lead
                == .busy("Looking for a fix…"))

        let request = FixRequest(title: "t", reason: nil, detail: nil, projectPath: "/p", branch: "feat/x", recreateRebase: true,
                                 retry: .createReview)
        #expect(FixSession.snapshot(nil, fixer: .ready(.claude), request: request).buttonTitle == "Find a Fix")
    }

    /// A fix that failed leaves the problem standing: its title stays, and the failure is its
    /// description — in the banner and in the footer alike.
    @Test func aFailedFixKeepsTheProblemsTitle() {
        let banner = BannerFixPresentation(issue: conflict, state: .failed("pnpm typecheck failed."), fixer: .claude)
        #expect(banner.content == .text("Couldn’t rebase the default branch.", detail: "pnpm typecheck failed.", help: "CONFLICT x"))

        let footer = FixFooterPresentation(error: footerConflict, state: .failed("pnpm typecheck failed."), fixer: .claude, lastProposal: nil)
        #expect(footer.lead == .failure(conflictSentence, description: "pnpm typecheck failed.", help: footerConflict.detail ?? conflictSentence))
        #expect(footer.offer?.title == "Try Again")

        // A footer failure with one sentence is the title alone.
        let plain = FixFooterPresentation(error: footerConflict, state: nil, fixer: nil, lastProposal: nil)
        #expect(plain.lead == .failure(conflictSentence + " Rebase it by hand.", description: nil,
                                       help: footerConflict.detail ?? conflictSentence + " Rebase it by hand."))
    }
}
