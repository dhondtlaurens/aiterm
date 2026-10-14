import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The banner's rules on their own, without a controller: which report wins it, what waits behind
/// a question, and what goes with a row that has gone.
@MainActor
struct NoticesTests {
    /// The rows the notices are asked about: `gone` holds the subjects that no longer exist.
    private final class Rows {
        var gone = Set<UUID>()
        var withdrawn: [UUID] = []
    }

    private func notices(_ rows: Rows, toastLifetime: Duration = .seconds(10)) -> Notices {
        let notices = Notices(toastLifetime: toastLifetime, isStale: { issue in issue.subject.map(rows.gone.contains) ?? false })
        notices.onWithdrawn { rows.withdrawn.append($0) }
        return notices
    }

    private let task = UUID(), other = UUID()
    private var question: OperationIssue {
        OperationIssue(title: "Branch kept.", actions: [.keepBranch(task), .deleteBranch(task)], subject: task)
    }

    /// The newest report takes the banner, and the one it replaces about another task is withdrawn.
    @Test func aNewReportReplacesTheBannerAndWithdrawsTheOld() {
        let rows = Rows(), notices = notices(rows)
        notices.report(OperationIssue(title: "First", subject: task))
        notices.report(OperationIssue(title: "Second", subject: other))
        #expect(notices.issue?.title == "Second")
        #expect(rows.withdrawn == [task])
        notices.report(OperationIssue(title: "Again", subject: other))
        #expect(rows.withdrawn == [task], "the same task's own report does not withdraw it")
    }

    /// A report with nothing to offer waits behind a question, and takes the banner once the
    /// question is answered; one about a row that went meanwhile does not.
    @Test func aPlainReportWaitsBehindAQuestion() {
        let rows = Rows(), notices = notices(rows)
        notices.report(question)
        notices.report("The helper restarted.")
        #expect(notices.issue == question)

        notices.clearIssue()
        #expect(notices.issue?.title == "The helper restarted.")

        notices.report(question)
        notices.report(OperationIssue(title: "About the other task", subject: other))
        rows.gone.insert(other)
        notices.clearIssue()
        #expect(notices.issue == nil)
    }

    /// Another question does not wait: it takes the banner.
    @Test func aQuestionReplacesAQuestion() {
        let rows = Rows(), notices = notices(rows)
        notices.report(question)
        let rebase = OperationIssue(title: "Diverged.", actions: [.rebaseDefault(other)])
        notices.report(rebase)
        #expect(notices.issue == rebase)
    }

    /// Dismissing withdraws the banner's task and puts up what waited behind it.
    @Test func dismissingWithdrawsAndPromotesTheHeldReport() {
        let rows = Rows(), notices = notices(rows)
        notices.report(question)
        notices.report("Held")
        notices.dismissIssue()
        #expect(rows.withdrawn == [task])
        #expect(notices.issue?.title == "Held")
    }

    /// A report about a row that has already gone is never shown.
    @Test func aStaleReportIsNotShown() {
        let rows = Rows(), notices = notices(rows)
        rows.gone.insert(task)
        notices.report(OperationIssue(title: "Too late", subject: task))
        #expect(notices.issue == nil)
    }

    /// Once a row goes, the banner about it and what waits behind it about it go too; the rest stays.
    @Test func dropStaleTakesDownWhatNamesAGoneRow() {
        let rows = Rows(), notices = notices(rows)
        notices.report(question)
        notices.report(OperationIssue(title: "About the other task", subject: other))
        rows.gone.insert(other)
        notices.dropStale()
        #expect(notices.issue == question, "the question about a task still there stays")
        notices.clearIssue()
        #expect(notices.issue == nil, "what was held about the gone task went")

        notices.report(question)
        rows.gone.insert(task)
        notices.dropStale()
        #expect(notices.issue == nil)
    }

    /// Work that did what the banner asked drops whatever is about its task, held or shown, and
    /// the held one does not take the banner on the way.
    @Test func dropIssuesClearsWhatIsAboutTheTask() {
        let rows = Rows(), notices = notices(rows)
        notices.report(question)
        notices.report(OperationIssue(title: "Couldn’t reopen.", subject: task))
        notices.dropIssues(about: task)
        #expect(notices.issue == nil)
        #expect(rows.withdrawn.isEmpty, "answered, not withdrawn")
    }

    // -- the Fix an issue offers ------------------------------------------------------------

