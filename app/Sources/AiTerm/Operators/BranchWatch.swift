import Foundation
import AiTermCore

/// Watches that each worker commits on its task branch (`BranchDrift`), on every reconcile tick: the
/// worktree's HEAD is read, and once a worker tab (`WorkerTab`) is idle at its prompt or done, the SHAs its
/// last message names are looked up in the repository. What it finds is kept on the task, shown in `run_status`, and
/// a newly found drift wakes the Operator once: `[AiTerm] PAY-2 committed off its task branch, call
/// run_status`. A task taken over, not at work, or in an operation paused or ended, is not read.
@MainActor
final class BranchWatch {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    private let waker: OperatorWaker
    private var polling: Task<Void, Never>?
    /// The latest pass, for a test to await.
    private(set) var lastPoll: Task<Void, Never>?

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, waker: OperatorWaker) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.waker = waker
    }

    private var state: AppState { workspace.state }

    /// Whether `task` is read now: working, or fixing its review, in its own worktree, still the Operator's,
    /// in an operation that runs and that you have neither paused nor ended.
    func isWatched(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, [.working, .inReview].contains(operated.state), !operated.takenOver,
              task.hasCheckout, let run = state.run(id: operated.runId), run.intent == nil else { return false }
        return run.state == .active || run.state == .complete
    }

    /// One pass over every watched task, unless the last is still reading.
    func poll() {
        guard polling == nil else { return }
        let ids = state.tasks.filter(isWatched).map(\.id)
        guard !ids.isEmpty else { return }
        let pass = Task { [weak self] in
            for id in ids { await self?.check(id) }
            self?.polling = nil
        }
        polling = pass
        lastPoll = pass
    }

    private func check(_ id: UUID) async {
        guard let task = state.task(id: id), isWatched(task), let operated = task.operated else { return }
        // A tab's last message is its final word only once its turn ended. The first worker's conversation is known
        // from its window's tabs too; an extra tab's only from its own.
        let conversations: [(agent: AgentKind, id: String)] = task.workerTabs(in: live.sessions).compactMap { tab in
            guard let session = tab.session, session.state == .idle || session.state == .done,
                  let conversation = session.conversationId
                    ?? (tab.key == nil ? task.conversations.first(where: { $0.agent == task.agent })?.id : nil) else { return nil }
            return (tab.agent, conversation)
        }
        let git = ports.git, home = ports.home, worktree = task.worktreePath, branch = task.branch
        let reading = await BackgroundWork.run {
            (head: Self.head(in: worktree, git: git),
             named: conversations.isEmpty ? nil : conversations.flatMap { conversation in
                 WorkerTranscript.lastMessage(agent: conversation.agent, conversation: conversation.id, home: home)
                     .map { Self.named(in: $0, branch: branch, worktree: worktree, git: git) } ?? []
             })
        }
        // Read fresh: git was asked meanwhile.
        guard let current = state.task(id: id), isWatched(current), current.worktreePath == worktree, current.branch == branch,
              let fresh = current.operated, fresh.ownership == operated.ownership else { return }
        let found = BranchDrift.find(taskBranch: branch, head: reading.head, named: reading.named, previous: fresh.branchDrift)
        guard found != fresh.branchDrift else { return }
        workspace.mutate { $0.updateOperated(id) { $0.branchDrift = found } }
        if found != nil, fresh.branchDrift == nil { waker.say("\(fresh.key) committed off its task branch", to: fresh.runId) }
    }

    /// The worktree's HEAD: its branch, nil when detached, and its commit. Nil when git can't read it, and
    /// while a rebase runs there: it detaches HEAD until it ends, back on the branch it started from.
    nonisolated static func head(in worktree: String, git: any GitRunning) -> BranchDrift.Head? {
        guard let sha = try? git.run(["rev-parse", "HEAD"], in: worktree),
              case .answered(let branch) = ask(["symbolic-ref", "--quiet", "--short", "HEAD"], in: worktree, none: [1], git: git)
        else { return nil }
        if branch == nil, rebasing(worktree, git: git) { return nil }
        return BranchDrift.Head(branch: branch, sha: sha)
    }

    /// Whether a rebase is under way in the worktree: its own git folder holds git's rebase state.
    nonisolated private static func rebasing(_ worktree: String, git: any GitRunning) -> Bool {
        ["rebase-merge", "rebase-apply"].contains { name in
            guard let path = try? git.run(["rev-parse", "--path-format=absolute", "--git-path", name], in: worktree) else { return true }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    /// The SHAs `message` names, each looked up: the commit it is, whether `branch` holds it, and which other
    /// branches do. One git couldn't answer for is left out: nothing is said of it.
    nonisolated static func named(in message: String, branch: String, worktree: String, git: any GitRunning) -> [BranchDrift.Named] {
        BranchDrift.shaCandidates(in: message).compactMap { text in
            guard case .answered(let found) = ask(["rev-parse", "--verify", "--quiet", text + "^{commit}"], in: worktree, none: [1, 128], git: git)
            else { return nil }
            guard let commit = found else {
                // Digits alone that name no commit are a number, not a SHA from elsewhere.
                return BranchDrift.isNumber(text) ? nil : BranchDrift.Named(text: text, commit: nil, onTaskBranch: false)
            }
            guard case .answered(let held) = ask(["merge-base", "--is-ancestor", commit, "refs/heads/" + branch], in: worktree, none: [1], git: git),
                  let listed = try? git.run(["for-each-ref", "--contains", commit, "--format=%(refname:short)", "refs/heads"], in: worktree)
            else { return nil }
            let branches = listed.split(separator: "\n").map(String.init).filter { $0 != branch }
            return BranchDrift.Named(text: text, commit: commit, onTaskBranch: held != nil, branches: branches)
        }
    }

    /// `GitRunning.ask`, with git's "no" (nil) told apart from a failure that says nothing.
    private enum Answer { case answered(String?), failed }
    nonisolated private static func ask(_ args: [String], in dir: String, none: Set<Int32>, git: any GitRunning) -> Answer {
        do { return .answered(try git.ask(args, in: dir, none: none)) } catch { return .failed }
    }
}
