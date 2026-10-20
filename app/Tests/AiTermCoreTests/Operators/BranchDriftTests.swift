import Testing
import Foundation
@testable import AiTermCore

/// A worker that committed off its task branch is found, from its worktree's HEAD or its last message.
@Suite struct BranchDriftTests {
    let head = BranchDrift.Head(branch: "feat/pluto-1", sha: "4f2a91c0ffee4f2a91c0ffee4f2a91c0ffee4f2a")

    @Test func aMessagesWordsThatReadAsAShaAreItsCandidates() {
        let message = """
            Committed 4f2a91c on feat/mine (full: 4f2a91c0ffee4f2a91c0ffee4f2a91c0ffee4f2a). Ran 1234567 tests,
            fixed the deadbeef badge, task 2f9c4b7e-5a1d-4c3b-9e8f-0a1b2c3d4e5f, color ABCDEF1, and 4f2a91c again.
            """
        #expect(BranchDrift.shaCandidates(in: message) == ["4f2a91c", "4f2a91c0ffee4f2a91c0ffee4f2a91c0ffee4f2a", "1234567"],
                "letters alone, uppercase and a UUID's pieces are not commits; a repeat is named once")
        #expect(BranchDrift.isNumber("1234567") && !BranchDrift.isNumber("4f2a91c"))
    }

    @Test func aWorktreeOnItsTaskBranchWithNothingNamedOffItHasNoDrift() {
        #expect(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: [], previous: nil) == nil)
        let on = BranchDrift.Named(text: "4f2a91c", commit: head.sha, onTaskBranch: true, branches: ["feat/pluto-1"])
        #expect(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: [on], previous: nil) == nil)
    }

    @Test func aHeadOnAnotherBranchOrDetachedIsDrift() throws {
        let other = BranchDrift.Head(branch: "fix/mine", sha: "b0b0b0b0b0")
        let moved = try #require(BranchDrift.find(taskBranch: "feat/pluto-1", head: other, named: nil, previous: nil))
        #expect(moved == BranchDrift(source: .head, branch: "fix/mine", sha: "b0b0b0b0b0",
                                     found: "Its worktree is on branch fix/mine, not on its task branch feat/pluto-1."))
        let loose = try #require(BranchDrift.find(taskBranch: "feat/pluto-1", head: BranchDrift.Head(branch: nil, sha: "b0b0b0b0b0"),
                                                  named: [], previous: nil))
        #expect(loose.branch == nil && loose.sha == "b0b0b0b0b0")
        #expect(loose.found == "Its worktree's HEAD is detached at b0b0b0b, off its task branch feat/pluto-1.")
    }

    @Test func aCommitTheLastMessageNamesOffTheTaskBranchIsDriftWithTheBranchItIsOn() throws {
        let off = BranchDrift.Named(text: "c0ffee1", commit: "c0ffee1c0ffee1", onTaskBranch: false, branches: ["feat/elsewhere"])
        let found = try #require(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: [off], previous: nil))
        #expect(found == BranchDrift(source: .lastMessage, branch: "feat/elsewhere", sha: "c0ffee1",
                                     found: "Its last message names c0ffee1, which isn't on its task branch feat/pluto-1: it is on feat/elsewhere."))
        let unknown = BranchDrift.Named(text: "abc1234", commit: nil, onTaskBranch: false)
        let elsewhere = try #require(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: [unknown], previous: nil))
        #expect(elsewhere.branch == nil && elsewhere.sha == "abc1234")
        #expect(elsewhere.found == "Its last message names abc1234, which isn't a commit in this repository, so not on its task branch feat/pluto-1.")
    }

    /// While the worker works its last message isn't read: what an earlier one showed is kept, a HEAD drift
    /// that righted itself is not, and a new reading decides again.
    @Test func aMessagesDriftIsKeptUntilTheNextMessageIsRead() throws {
        let off = BranchDrift.Named(text: "c0ffee1", commit: "c0ffee1c0ffee1", onTaskBranch: false)
        let fromMessage = try #require(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: [off], previous: nil))
        #expect(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: nil, previous: fromMessage) == fromMessage)
        #expect(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: [], previous: fromMessage) == nil)
        let fromHead = try #require(BranchDrift.find(taskBranch: "feat/pluto-1", head: BranchDrift.Head(branch: "x", sha: nil),
                                                     named: nil, previous: nil))
        #expect(BranchDrift.find(taskBranch: "feat/pluto-1", head: head, named: nil, previous: fromHead) == nil)
        #expect(BranchDrift.find(taskBranch: "feat/pluto-1", head: nil, named: nil, previous: fromMessage) == fromMessage,
                "a worktree git couldn't read says nothing")
        #expect(BranchDrift.find(taskBranch: "feat/pluto-1", head: nil, named: [], previous: fromHead) == fromHead)
    }
}
