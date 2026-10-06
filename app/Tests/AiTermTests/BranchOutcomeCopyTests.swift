import Testing
@testable import AiTerm
@testable import AiTermCore

/// The words the app gives what git work on a project's branches came to.
struct BranchOutcomeCopyTests {
    @Test func pullAndRebaseToasts() {
        #expect(DefaultBranchPull.upToDate("main").toast == "main is already up to date.")
        #expect(DefaultBranchPull.fastForwarded("main", commits: 1).toast == "main updated with 1 new commit.")
        #expect(DefaultBranchPull.fastForwarded("master", commits: 3).toast == "master updated with 3 new commits.")
        #expect(DefaultBranchPull.ahead("main", commits: 2).toast == "main is 2 commits ahead of origin, so there was nothing to pull.")
        #expect(DefaultBranchRebase(branch: "main", ahead: 1).toast == "main rebased onto origin: 1 commit ahead, not pushed.")
        #expect(DefaultBranchRebase(branch: "main", ahead: 0).toast == "main rebased onto origin: it now matches origin.")
    }

    @Test func aKeptReviewBranchSaysWhy() {
        let notes: [(ReviewBranchRelease.Kept, String)] = [
            (.unpushed(commits: 1), "Branch feat/x kept: 1 commit not on origin."),
            (.unpushed(commits: 2), "Branch feat/x kept: 2 commits not on origin."),
            (.checkedOut(at: "/r/.worktrees/x"), "Branch feat/x kept: checked out at /r/.worktrees/x."),
            (.originUnreachable("fatal: could not read from remote"), "Branch feat/x kept: couldn’t check origin (fatal: could not read from remote)."),
            (.originNotFetched, "Branch feat/x kept: couldn’t fetch origin’s feat/x to compare."),
            (.unmerged(target: "main"), "Branch feat/x kept: not on origin and not merged into main."),
            (.unmerged(target: ""), "Branch feat/x kept: not on origin and not merged into its target."),
            (.notDeleted("error: branch is locked"), "Branch feat/x kept: error: branch is locked."),
        ]
        for (kept, note) in notes { #expect(kept.note(branch: "feat/x") == note) }
    }
}
