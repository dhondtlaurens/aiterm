import Foundation
import Testing
@testable import AiTermCore

/// The banner's value on its own: its words, its ways out, and when it has gone stale. What the
/// app does with one — which report wins the banner, what its actions run — is in AiTermTests.
@Suite struct OperationIssueTests {
    /// The refusal AiTerm has words for: commits the base lacks, which `-D` answers, so Delete is
    /// offered beside Keep.
    @Test func aBranchWithCommitsItsBaseLacksOffersKeepAndDelete() {
        let id = UUID()
        #expect(OperationIssue.branchKept("feat/work", of: id, because: .notMerged(base: "main"))
                == OperationIssue(title: "Branch feat/work kept.", reason: "It has commits that aren’t on main.",
                                  actions: [.keepBranch(id), .deleteBranch(id)], subject: id))
        #expect(OperationIssue.branchKept("feat/work", of: id, because: .notMerged(base: "")).reason
                == "It has commits that aren’t on its base.")
    }

    /// A refusal AiTerm has no words of its own for keeps git's, and offers only Keep Branch: `-D`
    /// would not answer it.
    @Test func anyOtherRefusalKeepsGitsReasonAndOffersOnlyKeep() {
        let id = UUID()
        let issue = OperationIssue.branchKept("feat/work", of: id, because: .other(reason: "Cannot delete branch 'feat/work'."))
        #expect(issue == OperationIssue(title: "Branch feat/work kept.", reason: "Cannot delete branch 'feat/work'.",
                                        actions: [.keepBranch(id)], subject: id))
    }

    /// A failure's own words go in the title and the error's in the reason, never joined: git's by
    /// its sentence rule, the helper's by its code, anything else by its description.
    @Test func anErrorIsTheReasonNotPartOfTheTitle() {
        let daemon = OperationIssue(title: "Couldn’t reopen the window.",
                                    error: DaemonError(code: .itermUnavailable, message: "iTerm2 is not connected (RPC: activate)"))
        #expect(daemon == OperationIssue(title: "Couldn’t reopen the window.", reason: "iTerm2 isn’t connected."))
        let git = GitError(args: ["worktree", "remove"], code: 128, stderr: "fatal: not a working tree")
        #expect(OperationIssue(title: "Couldn’t remove the task.", error: git).reason == "Not a working tree.")
    }

    /// An issue is stale once the task it is about, or the task or project an action would act on,
    /// has left the workspace; one that names nothing never is.
    @Test func anIssueIsStaleOnceWhatItNamesHasGone() {
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                              addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "t", branch: "b", worktreePath: "/w", baseBranch: "main",
                            jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(timeIntervalSince1970: 0), windowId: nil)
        var state = AppState.empty
        state.append(project: project)
        state.tasks = [task]
        let issues = [OperationIssue(title: "About the task.", subject: task.id),
                      OperationIssue(title: "Keep it?", actions: [.keepBranch(task.id)]),
                      OperationIssue(title: "Delete it?", actions: [.deleteBranch(task.id)]),
                      OperationIssue(title: "Rebase?", actions: [.rebaseDefault(project.id)])]

        #expect(issues.allSatisfy { !$0.isStale(in: state) })
        #expect(!OperationIssue(title: "About nothing.").isStale(in: .empty))
        var withoutTask = state
        withoutTask.tasks = []
        #expect(issues.map { $0.isStale(in: withoutTask) } == [true, true, true, false])
        var withoutProject = state
        withoutProject.removeItem(id: project.id)
        #expect(issues.map { $0.isStale(in: withoutProject) } == [false, false, false, true])
    }

    /// A pull that found the branches diverged offers the rebase; any other failure is reported
    /// with its error and no way out.
    @Test func onlyADivergedPullOffersTheRebase() {
        let project = UUID()
        let diverged = OperationIssue.pullRefused(WorktreeError.branchDiverged("main", local: 1, remote: 2), in: project)
        #expect(diverged.title == "Couldn’t pull the default branch.")
        #expect(diverged.actions == [.rebaseDefault(project)])
        #expect(diverged.reason?.hasSuffix(" Rebase puts yours on top of origin’s; nothing is pushed.") == true)
        let other = OperationIssue.pullRefused(GitError(args: ["fetch"], code: 128, stderr: "fatal: unable to access 'origin'"), in: project)
        #expect(other == OperationIssue(title: "Couldn’t pull the default branch.", reason: "Unable to access 'origin'."))
    }
}
