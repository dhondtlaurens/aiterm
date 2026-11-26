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
        /// The second line: the Start's description, or its query (a schedule's cron) when it has none.
        var detail: String
        /// The second line is the query, drawn in the mono face.
        var detailIsQuery: Bool
        /// What the state column says; nil while it watches with nothing to say.
        var state: State?
        var switchedOff: Bool
        /// Whether a signal of its kind lies above or below it: Move Up and Move Down change their priority.
        var canMoveUp: Bool, canMoveDown: Bool
        /// What the search reads besides the name and the second line: the description, the query and the source.
        var searched: [String] = []
    }

    /// A row's state, one at a time: switched off, else what needs the person, else a schedule's next run.
    enum State: Equatable {
        /// A signal this version cannot run, its source's failing read, a skipped item: the chip's one line, the first
        /// issue's gist with the rest counted, and `detail`, every issue whole, for the glyph's help and VoiceOver.
        case issue(String, detail: [String])
        case switchedOff
        /// "Next run: 30 Nov 2026 09:00", or that none is to come.
        case schedule(String)
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
    var query = "" { didSet { if query != oldValue { highlightedId = nil } } }
    /// The row ↑ ↓ or a click last landed on; none until then.
    private var highlightedId: UUID?
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

    /// The rows the search finds, in priority order: a name, description, query or source holding the query, ignoring
    /// case and accents. Every row without a search.
    var visibleRows: [Row] {
        let query = Self.folded(query.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return rows }
        return rows.filter { row in ([row.name, row.detail] + row.searched).contains { Self.folded($0).contains(query) } }
    }

    var highlighted: Row? { visibleRows.first { $0.id == highlightedId } }

    /// ↑ ↓: from nothing to the first or the last, then along, wrapping.
    func move(by step: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let at = rows.firstIndex(where: { $0.id == highlightedId }) else {
            highlightedId = (step > 0 ? rows.first : rows.last)?.id; return
        }
        highlightedId = rows[((at + step) % rows.count + rows.count) % rows.count].id
    }

    func highlight(_ id: UUID) { highlightedId = id }

    /// ⎋: a search is cleared first; false when there was none, and the sheet closes.
    func clearQuery() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        return true
    }

    /// ⌘⌫: Remove Signal… on the highlighted row, which asks first; false with none.
    func removeHighlighted() -> Bool {
        guard let row = highlighted, canChange else { return false }
        remove(row.id)
        return true
    }

    private static func folded(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    // -- each row's menu and the footer --------------------------------------------------------
    func edit(_ id: UUID) { actions.edit(id) }
    func switchOnOff(_ id: UUID) { actions.switchOnOff(id) }
    func move(_ id: UUID, _ step: MoveStep) { actions.move(id, step) }
    func remove(_ id: UUID) { actions.remove(id) }
    func new() { actions.new() }
    var canChange: Bool { actions.canChange() }
    var canEdit: Bool { actions.canEdit() }

    /// The first issue as a sentence, and how many more there are: "PAY-7: No project. And 2 more."
    static func said(_ first: String, more: Int) -> String {
        guard more > 0 else { return first }
        return (first.hasSuffix(".") ? first : first + ".") + " And \(more) more."
    }

    /// `section`'s signals in `state` as rows, in their priority order: Operator signals in the Operator's section,
    /// project signals in the projects'. `failure` is a signal's failing read (`SignalReadIssues`), said with its source
    /// and when AiTerm tries again.
    static func rows(state: AppState, section: SidebarSection, failure: (UUID) -> SignalReadIssues.Issue?, now: Date,
                     calendar: Calendar = .autoupdatingCurrent) -> [Row] {
        let signals = state.signals.filter { $0.isProject == (section == .projects) }
        let skipped = SignalSidebar.skipped(in: state, calendar: calendar)
        let nextRuns = SignalSidebar.nextRuns(in: state, now: now, calendar: calendar)
        return signals.enumerated().map { index, signal in
            // Each issue whole, and its gist for the chip: a failing read's gist leaves out the server's error, which can
            // run past the sheet, and keeps the source and when AiTerm tries again.
            var issues = signal.isValid ? [] : ["This signal can’t run as it is set up."]
            var gists = issues
            if let failure = failure(signal.id) {
                let retry = SignalReadIssues.retry(after: failure, backOff: SignalPoller.failureBackOff, calendar: calendar)
                issues.append("Can’t read \(signal.start.source.label): " + SignalReadIssues.reason(failure.text, retry: retry))
                gists.append("Can’t read \(signal.start.source.label). " + retry)
            }
            issues += skipped[signal.id] ?? []
            gists += skipped[signal.id] ?? []
            let description = signal.start.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = signal.start.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let state: State? = if !signal.enabled { .switchedOff }
                else if let first = gists.first { .issue(Self.said(first, more: gists.count - 1), detail: issues) }
                else if signal.isScheduled { .schedule(SignalSummary.nextRun(nextRuns[signal.id], calendar: calendar) ?? "No run to come") }
                else { nil }
            return Row(id: signal.id, mark: ProviderIcon.source(of: signal.start.source), name: signal.name,
                       detail: description.isEmpty ? query : description, detailIsQuery: description.isEmpty, state: state,
                       switchedOff: !signal.enabled, canMoveUp: index > 0, canMoveDown: index < signals.count - 1,
                       searched: [description, query, signal.start.source.label])
        }
    }
}
