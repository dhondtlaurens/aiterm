import Testing
@testable import AiTermCore

struct GitErrorTests {
    /// git narrates before it fails — `Preparing worktree (checking out 'feat/x')` comes first — so
    /// the first lines of stderr are the wrong ones to show when there is room for only a few.
    @Test func theReasonIsGitsFatalAndErrorLines() {
        let stderr = "Preparing worktree (checking out 'feat/x')\nfatal: 'feat/x' is already used by worktree at '/r/.worktrees/x'\n"
        #expect(GitError(args: ["worktree", "add"], code: 128, stderr: stderr).reason
                == "fatal: 'feat/x' is already used by worktree at '/r/.worktrees/x'")
        let both = "hint: something\nerror: pathspec 'x' did not match\nfatal: unable to continue"
        #expect(GitError(args: [], code: 1, stderr: both).reason == "error: pathspec 'x' did not match\nfatal: unable to continue")
    }

    @Test func withoutAFatalLineTheLastLineIsTheReason() {
        #expect(GitError(args: [], code: 1, stderr: "first\nthe actual problem\n\n").reason == "the actual problem")
        #expect(GitError(args: [], code: 128, stderr: "").reason == "Git exited with status 128.")
    }

    /// git's refusals as git 2.54 words them, and the sentence each becomes beside AiTerm's own. A
    /// line that ends in `:` introduces the files it is about, which are kept, a few of them.
    @Test(arguments: [
        ("error: Your local changes to the following files would be overwritten by merge:\n\tfile.txt\n"
            + "Please commit your changes or stash them before you merge.\nAborting",
         "Your local changes to the following files would be overwritten by merge: file.txt."),
        ("error: The following untracked working tree files would be overwritten by merge:\n\ta.txt\n\tb.txt\n\tc.txt\n\td.txt\n\te.txt\n"
            + "Please move or remove them before you merge.\nAborting",
         "The following untracked working tree files would be overwritten by merge: a.txt, b.txt, c.txt and 2 more."),
        ("error: cannot rebase: You have unstaged changes.\nerror: Please commit or stash them.",
         "Cannot rebase: You have unstaged changes. Please commit or stash them."),
        ("error: the branch 'feat/x' is not fully merged\nhint: If you are sure you want to delete it, run 'git branch -D feat/x'\n"
            + "hint: Disable this message with \"git config set advice.forceDeleteBranch false\"",
         "The branch 'feat/x' is not fully merged."),
        ("fatal: refusing to fetch into branch 'refs/heads/main' checked out at '/r'",
         "Refusing to fetch into branch 'refs/heads/main' checked out at '/r'."),
        ("error: nothing follows this:", "Nothing follows this:"),
    ])
    func theSentenceOfARefusal(stderr: String, sentence: String) {
        #expect(GitError.sentence(of: GitError(args: [], code: 1, stderr: stderr)) == sentence)
    }

    @Test func onlyWorktreeRemovesRefusalOverUnsavedWorkAsksToForce() {
        let refusal = "fatal: '/r/.worktrees/x' contains modified or untracked files, use --force to delete it"
        #expect(GitError(args: ["worktree", "remove", "/r/.worktrees/x"], code: 128, stderr: refusal).refusedForUnsavedWork)
        #expect(!GitError(args: ["worktree", "remove", "/r/.worktrees/x"], code: 128, stderr: "fatal: not a working tree").refusedForUnsavedWork)
        #expect(!GitError(args: ["branch", "-d", "x"], code: 1, stderr: refusal).refusedForUnsavedWork)
    }

    /// A timeout is the runner's deadline, which it says in a flag of its own: a remote's error that
    /// happens to read "timed out after" — curl's — is a failure git answered with, not a stall.
    @Test func onlyTheRunnersDeadlineIsATimeout() {
        let curl = "fatal: unable to access 'https://example.com/a.git/': Connection timed out after 10001 milliseconds"
        #expect(!GitError(args: ["fetch"], code: 128, stderr: curl).timedOut)
    }
}
