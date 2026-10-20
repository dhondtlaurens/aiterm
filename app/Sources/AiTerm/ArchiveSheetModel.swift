import Foundation
import AiTermCore

/// The Archive sheet's state, apart from its view so it is tested without one: the query, the rows
/// it ranks — read from the workspace as it is now, so a restore or removal drops its row at once —
/// and the highlighted row, which ↑ ↓ move, wrapping, and ⌘↩ restores.
@MainActor @Observable
final class ArchiveSheetModel: Identifiable {
    let id = UUID()
    var query = "" { didSet { if query != oldValue { highlightedId = nil } } }
    /// The row ↑ ↓ last landed on; nil follows the first row.
    private var highlightedId: UUID?
    @ObservationIgnored private let entries: @MainActor () -> [ArchiveSearch.Entry]
    @ObservationIgnored private let restore: @MainActor (UUID) -> Void
    @ObservationIgnored private let remove: @MainActor (UUID) -> Void
    /// The clock the rows' dates are read against; the snapshots fix it.
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    init(entries: @escaping @MainActor () -> [ArchiveSearch.Entry], restore: @escaping @MainActor (UUID) -> Void,
         remove: @escaping @MainActor (UUID) -> Void) {
        self.entries = entries; self.restore = restore; self.remove = remove
    }

    /// One render or command's consistent view of the archive: ranked once, without caching a
    /// closure's changing workspace inputs across renders.
    struct Projection {
        let rows: [ArchiveSearch.Entry]
        let total: Int
        let highlighted: ArchiveSearch.Entry?
        let status: String
    }

    var projection: Projection {
        let entries = entries(), rows = ArchiveSearch.rank(entries, query: query)
        let highlighted = rows.first { $0.archived.id == highlightedId } ?? rows.first
        let status = query.trimmingCharacters(in: .whitespaces).isEmpty ? "\(entries.count) shelved" : "\(rows.count) of \(entries.count)"
        return Projection(rows: rows, total: entries.count, highlighted: highlighted, status: status)
    }

    func move(by step: Int) {
        let view = projection, rows = view.rows
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { $0.archived.id == view.highlighted?.archived.id } ?? 0
        highlightedId = rows[((at + step) % rows.count + rows.count) % rows.count].archived.id
    }

    func highlight(_ id: UUID) { highlightedId = id }

    /// ⎋: a search is cleared first; false when there was none, and the sheet closes.
    func clearQuery() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        return true
    }

    func restoreHighlighted() -> Bool {
        guard let row = projection.highlighted else { return false }
        restore(row.archived.id)
        return true
    }

    func removeHighlighted() -> Bool {
        guard let row = projection.highlighted else { return false }
        remove(row.archived.id)
        return true
    }
}
