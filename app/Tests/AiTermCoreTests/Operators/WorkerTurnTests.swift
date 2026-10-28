import Testing
import Foundation
@testable import AiTermCore

/// What a worker's ended turn says (spec §J): whether its last message asks the Operator something, the question it
/// asks, and whether work was done after its task was accepted.
@Suite struct WorkerTurnTests {
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

    /// An accepted task changed once its worktree has edits not committed, or its HEAD moved past the accepted commit.
    @Test func workAfterAcceptanceIsADirtyWorktreeOrAnotherHead() {
        let accepted = "4f2a91c0ffee4f2a91c0ffee4f2a91c0ffee4f2a"
        #expect(!WorkerTurn.changedAfterAcceptance(porcelain: "", head: accepted, accepted: accepted))
        #expect(!WorkerTurn.changedAfterAcceptance(porcelain: "\n", head: accepted, accepted: "4f2a91c"), "a short SHA is the same commit")
        #expect(WorkerTurn.changedAfterAcceptance(porcelain: " M src/app.ts", head: accepted, accepted: accepted))
        #expect(WorkerTurn.changedAfterAcceptance(porcelain: "", head: "b0b0b0b0b0b0", accepted: accepted))
        #expect(!WorkerTurn.changedAfterAcceptance(porcelain: "", head: nil, accepted: accepted), "a HEAD git couldn't read says nothing")
        #expect(!WorkerTurn.changedAfterAcceptance(porcelain: "", head: accepted, accepted: nil))
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

    @Test func aHistoricalQuestionFollowedByWorkIsNotPending() {
        #expect(!WorkerTurn.endsWithQuestion("Why did the tests fail?\n\nThe lockfile was stale. Fixed it and all tests pass."))
        #expect(!WorkerTurn.endsWithQuestion("Should the cache be cleared?\n\nThe existing invalidation already covers it. Committed the fix."))
    }

}
