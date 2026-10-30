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
    /// has not seen a change yet. The root is resolved with `realpath(3)`: git reports the physical
    /// path of a repository under `/var/folders`, and adding the unresolved one adds it as "the
    /// repository around" that path.
    init(prompter: ScriptedPrompter? = nil, activateIterm: @escaping @MainActor () -> Void = {},
         bringForward: @escaping @MainActor () -> Void = {}, launchIterm: @escaping @MainActor () -> Void = {},
         itermRunning: @escaping @MainActor () -> Bool = { true },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, scan: CheckoutMonitor.Scanner? = nil,
         checkoutPollInterval: Duration = .seconds(2),
         confirmsRemoval: @escaping TaskRemover.ConfirmsRemoval = TaskRemover.diskConfirmsRemoval,
         provider: Provider = .git, remoteUrl: String? = nil) throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: realpath(raw, nil).map { defer { free($0) }; return String(cString: $0) } ?? raw)
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo.path)
        project = Project(id: UUID(), name: "Repo", path: repo.path, provider: provider,
                          remoteUrl: remoteUrl, addedAt: Date(), collapsed: false)
        let prompter = prompter ?? ScriptedPrompter()
        self.prompter = prompter
        controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(), prompter: prompter,
                                   activateIterm: activateIterm, launchIterm: launchIterm, itermRunning: itermRunning,
                                   bringForward: bringForward, checkoutPollInterval: checkoutPollInterval, now: now,
                                   scan: scan ?? {
                                       WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5,
                                                         defaultBranches: $6)
                                   }, confirmsRemoval: confirmsRemoval)
        try controller.workspace.load()
        controller.workspace.mutate { $0.items = [.project(project)] }
        #expect(controller.workspace.flush())
    }

    /// A task with a real worktree, saved.
    func addTask(windowId: String?) throws -> TaskItem {
        let checkout = repo.appendingPathComponent(".worktrees/work").path
        try git.run(["worktree", "add", "-q", "-b", "feat/work", checkout], in: repo.path)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: checkout, baseBranch: "main", jira: nil, agent: .codex,
                            model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(timeIntervalSince1970: 0), windowId: windowId)
        controller.workspace.mutate { $0.tasks.append(task) }
        #expect(controller.workspace.flush())
        return task
    }

    /// A connected snapshot with one tab tagged with `task`, in window `windowId`.
    func snapshot(tagging task: TaskItem, in windowId: String) -> DaemonSnapshot {
        DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            SessionInfo(sessionId: "s", windowId: windowId, tabIndex: 0, taskId: task.id.uuidString, projectId: nil,
                        agent: .shell, model: nil, state: .idle, title: "", cwd: task.worktreePath),
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
    static func diverged() throws -> RaceFixture {
        let fixture = try RaceFixture()
        let remote = fixture.root.appendingPathComponent("remote.git").path, other = fixture.root.appendingPathComponent("other").path
        let repo = fixture.repo.path
        try fixture.git.run(["init", "-q", "--bare", "-b", "main", remote], in: fixture.root.path)
        try fixture.git.run(["remote", "add", "origin", remote], in: repo)
        try fixture.git.run(["push", "-q", "origin", "main"], in: repo)
        try fixture.git.run(["clone", "-q", remote, other], in: fixture.root.path)
        for (dir, message) in [(other, "upstream"), (repo, "local")] {
            try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message], in: dir)
        }
        try fixture.git.run(["push", "-q", "origin", "main"], in: other)
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
         confirmsRemoval: @escaping TaskRemover.ConfirmsRemoval = TaskRemover.diskConfirmsRemoval, provider: Provider = .git) throws {
        fixture = try RaceFixture(prompter: prompter, checkoutPollInterval: pollInterval, confirmsRemoval: confirmsRemoval, provider: provider)
        task = try fixture.addTask(windowId: windowOpen ? "alive" : nil)
    }

    func cleanUp() { fixture.cleanUp() }
}
