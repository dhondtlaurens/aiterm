import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct TaskWorkflowTests {
    @Test func removalRetainsUnmergedBranchAndRetryOnlyDeletesBranch() async throws {
        let (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        let git = GitRunner.hermetic(), workflow = TaskWorkflow(git: .hermetic())
        let created = try await workflow.create(draft: draft, project: project)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "work"], in: created.task.worktreePath)
        let result = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: true)
        // The one refusal AiTerm can put in its own words: commits the base lacks.
        #expect(result.branchRefusal == .notMerged(base: "main"))
        #expect(!FileManager.default.fileExists(atPath: created.task.worktreePath))
        #expect(try git.run(["rev-parse", "--verify", draft.branch], in: project.path).isEmpty == false)
        try git.run(["merge", "--ff-only", draft.branch], in: project.path)
        let retried = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: false)
        #expect(retried.branchRefusal == nil)
        let again = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: false)
        #expect(again.branchRefusal == nil)
    }

    /// The command is built from the finished checkout, after the task exists: what it carries is
    /// the worktree's own `.aiterm` prompt file, and a command that could not be built would be a
    /// launch warning on a task that is still created.
    @Test func creatingATaskBuildsItsCommandFromTheFinishedCheckout() async throws {
        var (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        draft.promptText = "line one\tTabbed, so it is read from a file"
        let created = try await TaskWorkflow(git: .hermetic()).create(draft: draft, project: project)
        #expect(created.launchWarning == nil)
        #expect(created.command?.contains(".aiterm/first-prompt.md") == true)
        #expect(FileManager.default.fileExists(atPath: created.task.worktreePath + "/.aiterm/first-prompt.md"))
    }

    /// Every git command of a creation and a removal goes through the runner the workflow was given:
    /// the checkout, the agent command's `.aiterm/` exclusion, the unlock and the branch deletion.
    @Test func aWorkflowRunsTheGitItWasGiven() async throws {
        var (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        draft.promptText = "line one\tTabbed, so it is read from a file"
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        let workflow = TaskWorkflow(git: recording)
        let created = try await workflow.create(draft: draft, project: project)
        let creation = recording.calls.map(\.args)
        #expect(creation.contains { $0.contains("add") && $0.contains("worktree") })
        #expect(creation.contains { $0.contains("--git-path") })
        #expect(try await workflow.hasUnsavedWork(task: created.task, project: project) == false)
        _ = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: false)
        let all = recording.calls.map(\.args)
        #expect(all.count > creation.count)
        #expect(all.contains { $0.starts(with: ["worktree", "remove"]) || $0.contains("remove") })
        #expect(all.contains { $0.starts(with: ["branch"]) })
    }

    @Test func refusedRemovalPreservesCheckoutAndLock() async throws {
        let (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        let workflow = TaskWorkflow(git: .hermetic()), git = GitRunner.hermetic()
        let created = try await workflow.create(draft: draft, project: project)
        let file = created.task.worktreePath + "/important.txt"
        try "work in progress".write(toFile: file, atomically: true, encoding: .utf8)
        do {
            _ = try await workflow.remove(task: created.task, project: project, deleteBranch: false, force: false)
            Issue.record("dirty checkout must be refused")
        } catch is GitError { }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "work in progress")
        #expect(try git.run(["worktree", "list", "--porcelain"], in: project.path).contains("locked aiterm task"))
    }

    /// A Remove git gave up on halfway left the task's folder behind, holding build output a
    /// process wrote back, with git's record of the worktree gone. Every Remove after it failed
    /// "is not a working tree", so the task could never go.
    @Test func removalFinishesATaskWhoseWorktreeGitHalfRemoved() async throws {
        let (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        let git = GitRunner.hermetic(), workflow = TaskWorkflow(git: .hermetic())
        let created = try await workflow.create(draft: draft, project: project)
        let path = created.task.worktreePath
        try git.run(["worktree", "unlock", path], in: project.path)
        try git.run(["worktree", "remove", path], in: project.path)
        try FileManager.default.createDirectory(atPath: path + "/app/node_modules/.cache", withIntermediateDirectories: true)

        let result = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: false)

        #expect(result.branchRefusal == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + draft.branch], in: project.path).isEmpty)
    }

    /// The project's checkout is rarely sitting on the base branch — users often keep another task's
    /// branch checked out there. `git branch -d` judges "merged" against HEAD and the branch's
    /// upstream only, so a branch already merged into its base was refused with "not fully merged".
    @Test func removalDeletesABranchMergedIntoItsBaseWhileAnotherBranchIsCheckedOut() async throws {
        let (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        let git = GitRunner.hermetic(), workflow = TaskWorkflow(git: .hermetic())
        let created = try await workflow.create(draft: draft, project: project)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "work"], in: created.task.worktreePath)
        try git.run(["merge", "--ff-only", draft.branch], in: project.path)
        // A sibling branch that does not contain the merge: what the checkout looks like while
        // another task is in flight.
        try git.run(["checkout", "-q", "-b", "feat/elsewhere", "main~1"], in: project.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "elsewhere"], in: project.path)

        let result = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: false)

        #expect(result.branchRefusal == nil)
        #expect(try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + draft.branch], in: project.path).isEmpty)
    }

    /// The other half of the same change: deciding merged-ness against the base must not turn into
    /// an unconditional `branch -D`. Work that lives nowhere but its own branch is still kept.
    @Test func removalRetainsABranchMissingFromItsBaseWhileAnotherBranchIsCheckedOut() async throws {
        let (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        let git = GitRunner.hermetic(), workflow = TaskWorkflow(git: .hermetic())
        let created = try await workflow.create(draft: draft, project: project)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "work"], in: created.task.worktreePath)
        try git.run(["checkout", "-q", "-b", "feat/elsewhere"], in: project.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "elsewhere"], in: project.path)

        let result = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: true)

        #expect(result.branchRefusal == .notMerged(base: "main"))
        #expect(try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + draft.branch], in: project.path).isEmpty == false)
    }

    /// "Delete Branch…" on the banner, after the person agreed to lose the commits: `-D`, which
    /// `remove` never runs on a branch its base lacks.
    @Test func deletingAnUnmergedBranchDropsItsCommits() async throws {
        let (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        let git = GitRunner.hermetic(), workflow = TaskWorkflow(git: .hermetic())
        let created = try await workflow.create(draft: draft, project: project)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "work"], in: created.task.worktreePath)
        _ = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: true)

        try await workflow.deleteUnmergedBranch(of: created.task, in: project)

        #expect(try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/" + draft.branch], in: project.path).isEmpty)
    }

    /// A refusal that is not about merged-ness keeps git's reason, without git's `error:` prefix,
    /// as a sentence: here the branch is checked out in a worktree AiTerm does not own.
    @Test func aBranchCheckedOutElsewhereIsRefusedInGitsWords() async throws {
        let (project, draft) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: project.path) }
        let git = GitRunner.hermetic(), workflow = TaskWorkflow(git: .hermetic())
        let created = try await workflow.create(draft: draft, project: project)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "work"], in: created.task.worktreePath)
        try git.run(["merge", "--ff-only", draft.branch], in: project.path)
        _ = try await workflow.remove(task: created.task, project: project, deleteBranch: false, force: true)
        let elsewhere = project.path + "-elsewhere"
        defer { try? FileManager.default.removeItem(atPath: elsewhere) }
        try git.run(["worktree", "add", "-q", elsewhere, draft.branch], in: project.path)

        let result = try await workflow.remove(task: created.task, project: project, deleteBranch: true, force: false)

        guard case .other(let reason) = result.branchRefusal else {
            Issue.record("expected git's own refusal, got \(String(describing: result.branchRefusal))"); return
        }
        #expect(!reason.hasPrefix("error:"))
        #expect(reason.first?.isUppercase == true && reason.hasSuffix("."))
    }

    /// A review's local branch goes with it only when that loses nothing (`releaseReviewBranch`),
    /// whatever the caller asks: without an origin there is nothing to judge by, so it stays.
    @Test func testRemovingAReviewWithoutOriginKeepsItsBranch() async throws {
        let fixture = try ReviewRemovalFixture(withOrigin: false)
        defer { fixture.cleanUp() }
        let result = try await TaskWorkflow(git: .hermetic()).remove(task: fixture.review, project: fixture.project, deleteBranch: true, force: true)
        #expect(try fixture.hasLocalBranch())
        #expect(!FileManager.default.fileExists(atPath: fixture.review.worktreePath))
        #expect(result.branchRefusal == nil && result.keptBranch == nil)
    }

    /// Pushed, the local copy is deleted; unpushed fixes keep it, and the removal says so — as a
    /// note, not a warning: the review is gone either way, there is nothing to retry.
    @Test func testRemovingAReviewReleasesItsBranchOnlyWhenPushed() async throws {
        let pushed = try ReviewRemovalFixture(withOrigin: true)
        defer { pushed.cleanUp() }
        let clean = try await TaskWorkflow(git: .hermetic()).remove(task: pushed.review, project: pushed.project, deleteBranch: false, force: false)
        #expect(try !pushed.hasLocalBranch())
        #expect(clean.branchRefusal == nil && clean.keptBranch == nil)

        let unpushed = try ReviewRemovalFixture(withOrigin: true)
        defer { unpushed.cleanUp() }
        try unpushed.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-q", "-m", "fix"], in: unpushed.review.worktreePath)
        let kept = try await TaskWorkflow(git: .hermetic()).remove(task: unpushed.review, project: unpushed.project, deleteBranch: true, force: false)
        #expect(try unpushed.hasLocalBranch())
        #expect(kept.branchRefusal == nil)
        #expect(kept.keptBranch == "Branch feat/mr-branch kept: 1 commit not on origin.")
    }

    private func fixture() throws -> (Project, TaskDraft) {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let git = GitRunner.hermetic()
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], in: repo)
        let project = Project(id: UUID(), name: "Repo", path: repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("Migration")
        return (project, draft)
    }
}

