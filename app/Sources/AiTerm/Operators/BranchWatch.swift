import Foundation
import AiTermCore

/// Watches that each worker commits on its task branch (`BranchDrift`), on every reconcile tick: the
/// worktree's HEAD is read, and once a worker tab (`WorkerTab`) is idle at its prompt or done, the SHAs its
/// last message names are looked up in the repository. A transcript is read again only once it was written
/// since it was last read (`WorkerTranscript.modified`): an idle tab's is the same 512 KB tail every tick
/// otherwise. What it finds is kept on the task, shown in `run_status`, and a newly found drift wakes the
/// Operator once: `[AiTerm] PAY-2 committed off its task branch, call run_status`. A task taken over, not
/// at work, or in a broadcast paused or ended, is not read. A changed task-branch head resets its
/// no-commit clock. The checked callback decides limits after each read, including one with no progress.
@MainActor
final class BranchWatch {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    private let waker: OperatorWaker
    private let transcripts: TranscriptLocator
    private let pass = TickPass()
    /// Each conversation's last message as last read, by conversation id, with when its transcript was written then.
    private var lastMessages: [String: Read] = [:]
    private struct Read: Sendable { let modified: Date, message: String? }
    /// The latest pass, for a test to await.
    var lastPoll: Task<Void, Never>? { pass.last }
    /// A fresh read finished, including one with no progress or an unreadable head.
    var checked: @MainActor (UUID) -> Void = { _ in }

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, waker: OperatorWaker, transcripts: TranscriptLocator) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.waker = waker
        self.transcripts = transcripts
    }

    private var state: AppState { workspace.state }

    /// Whether `task` is read now: working, or fixing its review, in its own worktree, still the Operator's,
    /// in a broadcast that runs and that you have neither paused nor ended.
    func isWatched(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, [.working, .inReview].contains(operated.state), !operated.takenOver,
              task.hasCheckout, let run = state.run(id: operated.runId), run.intent == nil else { return false }
        return run.state == .active || run.state == .complete
    }

    /// One pass over every watched task, unless the last is still reading.
    func poll() {
        let open = Set(live.sessions.compactMap(\.conversationId))
        lastMessages = lastMessages.filter { open.contains($0.key) }
        pass.run(state.tasks.filter(isWatched).map(\.id)) { [weak self] in await self?.check($0) }
    }

    func stop() { pass.cancel() }

    private func check(_ id: UUID) async {
        guard let task = state.task(id: id), isWatched(task), let operated = task.operated else { return }
        // A tab's last message is its final word only once its turn ended. The first worker's conversation is known
        // from its window's tabs too; an extra tab's from its own (`WorkerTab.conversation`).
        let conversations: [(agent: AgentKind, id: String)] = task.workerTabs(in: live.sessions).compactMap { tab in
            guard let session = tab.session, session.state.turnEnded,
                  let conversation = tab.conversation else { return nil }
            return (tab.agent, conversation)
        }
        let git = ports.git, transcripts = self.transcripts, known = lastMessages, worktree = task.worktreePath
        let branch = task.branch, base = task.baseBranch
        let reading = await BackgroundWork.run {
            var read: [String: Read] = [:]
            let named: [BranchDrift.Named]? = conversations.isEmpty ? nil : conversations.flatMap { conversation -> [BranchDrift.Named] in
                guard let file = transcripts.file(agent: conversation.agent, conversation: conversation.id) else { return [] }
                let modified = WorkerTranscript.modified(file), message: String?
                if let modified, let kept = known[conversation.id], kept.modified == modified {
                    message = kept.message
                } else {
                    message = WorkerTranscript.lastMessage(in: file, agent: conversation.agent)
                    if let modified { read[conversation.id] = Read(modified: modified, message: message) }
                }
                return message.map { Self.named(in: $0, branch: branch, base: base, worktree: worktree, git: git) } ?? []
            }
            return (head: Self.head(in: worktree, git: git), named: named, read: read)
        }
        guard !Task.isCancelled else { return }
        lastMessages.merge(reading.read) { _, new in new }
        // Read fresh: git was asked meanwhile.
        guard let current = state.task(id: id), isWatched(current), current.worktreePath == worktree, current.branch == branch,
              let fresh = current.operated, fresh.ownership == operated.ownership else { return }
        defer { checked(id) }
        let head = reading.head.flatMap { $0.branch == branch ? $0.sha : nil }
        let found = BranchDrift.find(taskBranch: branch, head: reading.head, named: reading.named, previous: fresh.branchDrift)
        guard (head != nil && head != fresh.runtimeHead) || found != fresh.branchDrift else { return }
        workspace.mutate { $0.updateOperated(id) {
            if let head, head != $0.runtimeHead {
                if $0.runtimeHead != nil { $0.runtimeUsed = 0 }
                $0.runtimeHead = head
            }
            $0.branchDrift = found
        } }
        if found != nil, fresh.branchDrift == nil { waker.say("one task committed off its task branch", to: fresh.runId) }
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

    /// The SHAs `message` names that are commits in the repository, each looked up: the commit it is, whether
    /// `branch` holds it, which other branches do, and for one it doesn't, whether `base` (none: the default branch) or
    /// the default branch holds it, here or on origin, and whether it is a merge of `branch` (`merges`). A hex
    /// string that is no commit here (a session id, a hash quoted as evidence) is left out, as is one git couldn't answer
    /// for: nothing is said of either.
    nonisolated static func named(in message: String, branch: String, base: String, worktree: String, git: any GitRunning) -> [BranchDrift.Named] {
        // The base branch and the default one, each as this clone has it and as origin's: asked once, and only for a
        // commit off the task branch.
        var baseRefs: [String]?
        var priorHeads: Set<String>?
        func bases() -> [String] {
            if let baseRefs { return baseRefs }
            let names = [base.isEmpty ? nil : base, Repository(worktree, git: git).defaultBranch()].compactMap { $0 }
            let refs = Array(Set(names.flatMap { ["refs/heads/" + $0, "refs/remotes/origin/" + $0] })).sorted()
            baseRefs = refs
            return refs
        }
        return BranchDrift.shaCandidates(in: message).compactMap { text in
            guard case .answered(let found) = ask(["rev-parse", "--verify", "--quiet", text + "^{commit}"], in: worktree, none: [1, 128], git: git),
                  let commit = found
            else { return nil }
            guard case .answered(let held) = ask(["merge-base", "--is-ancestor", commit, "refs/heads/" + branch], in: worktree, none: [1], git: git),
                  let listed = try? git.run(["for-each-ref", "--contains", commit, "--format=%(refname)", "refs/heads", "refs/remotes/origin"],
                                            in: worktree)
            else { return nil }
            let refs = listed.split(separator: "\n").map(String.init)
            let branches = refs.compactMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }.filter { $0 != branch }
            guard held == nil else { return BranchDrift.Named(text: text, commit: commit, onTaskBranch: true, branches: branches) }
            // Rewrites leave the old object readable. A previous head of this exact task branch is
            // history when no live branch retains it. Work retained on another branch still needs
            // attention unless its patch is already present. Reflogs can expire, so also ask git whether the
            // old commit's patch is already present under another SHA after a rebase or cherry-pick.
            if priorHeads == nil {
                priorHeads = Set(((try? git.run(["reflog", "show", "--format=%H", "refs/heads/" + branch], in: worktree)) ?? "")
                    .split(separator: "\n").map(String.init))
            }
            if refs.isEmpty, priorHeads?.contains(commit) == true { return nil }
            if let cherry = try? git.run(["cherry", "refs/heads/" + branch, commit, commit + "^"], in: worktree),
               cherry.split(separator: "\n").contains(where: { $0 == "- " + commit }) { return nil }
            let onBase = !Set(refs).isDisjoint(with: bases())
            return BranchDrift.Named(text: text, commit: commit, onTaskBranch: false, branches: branches, onBaseBranch: onBase,
                                     mergesTaskBranch: !onBase && merges(commit, branch: branch, worktree: worktree, git: git))
        }
    }

    /// Whether `commit` is a merge of `branch`: a merge commit that holds its head while its first parent doesn't, so the
    /// merge brought the task's work in. One that merged something else into a branch already holding it is not. False
    /// when git couldn't say.
    nonisolated private static func merges(_ commit: String, branch: String, worktree: String, git: any GitRunning) -> Bool {
        let head = "refs/heads/" + branch
        guard case .answered(let second) = ask(["rev-parse", "--verify", "--quiet", commit + "^2"], in: worktree, none: [1, 128], git: git),
              second != nil,
              case .answered(let holds) = ask(["merge-base", "--is-ancestor", head, commit], in: worktree, none: [1], git: git), holds != nil,
              case .answered(let before) = ask(["merge-base", "--is-ancestor", head, commit + "^1"], in: worktree, none: [1], git: git)
        else { return false }
        return before == nil
    }

    /// `GitRunning.ask`, with git's "no" (nil) told apart from a failure that says nothing.
    private enum Answer { case answered(String?), failed }
    nonisolated private static func ask(_ args: [String], in dir: String, none: Set<Int32>, git: any GitRunning) -> Answer {
        do { return .answered(try git.ask(args, in: dir, none: none)) } catch { return .failed }
    }
}
