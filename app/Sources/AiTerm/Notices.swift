import Foundation
import AiTermCore

/// What the person is told about work once it has finished or failed: the banner above the list —
/// a failed operation and the ways out it offers — and the completion toast. Every owner that has
/// something to report is handed this one, so which report wins the banner is decided here alone.
@MainActor
@Observable
final class Notices {
    /// The failed operation the banner above the list shows. Set through `report`, cleared by
    /// `dismissIssue`, by an action that answers it, or once the task or project it names is gone.
    private(set) var issue: OperationIssue?
    /// The latest report that had nothing to offer while `issue` held a question: it waits here, and
    /// takes the banner once the question is answered or dismissed. Not drawn, so not observed.
    @ObservationIgnored private var deferredIssue: OperationIssue?
    private(set) var toastState = ToastState()

    /// How long a completion toast stays up.
    private let toastLifetime: Duration
    /// Whether an issue names a task or a project the workspace no longer has.
    private let isStale: @MainActor (OperationIssue) -> Bool
    /// Who hears that the banner about a task was dismissed, or replaced by one about something else.
    @ObservationIgnored private var withdrawnHooks: [@MainActor (UUID) -> Void] = []

    init(toastLifetime: Duration, isStale: @escaping @MainActor (OperationIssue) -> Bool) {
        self.toastLifetime = toastLifetime
        self.isStale = isStale
    }

    /// Adds `hook` to what hears that the banner about a task was dismissed, or replaced by one
    /// about something else: whatever the task's row says in the banner's stead goes with it.
    func onWithdrawn(_ hook: @escaping @MainActor (UUID) -> Void) {
        withdrawnHooks.append(hook)
    }

    /// Completion feedback disappears on its own, after long enough to read a sentence — some say
    /// what was kept and why. The id means an older delayed dismissal cannot hide a newer toast.
    func showToast(_ message: String) {
        let id = toastState.show(message)
        Task { [weak self, toastLifetime] in
            try? await Task.sleep(for: toastLifetime)
            guard !Task.isCancelled else { return }
            self?.toastState.dismiss(id: id)
        }
    }

    /// Shows `issue` above the list, in place of whatever was there — unless it is about a task or
    /// project that has gone while the work it reports was running, or it offers nothing while a
    /// question with answers is still up: a background failure must not take "Branch X kept" and
    /// its Keep or Delete from someone who has not answered yet. It waits (the newest one) until
    /// the question is gone, and is logged meanwhile. The toast cannot carry it: it is the
    /// completion toast, a checkmark and all.
    func report(_ issue: OperationIssue) {
        guard !isStale(issue) else { return }
        if issue.actions.isEmpty, self.issue?.actions.isEmpty == false {
            NSLog("AiTerm: held back, a question is waiting: \(issue.title) \(issue.reason ?? "")")
            deferredIssue = issue
            return
        }
        if let shown = self.issue, shown.subject != issue.subject { withdraw(shown) }
        self.issue = issue
    }

    /// A failure with nothing to offer but Dismiss.
    func report(_ message: String) { report(OperationIssue(title: message)) }

    /// Dismissed, a removal that stopped with nothing deleted is just a task again. One that got
    /// past its worktree still waits on a retry, and its row keeps saying so.
    func dismissIssue() {
        if let issue { withdraw(issue) }
        clearIssue()
    }

    /// Takes the banner down, and puts up what was held back behind it, if its row is still there.
    /// For an action that answered the banner's question.
    func clearIssue() {
        issue = nil
        guard let held = deferredIssue else { return }
        deferredIssue = nil
        if !isStale(held) { issue = held }
    }

    /// Drops whatever is about task `id`, shown or held back — the held one first, so taking the
    /// shown one down cannot put it up in its place. For work that did what the banner asked.
    func dropIssues(about id: UUID) {
        if deferredIssue?.subject == id { deferredIssue = nil }
        if issue?.subject == id { clearIssue() }
    }

    /// The banner, and what is held back behind it, once the row either names has gone: through
    /// `window.closed`, a removed project, a restored backup or a removal.
    func dropStale() {
        if let held = deferredIssue, isStale(held) { deferredIssue = nil }
        if let issue, isStale(issue) { clearIssue() }
    }

    private func withdraw(_ issue: OperationIssue) {
        guard let subject = issue.subject else { return }
        for hook in withdrawnHooks { hook(subject) }
    }
}
