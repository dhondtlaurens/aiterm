import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A saved project in a real repository, a controller over it, and the prompter it asks.
@MainActor
struct RaceFixture {
    let root: URL
    let repo: URL
    let git = GitRunner.hermetic()
    let project: Project
    let prompter: ScriptedPrompter
    let controller: AppController

    /// `scan` replaces the checkout monitor's reading of the disk, for a test that needs a pass that
    /// has not seen a change yet. `controllerGit` is the git the controller runs, for a test that counts what it
    /// spawns; the fixture's own setup always runs `git`. The root is resolved with `realpath(3)`: git reports the physical
    /// path of a repository under `/var/folders`, and adding the unresolved one adds it as "the
    /// repository around" that path.
    init(prompter: ScriptedPrompter? = nil, activateIterm: @escaping @MainActor () -> Void = {},
         bringForward: @escaping @MainActor () -> Void = {}, launchIterm: @escaping @MainActor () -> Void = {},
         itermRunning: @escaping @MainActor () -> Bool = { true },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, scan: CheckoutMonitor.Scanner? = nil,
         checkoutPollInterval: Duration = .seconds(2),
         confirmsRemoval: @escaping TaskRemover.ConfirmsRemoval = TaskRemover.diskConfirmsRemoval,
         provider: Provider = .git, remoteUrl: String? = nil, controllerGit: (any GitRunning)? = nil,
         fixPipeline: (@MainActor (Project) -> FixPipeline)? = nil) async throws {
        root = try await BackgroundWork.run {
            let raw = try ScratchFolder.make("controller-").path
            return URL(fileURLWithPath: realpath(raw, nil).map { defer { free($0) }; return String(cString: $0) } ?? raw)
        }
        repo = root.appendingPathComponent("repo")
        let path = repo.path
        try await BackgroundWork.run { try GitFixture.initRepo(at: path) }
        project = .make(name: "Repo", path: repo.path, provider: provider, remoteUrl: remoteUrl, addedAt: Date())
        let prompter = prompter ?? ScriptedPrompter()
        self.prompter = prompter
        controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(), prompter: prompter,
                                   activateIterm: activateIterm, launchIterm: launchIterm, itermRunning: itermRunning,
                                   bringForward: bringForward, checkoutPollInterval: checkoutPollInterval, now: now,
                                   git: controllerGit ?? GitRunner.hermetic(), scan: scan ?? {
                                       WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5,
                                                         defaultBranches: $6)
                                   }, confirmsRemoval: confirmsRemoval, fixPipeline: fixPipeline)
        try controller.workspace.load()
        controller.workspace.mutate { $0.items = [.project(project)] }
        #expect(controller.workspace.flush())
    }

    /// A task with a real worktree, saved.
    func addTask(windowId: String?) async throws -> TaskItem {
        let checkout = repo.appendingPathComponent(".worktrees/work").path
        let git = git, path = repo.path
        try await BackgroundWork.run { try git.run(["worktree", "add", "-q", "-b", "feat/work", checkout], in: path) }
        let task = TaskItem.make(project: project.id, worktreePath: checkout, agent: .codex, model: "model", windowId: windowId)
        controller.workspace.mutate { $0.tasks.append(task) }
        #expect(controller.workspace.flush())
        return task
    }

    /// A connected snapshot with one tab tagged with `task`, in window `windowId`.
    func snapshot(tagging task: TaskItem, in windowId: String) -> DaemonSnapshot {
        DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            .make("s", window: windowId, task: task.id, agent: .shell, state: .idle, cwd: task.worktreePath),
        ], usage: .empty)
    }

    func draft(_ title: String) -> TaskDraft {
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle(title)
        return draft
    }

    func stateModified() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state.json").path)[.modificationDate] as? Date
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
    /// A repository whose `main` has one commit origin lacks while origin has one it lacks.
    static func diverged(fixPipeline: (@MainActor (Project) -> FixPipeline)? = nil) async throws -> RaceFixture {
        let fixture = try await RaceFixture(fixPipeline: fixPipeline)
        let remote = fixture.root.appendingPathComponent("remote.git").path, other = fixture.root.appendingPathComponent("other").path
        let repo = fixture.repo.path
        let git = fixture.git, root = fixture.root.path
        try await BackgroundWork.run {
            try git.run(["init", "-q", "--bare", "-b", "main", remote], in: root)
            try git.run(["remote", "add", "origin", remote], in: repo)
            try git.run(["push", "-q", "origin", "main"], in: repo)
            try git.run(["clone", "-q", remote, other], in: root)
            for (dir, message) in [(other, "upstream"), (repo, "local")] {
                try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message], in: dir)
            }
            try git.run(["push", "-q", "origin", "main"], in: other)
        }
        return fixture
    }
}

@MainActor
struct TaskFixture {
    private let fixture: RaceFixture
    var root: URL { fixture.root }
    var repo: URL { fixture.repo }
    var git: GitRunner { fixture.git }
    var project: Project { fixture.project }
    var controller: AppController { fixture.controller }
    let task: TaskItem

    init(windowOpen: Bool, prompter: ScriptedPrompter = ScriptedPrompter(), pollInterval: Duration = .seconds(2),
         confirmsRemoval: @escaping TaskRemover.ConfirmsRemoval = TaskRemover.diskConfirmsRemoval, provider: Provider = .git) async throws {
        fixture = try await RaceFixture(prompter: prompter, checkoutPollInterval: pollInterval, confirmsRemoval: confirmsRemoval, provider: provider)
        task = try await fixture.addTask(windowId: windowOpen ? "alive" : nil)
    }

    func cleanUp() { fixture.cleanUp() }
}
