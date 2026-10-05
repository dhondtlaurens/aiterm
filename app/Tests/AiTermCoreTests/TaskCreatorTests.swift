import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct TaskCreatorTests {
    let git = GitRunner.hermetic()
    let defaults = ScratchDefaults.make()
    var repo: String
    var project: Project

    /// See `WorktreesTests.realPath`: POSIX `realpath(3)` matches what git reports, while
    /// Foundation's `URL.resolvingSymlinksInPath()` normalizes `/private/var/...` back to
    /// `/var/...` and so can never agree with git's output for a temp-directory repo.
    private static func realPath(_ path: String) -> String {
        guard let cResolved = realpath(path, nil) else { return path }
        defer { free(cResolved) }
        return String(cString: cResolved)
    }

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        repo = Self.realPath(raw)
        try git.run(["init", "-q", "-b", "main"], in: repo)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        project = Project(id: UUID(), name: "repo", path: repo, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
    }

    /// A home with no agent configuration in it, so the draft's model comes from the catalogue's
    /// documented fallback rather than from whichever CLIs the machine running the tests has.
    var bareHome: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func testDraftFollowsTicketUntilEdited() {
        var state = AppState.empty; state.lastAgentByProject[project.id] = .codex; state.lastModelByAgent[.codex] = "gpt-5.6"
        var d = TaskDraft.initial(project: project, state: state, git: git, home: bareHome, defaults: defaults)
        #expect(d.agent == .codex); #expect(d.model == "gpt-5.6"); #expect(d.baseBranch == "main")
        d.apply(ticket: JiraTicket(key: "WEB-5447", summary: "Add graceful SIGTERM", description: nil, issueType: "Task", status: nil, url: "u"))
        #expect(d.title == "Add graceful SIGTERM"); #expect(d.branch == "feat/web-5447-add-graceful-sigterm")
        d.setBranch("feat/custom")
        d.apply(ticket: JiraTicket(key: "SHOP-1", summary: "Other", description: nil, issueType: "Bug", status: nil, url: "u"))
        #expect(d.title == "Other", "title still follows"); #expect(d.branch == "feat/custom", "edited branch is kept")
    }

    /// SwiftUI hands a `TextField`'s value back through its binding when editing begins and ends,
    /// not only when the text changes — so `setBranch` and `setTitle` are called with what they
    /// already hold merely because the user clicked another field. A write of the same value must
    /// not count as an edit, or the branch stops following the task name after a stray click.
    @Test func testAWriteOfTheSameValueIsNotAnEdit() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.setTitle("First name")
        #expect(d.branch == "feat/first-name")
        d.setBranch(d.branch)
        d.setTitle(d.title)
        d.setTitle("Second Name Here")
        #expect(d.title == "Second Name Here")
        #expect(d.branch == "feat/second-name-here", "the branch still follows the task name")
    }

    /// The branch type follows the ticket's issue type, like the task name does, until it is picked
    /// by hand; then a new ticket leaves it alone.
    @Test func testTheBranchTypeFollowsTheTicketUntilPicked() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        #expect(d.branchType == .feat)
        d.apply(ticket: JiraTicket(key: "SHOP-12", summary: "Broken link", description: nil, issueType: "Bug", status: nil, url: "u"))
        #expect(d.branchType == .fix); #expect(d.branch == "fix/shop-12-broken-link")
        d.apply(ticket: JiraTicket(key: "SHOP-13", summary: "Tidy", description: nil, issueType: "Task", status: nil, url: "u"))
        #expect(d.branchType == .feat, "still following")
        d.setBranchType(.chore)
        d.apply(ticket: JiraTicket(key: "SHOP-14", summary: "Crash", description: nil, issueType: "Bug", status: nil, url: "u"))
        #expect(d.branch == "chore/shop-14-crash", "a picked type survives a new ticket")
        d.apply(ticket: nil)
        #expect(d.branchType == .chore)
    }

    /// The type and the name are separate edits: a hand-typed name still takes a new type, and the
    /// name the field shows is the part after the type.
    @Test func testAnEditedNameStillTakesANewType() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.setBranch("my-own-name")
        #expect(d.branchName == "my-own-name"); #expect(d.branch == "feat/my-own-name")
        d.setBranchType(.chore)
        #expect(d.branch == "chore/my-own-name")
        d.setTitle("Something else")
        #expect(d.branch == "chore/my-own-name", "the edited name is kept")
    }

    /// Typing or pasting a whole branch with a known type moves the type into the select; an
    /// unknown prefix is part of the name.
    @Test func testATypedPrefixMovesIntoTheType() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.setBranch("fix/shop-12-broken-link")
        #expect(d.branchType == .fix); #expect(d.branchName == "shop-12-broken-link")
        d.apply(ticket: JiraTicket(key: "SHOP-1", summary: "Story", description: nil, issueType: "Story", status: nil, url: "u"))
        #expect(d.branch == "fix/shop-12-broken-link", "a typed type counts as picked")
        d.setBranch("release/x")
        #expect(d.branch == "fix/release/x")
    }

    /// The branch a typed task name produces is that name lowercased, with everything that is not a
    /// letter or a digit collapsed to a single dash.
    @Test func testATypedTaskNameLowercasesAndDashesIntoTheBranch() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.setTitle("Fix the JIRA select  (again!)")
        #expect(d.branch == "feat/fix-the-jira-select-again")
    }

    /// Before anything is typed the sheet previews no worktree directory — not the type alone, which
    /// is what slugging the bare `feat/` would give.
    @Test func testAnEmptyBranchNamePreviewsNoWorktreeDirectory() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        #expect(d.worktreeSlug == "")
        d.setTitle("Broken link")
        #expect(d.worktreeSlug == "broken-link")
        d.setBranch("")
        #expect(d.worktreeSlug == "")
    }

    /// A model remembered from a previous run that the CLI no longer lists must not reach the
    /// command line: the draft falls back to a model the CLI does list.
    @Test func testDraftDropsARememberedModelTheCliNoLongerLists() {
        var state = AppState.empty
        state.lastAgentByProject[project.id] = .codex
        state.lastModelByAgent[.codex] = "gpt-4-retired"
        let d = TaskDraft.initial(project: project, state: state, git: git, home: bareHome, defaults: defaults)
        #expect(d.model == "gpt-5.6")
    }

    /// Reasoning follows the model: a level the new model does not publish is replaced by its own
    /// default instead of being passed through.
    @Test func testSetModelKeepsASupportedEffortAndReplacesAnUnsupportedOne() {
        var state = AppState.empty; state.lastAgentByProject[project.id] = .codex
        var d = TaskDraft.initial(project: project, state: state, git: git, home: bareHome, defaults: defaults)
        let catalog = [AgentModel(id: "a", label: "A", detail: nil, efforts: ["low", "high"], defaultEffort: "high"),
                       AgentModel(id: "b", label: "B", detail: nil, efforts: ["max"], defaultEffort: "max")]
        d.reasoning = "low"
        d.setModel("a", catalog: catalog)
        #expect(d.reasoning == "low", "a level the model supports is kept")
        d.setModel("b", catalog: catalog)
        #expect(d.reasoning == "max", "a level it does not support becomes the model's default")
    }

    @Test func testProviderDefaultsApplyAcrossProjectsAndWhenSwitchingAgents() {
        let defaults = ScratchDefaults.make()
        let home = bareHome
        defer { try? FileManager.default.removeItem(at: home) }
        ModelSettings.save(ModelPreference(model: "sonnet", reasoning: "low"), for: .claude, defaults: defaults)
        ModelSettings.save(ModelPreference(model: "gpt-5.6", reasoning: "xhigh"), for: .codex, defaults: defaults)
        var state = AppState.empty
        state.lastModelByAgent[.claude] = "opus"
        var draft = TaskDraft.initial(project: project, state: state, git: git, home: home, defaults: defaults)
        #expect(draft.model == "sonnet")
        #expect(draft.reasoning == "low")
        var anotherProject = project
        anotherProject.id = UUID()
        let another = TaskDraft.initial(project: anotherProject, state: state, git: git, home: home, defaults: defaults)
        #expect(another.model == "sonnet")
        #expect(another.reasoning == "low")
        draft.setAgent(.codex, state: state, home: home, defaults: defaults)
        #expect(draft.model == "gpt-5.6")
        #expect(draft.reasoning == "xhigh")
        draft.reasoning = "medium"
        draft.setAgent(.claude, state: state, home: home, defaults: defaults)
        #expect(draft.model == "sonnet")
        #expect(draft.reasoning == "low")
        draft.setModel("opus", catalog: ModelCatalog.models(for: .claude, home: home))
        #expect(ModelSettings.load(for: .claude, defaults: defaults)?.model == "sonnet")
    }

    @Test func testCreateBuildsWorktreeAndTaskItem() throws {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.apply(ticket: JiraTicket(key: "WEB-1", summary: "Thing", description: "Do it", issueType: "Task", status: nil, url: "https://x/browse/WEB-1"))
        d.promptText = "/plan"
        let task = try TaskCreator.create(draft: d, project: project, git: .hermetic())
        #expect(task.worktreePath == repo + "/.worktrees/web-1-thing")
        #expect(task.branch == "feat/web-1-thing"); #expect(task.jira?.key == "WEB-1"); #expect(task.title == "Thing")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/.git"))
        #expect(task.windowId == nil)
    }

    @Test func testBranchWithoutAsciiStillGetsItsOwnWorktreeDirectory() throws {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.setTitle("x"); d.setBranch("feat/日本語")
        let task = try TaskCreator.create(draft: d, project: project, git: .hermetic())
        let worktreesDir = repo + "/.worktrees/"
        #expect(task.worktreePath.hasPrefix(worktreesDir))
        #expect(task.worktreePath.count > worktreesDir.count, "the slug must never be empty: \(task.worktreePath)")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/.git"))
    }

    /// The directory drops the branch's type, so `feat/login` and `fix/login` both wanted
    /// `.worktrees/login` and the second create failed in `git worktree add`.
    @Test func testBranchesThatDifferOnlyInTypeGetTheirOwnWorktrees() throws {
        var paths: [String] = []
        for type in ["feat", "fix", "chore"] {
            var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
            d.setTitle("Login"); d.setBranch("\(type)/login")
            paths.append(try TaskCreator.create(draft: d, project: project, git: .hermetic()).worktreePath)
        }
        #expect(paths == ["login", "login-2", "login-3"].map { repo + "/.worktrees/" + $0 })
    }

    /// The rule create and the sheet's preview share.
    @Test func anUnusedSlugSkipsEveryDirectoryAlreadyThere() throws {
        #expect(TaskCreator.unused("login", in: repo) == "login")
        for taken in ["login", "login-2"] {
            try FileManager.default.createDirectory(atPath: repo + "/.worktrees/" + taken, withIntermediateDirectories: true)
        }
        #expect(TaskCreator.unused("login", in: repo) == "login-3")
    }

    // -- reviews ---------------------------------------------------------------------

    private static let mergeRequest = MergeRequest(iid: 4, title: "Add gift card", sourceBranch: "feat/mr-branch",
                                                   targetBranch: "develop", author: "sam", state: "opened", draft: false,
                                                   url: "https://gitlab/x/-/merge_requests/4")

    /// `kind: .review` is stamped in exactly one place in the whole app, and every guarantee about
    /// never deleting a merge request's branch turns on it — `TaskWorkflow.remove`'s chokepoint,
    /// the missing delete-branch checkbox, the import. Delete that argument and nothing else fails.
    @Test func testCreateReviewStampsTheKindAndCarriesTheMergeRequest() throws {
        try git.run(["branch", "feat/mr-branch"], in: repo)
        var d = ReviewDraft.initial(project: project, state: .empty, home: bareHome, defaults: defaults)
        d.apply(mr: Self.mergeRequest)
        d.promptText = "/code-review"
        let task = try TaskCreator.createReview(draft: d, project: project, git: .hermetic())

        #expect(task.kind == .review, "a review must be recognisable as one; nothing else distinguishes it")
        #expect(task.worktreePath == repo + "/.worktrees/review-mr-branch")
        #expect(task.branch == "feat/mr-branch")
        #expect(task.title == "Add gift card")
        #expect(task.mr == MergeRequestRef(iid: 4, title: "Add gift card", url: "https://gitlab/x/-/merge_requests/4"))
        #expect(task.jira == nil, "a review has no ticket")
        #expect(task.appendTicket == false, "step 3 offers no include-details checkbox")
        #expect(task.baseBranch == "develop", "the merge request's target branch is what it lands on")
        #expect(task.firstPrompt == "/code-review")
        #expect(task.windowId == nil)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/.git"))
    }

    /// A review without a merge request is still a review: its branch is just as much someone
    /// else's, and `kind` — never `mr` — is what says so.
    @Test func testReviewsOfBranchesThatDifferOnlyInTypeGetTheirOwnWorktrees() throws {
        var paths: [String] = []
        for branch in ["feat/card", "fix/card"] {
            try git.run(["branch", branch], in: repo)
            var d = ReviewDraft.initial(project: project, state: .empty, home: bareHome, defaults: defaults)
            d.setTitle("Card"); d.setBranch(branch)
            paths.append(try TaskCreator.createReview(draft: d, project: project, git: .hermetic()).worktreePath)
        }
        #expect(paths == ["review-card", "review-card-2"].map { repo + "/.worktrees/" + $0 })
    }

    @Test func testCreateReviewWithoutAMergeRequestIsStillAReview() throws {
        try git.run(["branch", "feat/teammate-work"], in: repo)
        var d = ReviewDraft.initial(project: project, state: .empty, home: bareHome, defaults: defaults)
        d.setTitle("Look at Sam's branch")
        d.setBranch("feat/teammate-work")
        let task = try TaskCreator.createReview(draft: d, project: project, git: .hermetic())
        #expect(task.kind == .review)
        #expect(task.mr == nil)
        #expect(task.baseBranch == "", "no merge request means nothing to land on")
        #expect(task.firstPrompt == nil)
    }

    @Test func testCreateReviewRejectsAnEmptyOrInvalidBranchBeforeTouchingGit() throws {
        var d = ReviewDraft.initial(project: project, state: .empty, home: bareHome, defaults: defaults)
        d.setTitle("Review")
        let blank = #expect(throws: (any Error).self) { try TaskCreator.createReview(draft: d, project: project, git: .hermetic()) }
        #expect(blank as? TaskCreator.Failure == .invalidBranch(""))
        d.setBranch("bad..name")
        let bad = #expect(throws: (any Error).self) { try TaskCreator.createReview(draft: d, project: project, git: .hermetic()) }
        #expect(bad as? TaskCreator.Failure == .invalidBranch("bad..name"))
        d.setTitle("   ")
        #expect((#expect(throws: (any Error).self) { try TaskCreator.createReview(draft: d, project: project, git: .hermetic()) })
                as? TaskCreator.Failure == .emptyTitle)
    }

    @Test func testInvalidBranchIsRejectedBeforeTouchingGit() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.setTitle("x"); d.setBranch("bad..name")
        let e = #expect(throws: (any Error).self) { try TaskCreator.create(draft: d, project: project, git: .hermetic()) }
        #expect(e as? TaskCreator.Failure == .invalidBranch("feat/bad..name"))
    }

    @Test func testAnEmptyModelIsRejectedBeforeTouchingGit() {
        var d = TaskDraft.initial(project: project, state: .empty, git: git, home: bareHome, defaults: defaults)
        d.setTitle("No model")
        d.setModel("", catalog: [])
        let e = #expect(throws: (any Error).self) { try TaskCreator.create(draft: d, project: project, git: .hermetic()) }
        #expect(e as? TaskCreator.Failure == .emptyModel)
        #expect(!FileManager.default.fileExists(atPath: repo + "/.worktrees/no-model"))
    }
}
