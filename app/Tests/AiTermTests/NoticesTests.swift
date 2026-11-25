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
        let notices = Notices(toastLifetime: toastLifetime, isStale: { issue in
            (issue.subject ?? issue.signal).map(rows.gone.contains) ?? false
        })
        notices.onWithdrawn { rows.withdrawn.append($0) }
        return notices
    }

    private let task = UUID(), other = UUID(), project = UUID()
    private var question: OperationIssue {
        OperationIssue(title: "Couldn’t pull the default branch.", actions: [.rebaseDefault(project)], subject: task)
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

    /// A failing source's banner, as the controller raises it: Open Signals and Settings….
    private func sourceFails(_ signal: UUID, _ name: String = "Reviews for me") -> OperationIssue {
        .signalRead(signal: signal, name: name, source: "GitLab", reason: "Timed out.", retry: "AiTerm tries again at 14:05.")
    }

    /// A background report waits behind a question though it has actions, and takes the banner once the question is
    /// answered; with no question up it shows at once, over a plain report.
    @Test func aBackgroundReportWaitsBehindAQuestion() {
        let rows = Rows(), notices = notices(rows), signal = UUID()
        notices.report(question)
        notices.report(sourceFails(signal), background: true)
        #expect(notices.issue == question)
        notices.clearIssue()
        #expect(notices.issue == sourceFails(signal))

        notices.report("The helper restarted.")
        notices.report(sourceFails(signal), background: true)
        #expect(notices.issue == sourceFails(signal), "a plain report is no question")
    }

    /// The newest failing source wins the one place, shown or held; a question or a plain report that takes a source's
    /// place puts it back behind, so it returns once the banner is free; a dismissed one does not return.
    @Test func theNewestSourceWinsAndOneDisplacedComesBack() {
        let rows = Rows(), notices = notices(rows), first = UUID(), second = UUID()
        notices.report(sourceFails(first), background: true)
        notices.report(sourceFails(second, "Tickets for me"), background: true)
        #expect(notices.issue == sourceFails(second, "Tickets for me"))
        notices.report(question)
        #expect(notices.issue == question)
        notices.clearIssue()
        #expect(notices.issue == sourceFails(second, "Tickets for me"), "the displaced source returns, the older one is gone")
        notices.dismissIssue()
        #expect(notices.issue == nil)

        notices.report(question)
        notices.report(sourceFails(first), background: true)
        notices.report(sourceFails(second), background: true)
        notices.clearIssue()
        #expect(notices.issue == sourceFails(second), "the newest held wins")
    }

    /// A plain report no longer waits behind a failing source's banner: Open Signals asks nothing.
    @Test func aPlainReportReplacesASourcesBanner() {
        let rows = Rows(), notices = notices(rows), signal = UUID()
        notices.report(sourceFails(signal), background: true)
        notices.report("Couldn’t show the window.")
        #expect(notices.issue?.title == "Couldn’t show the window.")
    }

    /// A good read drops the signal's banner, shown or held, and leaves another signal's; a refresh rewrites only a
    /// banner still up or held; a removed signal's banner is stale.
    @Test func dropIssueAboutASignalAndItsRefresh() {
        let rows = Rows(), notices = notices(rows), signal = UUID(), other = UUID()
        notices.report(question)
        notices.report(sourceFails(signal), background: true)
        notices.dropIssue(aboutSignal: signal)
        notices.clearIssue()
        #expect(notices.issue == nil, "the held one went")

        notices.report(sourceFails(signal), background: true)
        notices.dropIssue(aboutSignal: other)
        #expect(notices.issue == sourceFails(signal))
        var newer = sourceFails(signal); newer.reason = "Refused. AiTerm tries again at 14:10."
        notices.refresh(newer)
        #expect(notices.issue == newer)
        notices.dropIssue(aboutSignal: signal)
        #expect(notices.issue == nil)
        notices.refresh(newer)
        #expect(notices.issue == nil, "a refresh raises nothing")

        notices.report(sourceFails(signal), background: true)
        rows.gone.insert(signal)
        notices.dropStale()
        #expect(notices.issue == nil)
        notices.report(sourceFails(signal), background: true)
        #expect(notices.issue == nil, "a removed signal's banner is never shown")
    }

    /// The toast goes on its own once its time is up.
    @Test func theToastGoesOnItsOwn() async {
        let notices = notices(Rows(), toastLifetime: .milliseconds(20))
        notices.showToast("Task removed.")
        #expect(notices.toastState.toast?.message == "Task removed.")
        await eventually(describing: "the toast to go") { notices.toastState.toast == nil }
    }
}
