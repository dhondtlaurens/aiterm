import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The New operation sheet as a model: the operator picked from the header used, the brief, when it is
/// done, where it opens, and Start Operation handing them to the operator controller (§10.6).
@MainActor
struct NewOperationModelTests {
    private let trusted = OperatorUIFixtures.persona("Incident investigator", handle: "investigator", autonomy: .trusted)

    private func model(start: @escaping @MainActor (OperatorPersona, String, String?) async throws -> UUID = { _, _, _ in UUID() })
        -> NewOperationModel {
        NewOperationModel(operators: [OperatorUIFixtures.senior, trusted], picked: "senior", start: start)
    }

    @Test func itSaysWhatHappensAndWhereItOpens() {
        let sheet = model()
        #expect(NewOperationModel.title == "New operation")
        #expect(sheet.subtitle == "Senior engineer plans it first; nothing starts before you see the plan.")
        #expect(sheet.destination.text == "Opens in iTerm2 · Senior engineer’s window · tasks in the projects the brief needs")
        sheet.handle = "investigator"
        #expect(sheet.subtitle == "Incident investigator plans it, then starts it at once; you watch the plan run.")
        #expect(NewOperationModel.briefHelp == "What to work on, as you would tell a colleague. A Jira key brings in its ticket.")
        #expect(NewOperationModel.doneWhenHelp == "What finished looks like. A draft MR or a merge happens only when this brief or the operator’s persona asks for it, as an end in the plan you approve.")
        #expect(NewOperationModel.doneWhenPlaceholder == "a commit per item, tests green — I review and push")
    }

    @Test func itStartsOnlyWithABrief() async {
        var started: [(String, String, String?)] = []
        let id = UUID()
        let sheet = model { persona, brief, doneWhen in started.append((persona.handle, brief, doneWhen)); return id }
        #expect(!sheet.canStart)
        #expect(await sheet.startOperation() == nil)
        sheet.brief = "  PLUTO-231 newsletter signup block in Storyblok\n"
        sheet.doneWhen = "   "
        #expect(sheet.canStart)
        #expect(await sheet.startOperation() == id)
        #expect(started.count == 1)
        #expect(started.first?.0 == "senior" && started.first?.1 == "PLUTO-231 newsletter signup block in Storyblok")
        #expect(started.first?.2 == nil, "an empty Done when is none: the end is a commit")
    }

    @Test func aStartThatFailsSaysWhyAndCanBeTriedAgain() async {
        struct Refused: LocalizedError { var errorDescription: String? { "AiTerm couldn’t open the operator’s window." } }
        let sheet = model { _, _, _ in throw Refused() }
        sheet.brief = "PLUTO-231"
        #expect(await sheet.startOperation() == nil)
        #expect(sheet.error == "AiTerm couldn’t open the operator’s window.")
        #expect(!sheet.starting && sheet.canStart)
    }

    /// A start held open: the second press, or ⌘↩ while it is in flight, must not start a second operation.
    @Test func aSecondPressWhileAStartIsInFlightStartsNothingMore() async {
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var enteredStarts = entered.makeAsyncIterator()
        let id = UUID()
        let sheet = model { _, _, _ in
            calls += 1
            signal.yield()
            await withCheckedContinuation { release = $0 }
            return id
        }
        sheet.brief = "PLUTO-231"
        let first = Task { await sheet.startOperation() }
        await enteredStarts.next()
        #expect(sheet.starting && !sheet.canStart)
        #expect(await sheet.startOperation() == nil, "pressed again while the first is in flight")
        #expect(calls == 1)
        release?.resume()
        #expect(await first.value == id)
        #expect(calls == 1 && !sheet.starting)
    }
}
