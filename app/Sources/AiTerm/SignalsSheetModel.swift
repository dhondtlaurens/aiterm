import Foundation
import AiTermCore
import AiTermUI

/// A section's signals sheet, apart from its view so it is tested without one: the section's signals in their priority
/// order, read whenever it draws so an edit, a switch or a removal shows at once, and what each row's menu and the
/// footer do. Every action takes a signal's id and the owner resolves the saved signal when it runs, so a stale row
/// acts on the signal as it is now, or on nothing once it is gone.
@MainActor @Observable
final class SignalsSheetModel: Identifiable {
    /// One signal as the sheet lists it.
    struct Row: Equatable, Identifiable {
        var id: UUID
        /// Its Start trigger's source, as its heading marks it.
        var mark: IconSource
        var name: String
        /// "Starts: …", with a schedule in words.
        var starts: String
        /// A schedule's "Next run: …"; nil for a signal that starts from items, or one that runs no more.
        var nextRun: String?
        /// "Done: …".
        var done: String
        /// What needs the person, in the warning ink: a signal this version cannot run, its source's failing read, and
        /// each skipped item with its reason.
        var issues: [String]
        var switchedOff: Bool
        /// Whether a signal of its kind lies above or below it: Move Up and Move Down change their priority.
        var canMoveUp: Bool, canMoveDown: Bool

        /// The trigger lines under its name, in order.
        var lines: [String] { [starts] + (nextRun.map { [$0] } ?? []) + [done] }
    }

    /// What the menus do, each with the id of the row it was chosen on.
    struct Actions {
        var edit: @MainActor (UUID) -> Void = { _ in }
        var switchOnOff: @MainActor (UUID) -> Void = { _ in }
        var move: @MainActor (UUID, MoveStep) -> Void = { _, _ in }
        var remove: @MainActor (UUID) -> Void = { _ in }
        var new: @MainActor () -> Void = {}
        /// Whether the workspace can change now: every action but Edit and New greys without it.
        var canChange: @MainActor () -> Bool = { true }
        /// Whether Edit Signal… and New Signal… can open their sheet now.
        var canEdit: @MainActor () -> Bool = { true }
    }

    let id = UUID()
    let section: SidebarSection
    @ObservationIgnored private let source: @MainActor () -> [Row]
    @ObservationIgnored let actions: Actions

    init(section: SidebarSection, rows: @escaping @MainActor () -> [Row], actions: Actions = Actions()) {
        self.section = section; source = rows; self.actions = actions
    }

    /// "Operator signals" or "Project signals".
    var title: String { section == .operator ? "Operator signals" : "Project signals" }

    /// What the sheet says while the section has no signal.
    var emptyText: String {
        section == .operator
            ? "No Operator signal yet. New Signal… hands the items it finds to the Operator."
            : "No project signal yet. New Signal… starts a task in its project for each item it finds."
    }

    /// The section's signals as they are now, in priority order.
    var rows: [Row] { source() }

    // -- each row's menu and the footer --------------------------------------------------------
    func edit(_ id: UUID) { actions.edit(id) }
    func switchOnOff(_ id: UUID) { actions.switchOnOff(id) }
    func move(_ id: UUID, _ step: MoveStep) { actions.move(id, step) }
    func remove(_ id: UUID) { actions.remove(id) }
    func new() { actions.new() }
    var canChange: Bool { actions.canChange() }
    var canEdit: Bool { actions.canEdit() }

    /// `section`'s signals in `state` as rows, in their priority order: Operator signals in the Operator's section,
    /// project signals in the projects'. `failure` is a signal's failing read (`SignalReadIssues`), said with its source
    /// and when AiTerm tries again.
    static func rows(state: AppState, section: SidebarSection, failure: (UUID) -> SignalReadIssues.Issue?, now: Date,
                     calendar: Calendar = .autoupdatingCurrent) -> [Row] {
        let signals = state.signals.filter { $0.isProject == (section == .projects) }
        let skipped = SignalSidebar.skipped(in: state, calendar: calendar)
        let nextRuns = SignalSidebar.nextRuns(in: state, now: now, calendar: calendar)
        return signals.enumerated().map { index, signal in
            var issues = signal.isValid ? [] : ["This signal can’t run as it is set up."]
            if let failure = failure(signal.id) {
                let retry = SignalReadIssues.retry(after: failure, backOff: SignalPoller.failureBackOff, calendar: calendar)
                issues.append("Can’t read \(signal.start.source.label): " + SignalReadIssues.reason(failure.text, retry: retry))
            }
            issues += skipped[signal.id] ?? []
            return Row(id: signal.id, mark: ProviderIcon.source(of: signal.start.source), name: signal.name,
                       starts: SignalSummary.starts(signal),
                       nextRun: signal.isScheduled ? SignalSummary.nextRun(nextRuns[signal.id], calendar: calendar) : nil,
                       done: SignalSummary.done(signal), issues: issues, switchedOff: !signal.enabled,
                       canMoveUp: index > 0, canMoveDown: index < signals.count - 1)
        }
    }
}
