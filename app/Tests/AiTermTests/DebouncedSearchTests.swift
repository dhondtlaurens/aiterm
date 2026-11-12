import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// `DebouncedSearch` took the place of two hand-rolled searches (phase 7): the pickers' (`CreationModel`) and New
/// Review's ticket field (`ReviewCreationModel`). Each is kept here as it was, as the reference, and driven through the
/// same steps as the shared type in the matching mode: what the field shows after each step — its rows and its error
/// line, in order — is the same, and so is the pause before a typed query is searched for.
@MainActor @Suite struct DebouncedSearchTests {
    /// A search's answers, held until the test gives them, in the order they were asked for.
    @MainActor final class HeldLookup {
        private(set) var asked: [String] = []
        private var waiting: [Int: CheckedContinuation<Result<[String], any Error>, Never>] = [:]

        func lookup(_ query: String) async throws -> [String] {
            let n = asked.count
            asked.append(query)
            return try await withCheckedContinuation { waiting[n] = $0 }.get()
        }

        /// Answers the `n`th question asked.
        func answer(_ n: Int, _ result: Result<[String], any Error>) {
            waiting.removeValue(forKey: n)?.resume(returning: result)
        }
    }

    struct Failed: LocalizedError { var errorDescription: String? { "boom" } }

    /// What both kinds of search are driven through.
    @MainActor protocol Driven: AnyObject {
        func type(_ text: String)
        func cancel()
        func search(_ text: String, debounce: Bool) async
        var typing: Task<Void, Never>? { get }
        var shown: Shown { get }
    }

    struct Shown: Equatable { var results: [String]; var error: String? }

    /// The pickers' search as it was before phase 7 (`CreationModel.setQuery`, `cancelSearch`, `search`).
    @MainActor final class PickerReference: Driven {
        var results: [String] = [], searchError: String?
        private(set) var typing: Task<Void, Never>?
        private var generation = 0
        let lookup: HeldLookup
        init(_ lookup: HeldLookup) { self.lookup = lookup }
        var shown: Shown { Shown(results: results, error: searchError) }

        func cancel() { generation += 1; typing?.cancel(); typing = nil }
        func type(_ text: String) { cancel(); typing = Task { await search(text, debounce: true) } }
        func search(_ text: String, debounce: Bool) async {
            generation += 1
            let generation = generation
            do {
                if debounce { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                let found = try await lookup.lookup(text)
                guard !Task.isCancelled, generation == self.generation else { return }
                results = found; searchError = nil
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                if let partial = error as? PartialSearch<String> { results = partial.items; searchError = partial.message; return }
                results = []
                searchError = error.localizedDescription
            }
        }
    }

    /// New Review's ticket field as it was before phase 7 (`setTicketQuery`, `pickTicket`'s cancel, `searchTickets`).
    @MainActor final class TicketReference: Driven {
        var results: [String] = [], searchError: String?
        private(set) var typing: Task<Void, Never>?
        private var generation = 0
        let lookup: HeldLookup
        init(_ lookup: HeldLookup) { self.lookup = lookup }
        var shown: Shown { Shown(results: results, error: searchError) }

        func cancel() { typing?.cancel() }
        func type(_ text: String) { typing?.cancel(); typing = Task { await search(text, debounce: true) } }
        func search(_ text: String, debounce: Bool) async {
            generation += 1
            let generation = generation
            do {
                if debounce { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                let found = try await lookup.lookup(text)
                guard !Task.isCancelled, generation == self.generation else { return }
                results = found; searchError = nil
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                if let partial = error as? PartialSearch<String> {
                    results = partial.items; searchError = partial.message
                } else {
                    results = []; searchError = error.localizedDescription
                }
            }
        }
    }

    /// The shared type, driven as the references are.
    @MainActor final class Shared: Driven {
        let field: DebouncedSearch<String>
        init(_ lookup: HeldLookup, _ superseding: DebouncedSearch<String>.Superseding) {
            field = DebouncedSearch(superseding: superseding) { try await lookup.lookup($0) }
        }
        var typing: Task<Void, Never>? { field.typed }
        var shown: Shown { Shown(results: field.results, error: field.error) }
        func type(_ text: String) { field.type(text) }
        func cancel() { field.cancel() }
        func search(_ text: String, debounce: Bool) async { await field.search(text, debounce: debounce) }
    }

