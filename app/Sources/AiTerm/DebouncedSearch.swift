import Foundation
import AiTermCore

/// A search field's query, the rows its last search answered and the line saying why it failed, searched for again a
/// pause after each keystroke. New Task's and New Review's pickers and New Review's ticket field each keep one.
///
/// Latest wins: an answer that arrives after a newer search started, or after the search was let go, is dropped. A
/// failure clears the rows — rows from an earlier query beside an error about this one would read as its answer — and
/// a source that failed beside another's rows (`PartialSearch`) shows both.
@MainActor
@Observable
final class DebouncedSearch<Item: Sendable> {
    /// How long typing pauses before the query is searched for.
    static var pause: Duration { .milliseconds(250) }

    /// What letting the search go drops (`cancel()`, and each keystroke before it searches again). The pickers drop
    /// any search under way, one started directly — the sheet's opening search — among them; the ticket field cancels
    /// only the search its own typing started, so a direct search's answer can still land after it. Two rules from
    /// before they shared this type, each kept (`DebouncedSearchTests`).
    enum Superseding {
        case everySearch, typedSearchOnly
    }

    /// The text as it is typed.
    var query = ""
    /// The rows of the latest answer.
    var results: [Item] = []
    /// Why the latest search failed, or which of its sources did.
    var error: String?

    @ObservationIgnored private let lookup: @MainActor (String) async throws -> [Item]
    @ObservationIgnored private let superseding: Superseding
    /// The search the latest keystroke started, while it runs; a test awaits it.
    @ObservationIgnored private(set) var typed: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(superseding: Superseding = .everySearch, lookup: @escaping @MainActor (String) async throws -> [Item]) {
        self.superseding = superseding
        self.lookup = lookup
    }

    /// The field's text as it is typed: kept, and searched for after a pause.
    func type(_ text: String) {
        query = text
        cancel()
        typed = Task { await search(text, debounce: true) }
    }

    /// Lets the search go: what it answers is dropped (`Superseding`).
    func cancel() {
        typed?.cancel()
        guard superseding == .everySearch else { return }
        generation += 1
        typed = nil
    }

    /// Searches for `text` now, or after the pause, and keeps the answer if it is still the latest.
    func search(_ text: String, debounce: Bool = false) async {
        generation += 1
        let generation = generation
        do {
            if debounce { try await Task.sleep(for: Self.pause) }
            try Task.checkCancellation()
            let found = try await lookup(text)
            guard !Task.isCancelled, generation == self.generation else { return }
            results = found; error = nil
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return }
            if let partial = error as? PartialSearch<Item> {
                results = partial.items; self.error = partial.message
            } else {
                results = []; self.error = error.localizedDescription
            }
        }
    }
}
