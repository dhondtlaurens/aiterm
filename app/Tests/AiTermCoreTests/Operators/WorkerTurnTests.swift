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
}