    /// The steps, and what the field shows after each: the opening search, a typed query, two quick keystrokes, a
    /// failure, a partial answer, a typed search let go, and a direct search let go.
    func trace(_ field: any Driven, _ lookup: HeldLookup) async -> [Shown] {
        var shown: [Shown] = []
        // The sheet's opening search, then a typed query.
        let opening = Task { await field.search("", debounce: false) }
        await eventually(describing: "the opening search asked") { lookup.asked.count == 1 }
        lookup.answer(0, .success(["all"]))
        await opening.value
        shown.append(field.shown)
        field.type("a")
        let typedA = field.typing
        await eventually(describing: "the typed search asked") { lookup.asked.count == 2 }
        lookup.answer(1, .success(["a1"]))
        await typedA?.value
        shown.append(field.shown)
        // Two keystrokes inside the pause: only the second is searched for.
        field.type("ab")
        let first = field.typing
        field.type("abc")
        let second = field.typing
        await first?.value
        await eventually(describing: "the second keystroke searched") { lookup.asked.count == 3 }
        #expect(lookup.asked.last == "abc")
        lookup.answer(2, .failure(Failed()))
        await second?.value
        shown.append(field.shown)
        // One source failed beside another's rows.
        let partial = Task { await field.search("p", debounce: false) }
        await eventually(describing: "the partial search asked") { lookup.asked.count == 4 }
        lookup.answer(3, .failure(PartialSearch(items: ["p1"], message: "One source failed")))
        await partial.value
        shown.append(field.shown)
        // A typed search let go before its answer.
        field.type("q")
        let typedQ = field.typing
        await eventually(describing: "the typed search asked") { lookup.asked.count == 5 }
        field.cancel()
        lookup.answer(4, .success(["late"]))
        await typedQ?.value
        shown.append(field.shown)
        // A direct search let go before its answer.
        let direct = Task { await field.search("d", debounce: false) }
        await eventually(describing: "the direct search asked") { lookup.asked.count == 6 }
        field.cancel()
        lookup.answer(5, .success(["direct"]))
        await direct.value
        shown.append(field.shown)
        return shown
    }

    @Test func thePickersSearchShowsWhatItsOwnRuleShowed() async {
        let referenceLookup = HeldLookup(), sharedLookup = HeldLookup()
        let reference = await trace(PickerReference(referenceLookup), referenceLookup)
        let shared = await trace(Shared(sharedLookup, .everySearch), sharedLookup)
        #expect(shared == reference)
        #expect(sharedLookup.asked == referenceLookup.asked)
        #expect(reference == [
            Shown(results: ["all"], error: nil),
            Shown(results: ["a1"], error: nil),
            Shown(results: [], error: "boom"),
            Shown(results: ["p1"], error: "One source failed"),
            Shown(results: ["p1"], error: "One source failed"),  // the typed answer let go is dropped
            Shown(results: ["p1"], error: "One source failed"),  // and so is the direct one
        ])
    }

    @Test func theTicketFieldShowsWhatItsOwnRuleShowed() async {
        let referenceLookup = HeldLookup(), sharedLookup = HeldLookup()
        let reference = await trace(TicketReference(referenceLookup), referenceLookup)
        let shared = await trace(Shared(sharedLookup, .typedSearchOnly), sharedLookup)
        #expect(shared == reference)
        #expect(sharedLookup.asked == referenceLookup.asked)
        #expect(reference == [
            Shown(results: ["all"], error: nil),
            Shown(results: ["a1"], error: nil),
            Shown(results: [], error: "boom"),
            Shown(results: ["p1"], error: "One source failed"),
            Shown(results: ["p1"], error: "One source failed"),  // the typed answer let go is dropped
            Shown(results: ["direct"], error: nil),              // a direct search is not the field's to let go
        ])
    }

    /// Typing pauses as long as both did before.
    @Test func typingPausesAsBefore() {
        #expect(DebouncedSearch<String>.pause == .milliseconds(250))
    }
}
