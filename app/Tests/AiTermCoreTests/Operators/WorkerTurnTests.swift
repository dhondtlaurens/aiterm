import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// Whether a worker's last message asks a question, and the question itself.
@Suite(.blocking) struct WorkerTurnTests {
    @Test func aLastLineEndingInAQuestionMarkAsks() {
        #expect(WorkerTurn.endsWithQuestion("Done.\n\nShould I also bump eslint?"))
        #expect(WorkerTurn.endsWithQuestion("**Ready?**  "), "markdown emphasis and trailing spaces are stripped")
        #expect(WorkerTurn.endsWithQuestion("Shall I commit it?\n\n\n"), "the last line that says something")
        #expect(!WorkerTurn.endsWithQuestion("Ran the tests. All green."))
        #expect(!WorkerTurn.endsWithQuestion("Why did it fail? The lockfile was stale. Fixed."), "a question earlier is answered")
        #expect(!WorkerTurn.endsWithQuestion(nil))
        #expect(!WorkerTurn.endsWithQuestion(""))
    }

    @Test func theQuestionIsTheLastParagraphCutToThreeHundredCharacters() {
        #expect(WorkerTurn.question("Done.\n\nShould I also bump eslint?") == "Should I also bump eslint?")
        #expect(WorkerTurn.question("Done.\n\n  \nShould I commit it,\nor leave it staged?\n") == "Should I commit it,\nor leave it staged?")
        let long = String(repeating: "word ", count: 99) + "ready?"
        #expect(long.count > 490)
        #expect(WorkerTurn.question("Intro.\n\n" + long).count == WorkerTurn.questionLimit)
        #expect(WorkerTurn.questionLimit == 300)
    }

    @Test func aQuestionWithAnswerOptionsStillAsksWhenItsFinalLineHasNoQuestionMark() {
        let message = "No files, tests or commits changed.\n\nShould I add runChanged(id), or leave that to P7?\n- Add it here.\n- Leave it to P7."
        #expect(WorkerTurn.endsWithQuestion(message))
        #expect(WorkerTurn.question(message).contains("Should I add runChanged(id)"))
        #expect(!WorkerTurn.endsWithQuestion("Why did it fail?\nThe lockfile was stale. Fixed it and all tests pass."))
    }

    @Test(arguments: [
        "Read the review. Item 4 requires a change outside the authorized scope.\n\nMay I add that initialization call, keeping its implementation in `AppController+Operators.swift`? Your scope rule explicitly requires me to stop before editing another file.\n\nNo files changed, tests run, or new commit made. HEAD remains `76c4896`.",
        "Blocked by another out-of-scope hook gap.\n\nMay I add `runChanged(id)` after the end is saved, or should P7 supply it? Your scope rule requires me to stop before editing this file.\n\nOnly regression tests have changed; no implementation changes or new commit. HEAD remains `76c4896`. The targeted test run is still building; its latest output is:\n\n```text\n[11 / 11] AiTermCoreTests-product\n```",
        "Stopped at a spec question, as instructed. No files changed or commits made.\n\nShould `read_task diff` on a closed task show:\n\n- **The whole task diff** (recommended)\n- **Only the accepted commit’s patch**\n\nThe record currently preserves neither the base branch nor stacked-parent information needed for the whole diff.\n\n`scripts/test.sh` is still running. Latest output tail:\n\n```text\ntest selector guard passed\n```",
        "**Question:** Is that what the person wants, or should a waiting reason show while the pass is open? Either way, that’s a change in P4’s board code.",
    ])
    func scopeQuestionsRemainPendingThroughTrailingStatus(_ message: String) {
        #expect(WorkerTurn.endsWithQuestion(message))
        let question = WorkerTurn.question(message)
        #expect(question.contains("May I") || question.contains("Should `read_task diff`") || question.contains("Question:"))
        #expect(!question.contains("HEAD remains") && !question.contains("test selector guard passed"))
    }

    /// One worker's last message of the shared table (H3), which `RunStatusTests` reads too: whether the scan says it asks,
    /// and the question it reads, when the row names one.
    struct LastMessage: Decodable, CustomTestStringConvertible {
        var name: String, message: String, asks: Bool, question: String?
        var testDescription: String { name }

        static let table: [LastMessage] = {
            let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/worker-last-messages.json")
            return (try? JSONDecoder().decode([LastMessage].self, from: Data(contentsOf: file))) ?? []
        }()
    }

    @Test func theSharedTableHasItsRows() { #expect(LastMessage.table.count == 5) }

    @Test(arguments: LastMessage.table)
    func eachLastMessageOfTheSharedTableAsksOrNot(_ row: LastMessage) {
        #expect(WorkerTurn.endsWithQuestion(row.message) == row.asks)
        if let question = row.question { #expect(WorkerTurn.question(row.message) == question) }
    }

    @Test func aHistoricalQuestionFollowedByWorkIsNotPending() {
        #expect(!WorkerTurn.endsWithQuestion("Why did the tests fail?\n\nThe lockfile was stale. Fixed it and all tests pass."))
        #expect(!WorkerTurn.endsWithQuestion("Should the cache be cleared?\n\nThe existing invalidation already covers it. Committed the fix."))
    }

}