/// A repo with a merge request's branch already checked out into a worktree — the shape
/// `TaskWorkflow.remove` sees for a review — built the same way `TaskWorkflowTests.fixture()`
/// builds a task's repo, plus the branch and the `Worktrees.checkout` worktree a review needs.
/// With an origin, the branch is pushed there and exists locally only as the review's checkout.
private struct ReviewRemovalFixture {
    let git = GitRunner.hermetic()
    let root: String
    let project: Project
    let review: TaskItem

    init(withOrigin: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "init"], in: repo)
        try git.run(["branch", "feat/mr-branch"], in: repo)
        if withOrigin {
            try git.run(["init", "-q", "--bare", root + "/remote.git"], in: root)
            try git.run(["remote", "add", "origin", root + "/remote.git"], in: repo)
            try git.run(["push", "-q", "origin", "main", "feat/mr-branch"], in: repo)
            try git.run(["branch", "-q", "-D", "feat/mr-branch"], in: repo)
        }
        let path = try Worktrees.checkout(repo: repo, slug: "review-mr-branch", branch: "feat/mr-branch", git: git)
        project = Project(id: UUID(), name: "Repo", path: repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        review = TaskItem(id: UUID(), projectId: project.id, title: "Add gift card", branch: "feat/mr-branch", worktreePath: path,
                          baseBranch: "main", jira: nil, kind: .review, mr: nil, agent: .claude, model: "sonnet", reasoning: nil,
                          firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: nil)
    }

    func hasLocalBranch() throws -> Bool {
        try git.run(["for-each-ref", "--format=%(refname)", "refs/heads/feat/mr-branch"], in: project.path).isEmpty == false
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
}
