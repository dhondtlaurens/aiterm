import Foundation
import AiTermCore

/// The Shelf's state, apart from its view so it is tested without one: the query, the rows it ranks —
/// read from the workspace as it is now, so a restore or removal drops its row at once — and the
/// highlighted row, which ↑ ↓ move, wrapping, and ⌘↩ restores, or opens when it is an ended broadcast.
@MainActor @Observable
final class ArchiveSheetModel: Identifiable {
    let id = UUID()
    var query = "" { didSet { if query != oldValue { highlightedId = nil } } }
    /// The row ↑ ↓ last landed on; nil follows the first row.
    private var highlightedId: UUID?
    @ObservationIgnored private let entries: @MainActor () -> [ShelfRow]
    @ObservationIgnored private let restore: @MainActor (UUID) -> Void
    @ObservationIgnored private let open: @MainActor (UUID) -> Void
    @ObservationIgnored private let remove: @MainActor (UUID) -> Void
    /// The clock the rows' dates are read against; the snapshots fix it.
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    /// `restore` takes a task's or review's id, `open` an ended broadcast's; `remove` either.
    init(entries: @escaping @MainActor () -> [ShelfRow], restore: @escaping @MainActor (UUID) -> Void,
         open: @escaping @MainActor (UUID) -> Void, remove: @escaping @MainActor (UUID) -> Void) {
        self.entries = entries; self.restore = restore; self.open = open; self.remove = remove
    }

    /// One render or command's consistent view of the Shelf: ranked once, without caching a
    /// closure's changing workspace inputs across renders.
    struct Projection {
        let rows: [ShelfRow]
        let total: Int
        let highlighted: ShelfRow?
        let status: String

        /// The footer's primary button on the highlighted row; none with nothing highlighted.
        var primaryTitle: String? { highlighted.map(ArchiveSheetModel.primaryTitle(of:)) }
    }

    /// What ⌘↩ does to a row: Open for an ended broadcast, Restore for a task or review.
    nonisolated static func primaryTitle(of row: ShelfRow) -> String {
        switch row {
        case .task: "Restore"
        case .broadcast: "Open"
        }
    }

    var projection: Projection {
        let entries = entries(), rows = ArchiveSearch.rank(entries, query: query)
        let highlighted = rows.first { $0.id == highlightedId } ?? rows.first
        let status = query.trimmingCharacters(in: .whitespaces).isEmpty ? "\(entries.count) shelved" : "\(rows.count) of \(entries.count)"
        return Projection(rows: rows, total: entries.count, highlighted: highlighted, status: status)
    }

    func move(by step: Int) {
        let view = projection, rows = view.rows
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { $0.id == view.highlighted?.id } ?? 0
        highlightedId = rows[((at + step) % rows.count + rows.count) % rows.count].id
    }

    func highlight(_ id: UUID) { highlightedId = id }

    /// ⎋: a search is cleared first; false when there was none, and the sheet closes.
    func clearQuery() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        return true
    }

    /// ⌘↩, the primary button or a double-click: the highlighted task restored, or the highlighted
    /// broadcast opened. False when nothing is highlighted.
    @discardableResult
    func performHighlighted() -> Bool {
        switch projection.highlighted {
        case .task(let entry): restore(entry.archived.id)
        case .broadcast(let broadcast): open(broadcast.runId)
        case nil: return false
        }
        return true
    }

    func removeHighlighted() -> Bool {
        guard let row = projection.highlighted else { return false }
        remove(row.id)
        return true
    }
}
