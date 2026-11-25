import Foundation
import AiTermCore
import os

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
    /// A background report (a failing signal's source) kept back while a question is up, or put back when something
    /// else took its place: it takes the banner once the banner is free and nothing else waits. Not drawn.
    @ObservationIgnored private var heldBackground: OperationIssue?
    private(set) var toastState = ToastState()

    /// How long a completion toast stays up.
    private let toastLifetime: Duration
    /// Whether an issue names a task or a project the workspace no longer has.
    private let isStale: @MainActor (OperationIssue) -> Bool
    /// Who hears that the banner about a task was dismissed, or replaced by one about something else.
    @ObservationIgnored private let withdrawnHooks = HookList<UUID>()
    /// Who hears the banner's issue change: the one it showed and the one it shows now, either nil.
    @ObservationIgnored private let issueHooks = HookList<(old: OperationIssue?, new: OperationIssue?)>()

    init(toastLifetime: Duration, isStale: @escaping @MainActor (OperationIssue) -> Bool) {
        self.toastLifetime = toastLifetime
        self.isStale = isStale
    }

    /// Adds `hook` to what hears that the banner about a task was dismissed, or replaced by one
    /// about something else: whatever the task's row says in the banner's stead goes with it.
    @discardableResult
    func onWithdrawn(_ hook: @escaping @MainActor (UUID) -> Void) -> HookList<UUID>.Token {
        withdrawnHooks.add(hook)
    }

    /// Adds `hook` to what hears the banner's issue change — shown, replaced, dismissed or answered —
    /// with the one it showed and the one it shows now: a driven task's `problem` follows it.
    @discardableResult
    func onIssueChanged(_ hook: @escaping @MainActor (_ old: OperationIssue?, _ new: OperationIssue?) -> Void)
        -> HookList<(old: OperationIssue?, new: OperationIssue?)>.Token {
        issueHooks.add { hook($0.old, $0.new) }
    }

    func showRemoval(of task: TaskItem, result: TaskWorkflow.Removed) {
        showToast("\(task.kindName) removed." + (result.keptBranch.map { " " + $0.note(branch: task.branch) } ?? ""))
    }

    /// Completion feedback disappears on its own, after long enough to read a sentence — some say
    /// what was kept and why. The id means an older delayed dismissal cannot hide a newer toast.
    /// `symbol` is the glyph in front of it: the checkmark, unless the toast names its own.
    func showToast(_ message: String, symbol: String = "checkmark.circle.fill") {
        let id = toastState.show(message, symbol: symbol)
        Task { [weak self, toastLifetime] in
            try? await Task.sleep(for: toastLifetime)
            guard !Task.isCancelled else { return }
            self?.toastState.dismiss(id: id)
        }
    }

    /// Shows `issue` above the list, in place of whatever was there — unless it is about a task or
    /// project that has gone while the work it reports was running, or it asks nothing (`isQuestion`)
    /// while a question with answers is still up: a background failure must not take a diverged pull's
    /// Rebase from someone who has not answered yet. It waits (the newest one) until
    /// the question is gone, and is logged meanwhile. The toast cannot carry it: it is the
    /// completion toast, a checkmark and all.
    func report(_ issue: OperationIssue) {
        guard !isStale(issue) else { return }
        if !issue.isQuestion, self.issue?.isQuestion == true { return hold(issue, while: "a question is waiting") }
        replace(with: issue)
    }

    /// Shows `issue`, which nobody asked for just now (a signal whose source keeps failing), unless a question is up:
    /// then it waits, even though it has actions of its own, and takes the banner once the question is gone. The newest
    /// background report wins the one place: it replaces another shown or held.
    func report(_ issue: OperationIssue, background: Bool) {
        guard background else { return report(issue) }
        guard !isStale(issue) else { return }
        if self.issue?.isQuestion == true {
            Log.ui.notice("Held back while a question is waiting: \(issue.title, privacy: .public)")
            heldBackground = issue
            return
        }
        if heldBackground?.signal == issue.signal { heldBackground = nil }
        replace(with: issue)
    }

    /// The banner about signal `issue.signal`, shown or held, says `issue` now (its newer error and retry time). Nothing
    /// else changes: a dismissed one stays dismissed.
    func refresh(_ issue: OperationIssue) {
        guard let signal = issue.signal else { return }
        if heldBackground?.signal == signal { heldBackground = issue }
        if self.issue?.signal == signal { show(issue) }
    }

    /// Takes down what is about `signal`, shown or held back: its source reads again, or it was switched off.
    func dropIssue(aboutSignal signal: UUID) {
        if heldBackground?.signal == signal { heldBackground = nil }
        if deferredIssue?.signal == signal { deferredIssue = nil }
        if issue?.signal == signal { clearIssue() }
    }

    /// Shows `issue` in place of the banner's, withdrawing that one's task. A background banner something else takes the
    /// place of is put back behind it, unless a newer one waits there already.
    private func replace(with issue: OperationIssue) {
        if let shown = self.issue {
            if shown.subject != issue.subject { withdraw(shown) }
            if shown.signal != nil, shown.signal != issue.signal, issue.signal == nil, heldBackground == nil { heldBackground = shown }
        }
        show(issue)
    }

    /// A failure with nothing to offer but Dismiss.
    func report(_ message: String) { report(OperationIssue(title: message)) }

    /// Dismissed, a removal that stopped with nothing deleted is just a task again.
    func dismissIssue() {
        if let issue { withdraw(issue) }
        clearIssue()
    }

    /// Takes the banner down, and puts up what was held back behind it, if its row is still there.
    /// For an action that answered the banner's question.
    func clearIssue() {
        show(nil)
        if let held = deferredIssue {
            deferredIssue = nil
            if !isStale(held) { return show(held) }
        }
        if let background = heldBackground {
            heldBackground = nil
            if !isStale(background) { show(background) }
        }
    }

    /// The one write to `issue`, telling `issueHooks` when it changed.
    private func show(_ new: OperationIssue?) {
        let old = issue
        issue = new
        guard old != new else { return }
        issueHooks((old, new))
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
        if let background = heldBackground, isStale(background) { heldBackground = nil }
        if let issue, isStale(issue) { clearIssue() }
    }

    /// Keeps `issue` back until the banner is free, as the newest held — except over a held question,
    /// which a report with nothing to offer never takes the place of (it is logged and dropped, as
    /// it would be behind the question shown). A question held in place of another withdraws it, so
    /// whatever its row said in the banner's stead goes with it.
    private func hold(_ issue: OperationIssue, while reason: String) {
        if let held = deferredIssue, held.isQuestion {
            if !issue.isQuestion {
                Log.ui.notice("Dropped behind a held question: \(issue.title, privacy: .public) \(issue.reason ?? "", privacy: .public)")
                return
            }
            if held.subject != issue.subject { withdraw(held) }
        }
        Log.ui.notice("Held back while \(reason, privacy: .public): \(issue.title, privacy: .public) \(issue.reason ?? "", privacy: .public)")
        deferredIssue = issue
    }

    private func withdraw(_ issue: OperationIssue) {
        guard let subject = issue.subject else { return }
        withdrawnHooks(subject)
    }
}