    private let proposal = FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["main"], drops: [], verify: nil)

    /// Notices whose fixes are made by `make`, and the sessions made so far.
    private final class Made { var sessions: [FixSession] = [] }
    private func fixing(_ made: Made, _ make: @escaping @MainActor (FixRequest) -> FixSession) -> Notices {
        Notices(toastLifetime: .seconds(10), isStale: { _ in false }, makeFix: { request in
            let session = make(request)
            made.sessions.append(session)
            return session
        })
    }

    @Test func aNewIssueWaitsWhileAFixIsBusy() async {
        let notices = Notices(toastLifetime: .seconds(10), isStale: { _ in false },
                              makeFix: { FixSession(request: $0, fixer: .ready(.claude), pipeline: .stub(look: .none("n"), slowLook: true), retry: { _ in }) })
        notices.report(OperationIssue(title: "Couldn’t pull.", fix: FixRequest.sample))
        notices.fixSession?.start()
        notices.report(OperationIssue(title: "Something else"))
        #expect(notices.issue?.title == "Couldn’t pull.", "held while the fix looks")
        notices.fixSession?.cancel(); await notices.fixSession?.settled()
        notices.fixEnded()
        #expect(notices.issue?.title == "Something else")
    }

    /// An issue with a problem to fix gets a session; one without, none; and the next issue's
    /// replaces the last's while it is only offered.
    @Test func anIssueWithAFixGetsASessionOfItsOwn() {
        let made = Made()
        let notices = fixing(made) { FixSession(request: $0, fixer: .ready(.claude), pipeline: .stub(look: .none("n")), retry: { _ in }) }
        notices.report(OperationIssue(title: "Plain"))
        #expect(notices.fixSession == nil && made.sessions.isEmpty)
        notices.report(OperationIssue(title: "Couldn’t pull.", fix: .sample))
        let first = notices.fixSession
        #expect(first != nil && first?.state == .offered)
        notices.report(OperationIssue(title: "Couldn’t pull again.", fix: .sample))
        #expect(notices.fixSession !== first && notices.fixSession != nil)
        notices.report(OperationIssue(title: "Plain"))
        #expect(notices.fixSession == nil)
    }

    /// A proposal waiting on Apply holds the banner as a Look does; Cancel declines it and puts up
    /// what waited.
    @Test func aProposalHoldsTheBannerUntilItIsCancelled() async {
        let notices = fixing(Made()) { FixSession(request: $0, fixer: .ready(.claude), pipeline: .stub(look: .fix(self.proposal)), retry: { _ in }) }
        notices.report(OperationIssue(title: "Couldn’t pull.", fix: .sample))
        let session = notices.fixSession
        session?.start(); await session?.settled()
        #expect(session?.state == .proposal(proposal))
        notices.report(OperationIssue(title: "Something else"))
        #expect(notices.issue?.title == "Couldn’t pull.")
        notices.cancelFix()
        #expect(session?.state == .offered, "declined")
        #expect(notices.issue?.title == "Something else")
        #expect(notices.fixSession == nil)
        await session?.settled()
    }

    /// Dismissed while it looks, the banner stops the Look: it would otherwise run on for minutes
    /// in a clone nobody shows.
    @Test func dismissingStopsTheLook() async {
        let notices = fixing(Made()) {
            FixSession(request: $0, fixer: .ready(.claude), pipeline: .stub(look: .none("n"), slowLook: true), retry: { _ in })
        }
        notices.report(OperationIssue(title: "Couldn’t pull.", fix: .sample))
        let session = notices.fixSession
        session?.start()
        #expect(session?.state == .looking)
        notices.dismissIssue()
        #expect(session?.state == .offered, "cancelled")
        #expect(notices.issue == nil && notices.fixSession == nil)
        await session?.settled()
    }

    /// While a fix is applied the banner holds: it cannot be dismissed, and a new issue waits.
    @Test func whileAFixIsAppliedTheBannerCannotBeDismissedOrReplaced() {
        let notices = fixing(Made()) { FixSession.snapshot(.applying, fixer: .ready(.claude), request: $0) }
        let pull = OperationIssue(title: "Couldn’t pull.", fix: .sample)
        notices.report(pull)
        notices.dismissIssue()
        #expect(notices.issue == pull)
        notices.report(OperationIssue(title: "Something else", actions: [.rebaseDefault(other)]))
        #expect(notices.issue == pull, "even a question waits")
        notices.cancelFix()
        #expect(notices.issue == pull && notices.fixSession?.state == .applying, "Cancel does nothing while applying")
    }

    /// Once the fix has ended without a fix — no fix, or failed — the banner is the person's
    /// again: Dismiss takes it down and puts up what waited.
    @Test func anEndedFixLetsTheBannerGo() {
        let notices = fixing(Made()) { FixSession.snapshot(.noFix("Claude found no fix."), fixer: .ready(.claude), request: $0) }
        notices.report(OperationIssue(title: "Couldn’t pull.", fix: .sample))
        notices.report(OperationIssue(title: "Something else"))
        #expect(notices.issue?.title == "Something else", "an ended fix holds nothing")
    }

    /// Taking the banner down — an action that answered it, or its project gone — lets its fix go.
    @Test func clearingTheIssueLetsALookGo() async {
        let notices = fixing(Made()) {
            FixSession(request: $0, fixer: .ready(.claude), pipeline: .stub(look: .none("n"), slowLook: true), retry: { _ in })
        }
        notices.report(OperationIssue(title: "Couldn’t pull.", fix: .sample))
        let session = notices.fixSession
        session?.start()
        notices.clearIssue()
        #expect(session?.state == .offered && notices.fixSession == nil)
        await session?.settled()
    }

    /// The toast goes on its own once its time is up.
    @Test func theToastGoesOnItsOwn() async {
        let notices = notices(Rows(), toastLifetime: .milliseconds(20))
        notices.showToast("Task removed.")
        #expect(notices.toastState.toast?.message == "Task removed.")
        await eventually(describing: "the toast to go") { notices.toastState.toast == nil }
    }
}
