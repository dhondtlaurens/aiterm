import Foundation
import AiTermCore

/// The Archive's state, apart from its view so it is tested without one: the query, the rows it ranks —
/// read from the workspace as it is now, so a restore or removal drops its row at once — and the
/// highlighted row, which ↑ ↓ move, wrapping, and ⌘↩ restores.
@MainActor @Observable
final class ArchiveSheetModel: Identifiable {
    let id = UUID()
    var query = "" { didSet { if query != oldValue { highlightedId = nil } } }
    /// The row ↑ ↓ last landed on; nil follows the first row.
    private var highlightedId: UUID?
    @ObservationIgnored private let entries: @MainActor () -> [ArchiveSearch.Entry]
    @ObservationIgnored private let restoreAction: @MainActor (UUID) -> Void
    @ObservationIgnored private let removeAction: @MainActor (UUID) -> Void
    /// The clock the rows' dates are read against; the snapshots fix it.
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    /// `restore` and `remove` take an archived task or review id.
    init(entries: @escaping @MainActor () -> [ArchiveSearch.Entry], restore: @escaping @MainActor (UUID) -> Void,
         remove: @escaping @MainActor (UUID) -> Void) {
        self.entries = entries; restoreAction = restore; removeAction = remove
    }

    /// One render or command's consistent view of the Archive. Ranking is reused only while
    /// the source's current rows and the query are equal.
    struct Projection {
        let rows: [ArchiveSearch.Entry]
        let total: Int
        let highlighted: ArchiveSearch.Entry?
        let status: String

        /// The footer's primary button on the highlighted row; none with nothing highlighted.
        var primaryTitle: String? { highlighted == nil ? nil : "Restore" }
    }

    /// One retained ranking. The source is still read every time, under Observation,
    /// so replacement rows, restored/removed entries and edits invalidate it immediately.
    @ObservationIgnored private var rankedInput: [ArchiveSearch.Entry]?
    @ObservationIgnored private var rankedQuery = ""
    @ObservationIgnored private var rankedRows: [ArchiveSearch.Entry] = []

    var projection: Projection {
        let entries = entries()
        if entries != rankedInput || query != rankedQuery {
            WorkMeter.note(.archiveRank)
            rankedRows = ArchiveSearch.rank(entries, query: query)
            rankedInput = entries; rankedQuery = query
        }
        let rows = rankedRows
        let highlighted = rows.first { $0.id == highlightedId } ?? rows.first
        let status = query.trimmingCharacters(in: .whitespaces).isEmpty ? "\(entries.count) archived" : "\(rows.count) of \(entries.count)"
        return Projection(rows: rows, total: entries.count, highlighted: highlighted, status: status)
    }

    func move(by step: Int) {
        let view = projection, rows = view.rows
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { $0.id == view.highlighted?.id } ?? 0
        highlightedId = rows[((at + step) % rows.count + rows.count) % rows.count].id
    }

    func highlight(_ id: UUID) { highlightedId = id }

    /// The rows as the sheet lists them: under their dates' groups, newest first, without a search (`ArchiveDate`); a
    /// search's matches best first, under no heading. Either way in the order ↑ ↓ walk.
    func groups(calendar: Calendar, locale: Locale) -> [ListGroup<ArchiveSearch.Entry>] {
        let rows = projection.rows
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return rows.isEmpty ? [] : [ListGroup(heading: nil, items: rows)] }
        let now = now()
        var groups: [ListGroup<ArchiveSearch.Entry>] = []
        for row in rows {
            let heading = ArchiveDate.group(row.archived.archivedAt, now: now, calendar: calendar, locale: locale)
            if groups.last?.heading == heading { groups[groups.count - 1].items.append(row) }
            else { groups.append(ListGroup(heading: heading, items: [row])) }
        }
        return groups
    }

    /// A row's menu: Restore and Remove… act on the row they were chosen on.
    func restore(_ id: UUID) { restoreAction(id) }
    func remove(_ id: UUID) { removeAction(id) }

    /// ⎋: a search is cleared first; false when there was none, and the sheet closes.
    func clearQuery() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        return true
    }

    /// Restores the highlighted entry; false when nothing is highlighted.
    @discardableResult
    func performHighlighted() -> Bool {
        guard let entry = projection.highlighted else { return false }
        restoreAction(entry.id)
        return true
    }

    func removeHighlighted() -> Bool {
        guard let row = projection.highlighted else { return false }
        removeAction(row.id)
        return true
    }
}
