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
        let diverged = OperationIssue.pullRefused(WorktreeError.branchDiverged("main", local: 1, remote: 2), in: project, projectPath: "/p")
        #expect(diverged.title == "Couldn’t pull the default branch.")
        #expect(diverged.actions == [.rebaseDefault(project)])
        #expect(diverged.reason?.hasSuffix(" Rebase puts yours on top of origin’s; nothing is pushed.") == true)
        let other = OperationIssue.pullRefused(GitError(args: ["fetch"], code: 128, stderr: "fatal: unable to access 'origin'"),
                                               in: project, projectPath: "/p")
        #expect(other == OperationIssue(title: "Couldn’t pull the default branch.", reason: "Unable to access 'origin'.",
                                        detail: "git fetch failed:\nfatal: unable to access 'origin'"))
    }

    @Test func aDivergedPullOffersRebaseAndAFix() {
        let id = UUID()
        let issue = OperationIssue.pullRefused(WorktreeError.branchDiverged("main", local: 1, remote: 3), in: id, projectPath: "/p")
        #expect(issue.actions == [.rebaseDefault(id)])
        #expect(issue.fix == FixRequest(title: "Couldn’t pull the default branch.", reason: issue.reason, detail: nil,
                                        projectPath: "/p", branch: "main", recreateRebase: false, retry: .pullDefault(id)))
    }

    /// The conflict's fix carries git's words; the sentence drops “Rebase it by hand.”, since the
    /// Fix is the way out now.
    @Test func aConflictedRebaseOfMainOffersTheFix() {
        let id = UUID()
        let issue = OperationIssue.rebaseRefused(WorktreeError.rebaseConflicted("main", detail: "CONFLICT x"), in: id, projectPath: "/p")
        #expect(issue.title == "Couldn’t rebase the default branch.")
        #expect(issue.fix?.recreateRebase == true && issue.fix?.detail == "CONFLICT x")
        #expect(issue.fix?.retry == .pullDefault(id) && issue.fix?.branch == "main" && issue.fix?.projectPath == "/p")
        #expect(issue.reason == "Rebasing “main” onto origin’s hit a conflict, so it was left as it was.")
        #expect(issue.reason?.contains("Rebase it by hand.") == false)
        #expect(issue.fix?.reason == issue.reason, "the agent is not told to rebase by hand either")
        #expect(issue.detail == "CONFLICT x")
    }

    /// Any other failure of the rebase is reported with its error, and offers no fix.
    @Test func anyOtherRebaseFailureOffersNoFix() {
        let issue = OperationIssue.rebaseRefused(GitError(args: ["rebase"], code: 1, stderr: "fatal: no"), in: UUID(), projectPath: "/p")
        #expect(issue.title == "Couldn’t rebase the default branch.")
        #expect(issue.fix == nil && issue.actions.isEmpty)
        #expect(issue.reason == "No.")
    }

    @Test func aPlainGitFailureOfAPullKeepsItsWordsAsDetailButOffersNoFix() {
        let error = GitError(args: ["pull"], code: 1, stderr: "fatal: unable to access", timedOut: false)
        let issue = OperationIssue.pullRefused(error, in: UUID(), projectPath: "/p")
        #expect(issue.detail?.contains("unable to access") == true)
        #expect(issue.fix == nil)
    }

    /// A fix that would pull a project the workspace no longer has is as stale as a Rebase for it.
    @Test func anIssueWhoseFixRetriesAGoneProjectIsStale() {
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                              addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        var state = AppState.empty
        state.append(project: project)
        let issue = OperationIssue.rebaseRefused(WorktreeError.rebaseConflicted("main", detail: nil), in: project.id, projectPath: "/repo")
        #expect(!issue.isStale(in: state))
        #expect(issue.isStale(in: .empty))
    }
}
