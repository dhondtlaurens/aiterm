import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The New operation sheet as a model: the prompt, when it is done, where it opens, and Start Operation
/// handing them to the operator controller with Settings › Operator's profile.
@MainActor
struct NewOperationModelTests {
    private func model(start: @escaping @MainActor (OperatorProfile, String, String?) async throws -> UUID = { _, _, _ in UUID() })
        -> NewOperationModel {
        NewOperationModel(profile: OperatorUIFixtures.profile, start: start)
    }

    @Test func itSaysWhatHappensAndWhereItOpens() {
        let sheet = model()
        #expect(NewOperationModel.title == "New operation")
        #expect(NewOperationModel.subtitle == "The Operator plans it first; nothing starts before you see the plan.")
        #expect(sheet.destination.text == "Opens in iTerm2 · The Operator’s window · tasks in the projects the brief needs")
        #expect(NewOperationModel.promptHelp == "What to work on, as you would tell a colleague. A Jira key brings in its ticket.")
        #expect(NewOperationModel.doneHelp == "What finished looks like. A draft MR or a merge happens only when this asks for it, as an end in the plan.")
        #expect(NewOperationModel.donePlaceholder == "a commit per item, tests green, I review and push")
        for text in [NewOperationModel.subtitle, NewOperationModel.promptHelp, NewOperationModel.doneHelp, NewOperationModel.donePlaceholder] {
            #expect(!text.contains("—"), "no em dash in \(text)")
        }
    }

    @Test func itStartsOnlyWithAPromptAndOnTheProfileItOpenedWith() async {
        var started: [(OperatorProfile, String, String?)] = []
        let id = UUID()
        let sheet = model { profile, prompt, done in started.append((profile, prompt, done)); return id }
        #expect(!sheet.canStart)
        #expect(await sheet.startOperation() == nil)
        sheet.prompt = "  PLUTO-231 newsletter signup block in Storyblok\n"
        sheet.done = "   "
        #expect(sheet.canStart)
        #expect(await sheet.startOperation() == id)
        #expect(started.count == 1)
        #expect(started.first?.0 == OperatorUIFixtures.profile && started.first?.1 == "PLUTO-231 newsletter signup block in Storyblok")
        #expect(started.first?.2 == nil, "an empty Done is none: the end is a commit")
    }

    @Test func aStartThatFailsSaysWhyAndCanBeTriedAgain() async {
        struct Refused: LocalizedError { var errorDescription: String? { "AiTerm couldn’t open the operator’s window." } }
        let sheet = model { _, _, _ in throw Refused() }
        sheet.prompt = "PLUTO-231"
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
        sheet.prompt = "PLUTO-231"
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
