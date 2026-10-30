import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

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

    /// Content needs a known baseline; a different HEAD is evidence even for older acceptances.
    @Test func workAfterAcceptanceIsChangedContentOrAnotherHead() {
        let accepted = "4f2a91c0ffee4f2a91c0ffee4f2a91c0ffee4f2a"
        #expect(!WorkerTurn.changedAfterAcceptance(head: accepted, accepted: "4f2a91c", fingerprint: "dirty", acceptedFingerprint: "dirty"))
        #expect(WorkerTurn.changedAfterAcceptance(head: accepted, accepted: accepted, fingerprint: "new", acceptedFingerprint: "old"))
        #expect(WorkerTurn.changedAfterAcceptance(head: "b0b0b0b0b0b0", accepted: accepted))
        #expect(!WorkerTurn.changedAfterAcceptance(head: accepted, accepted: accepted, fingerprint: "dirty"), "legacy dirt has no date")
        #expect(!WorkerTurn.changedAfterAcceptance(head: nil, accepted: accepted, acceptedFingerprint: "old"), "failed reads say nothing")
        #expect(!WorkerTurn.changedAfterAcceptance(head: accepted, accepted: nil, fingerprint: "new", acceptedFingerprint: "old"))
    }

    @Test func contentFingerprintSurvivesStagingAndDetectsEditsWithIdenticalStatus() throws {
        let git = GitRunner.hermetic(), path = try GitFixture.makeRepo(prefix: "acceptance-content-")
        let repository = Repository(path, git: git), clean = try repository.worktreeFingerprint()
        let name = " plan\nnotes.bin", file = URL(fileURLWithPath: path).appendingPathComponent(name)
        try Data([0, 255, 1]).write(to: file)
        let untracked = try repository.worktreeFingerprint()
        #expect(untracked != clean)
        try git.run(["add", "--", name], in: path)
        #expect(try repository.worktreeFingerprint() == untracked, "git add alone changes no content")
        try Data([0, 255, 2]).write(to: file)
        let edited = try repository.worktreeFingerprint()
        #expect(edited != untracked)
        let before = try git.run(["status", "--porcelain"], in: path)
        try Data([0, 255, 3]).write(to: file)
        #expect(try repository.worktreeFingerprint() != edited)
        let after = try git.run(["status", "--porcelain"], in: path)
        #expect(before == after, "the later edit changes content while status stays identical")
        try git.run(["add", "--", name], in: path)
        let staged = try repository.worktreeFingerprint()
        try git.run(["commit", "-q", "-m", "notes"], in: path)
        #expect(try repository.worktreeFingerprint() == clean)
        try FileManager.default.removeItem(at: file)
        #expect(try repository.worktreeFingerprint() != clean, "tracked deletion")
        #expect(try repository.worktreeFingerprint() != staged)
    }

    @Test func fingerprintsReadSymlinksWithoutFollowingThemAndNoticeExecutableChanges() throws {
        let git = GitRunner.hermetic(), path = try GitFixture.makeRepo(prefix: "acceptance-links-")
        let repository = Repository(path, git: git)
        let outside = URL(fileURLWithPath: try GitFixture.folder("acceptance-outside-")).appendingPathComponent("secret")
        let link = URL(fileURLWithPath: path).appendingPathComponent("link")
        try Data("first".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        let initial = try repository.worktreeFingerprint()
        try Data("later".utf8).write(to: outside)
        #expect(try repository.worktreeFingerprint() == initial, "outside content is not read")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path + "-missing")
        #expect(try repository.worktreeFingerprint() != initial, "a changed, dangling link is still content")
        let script = URL(fileURLWithPath: path).appendingPathComponent("run.sh")
        try Data("echo ok\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        let regular = try repository.worktreeFingerprint()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        #expect(try repository.worktreeFingerprint() != regular)
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
