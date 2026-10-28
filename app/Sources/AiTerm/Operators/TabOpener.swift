import CryptoKit
import Foundation
import AiTermCore

/// Opens the worker tabs the Operator adds to a running task (`open_tab`). Each is saved on its task before the
/// daemon is asked for it (`ExtraTab`), as a task's launch is: it opens in the task's window, in its worktree, behind
/// your work, tagged with the task and its key (`SessionInfo.tabKey`), and the reconciler adopts the tab so tagged,
/// after a restart too, or asks again, never for a second one: the daemon answers a repeat with the tab it tagged.
@MainActor
final class TabOpener {
    /// One extra tab: its task, and its key there.
    struct ID: Hashable {
        let task: UUID
        let key: String
    }

    /// What asking for a tab came to: its tab opened; it may still open, which the reconciler looks for; or the
    /// daemon refused it, with the reason.
    enum Outcome: Equatable {
        case opened, opening
        case failed(String)
    }

    private let workspace: WorkspaceStore
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let ports: OperatorPorts
    /// The tabs being asked for now: a reconcile pass that meets one leaves it be.
    private(set) var opening: Set<ID> = []
    /// When each tab's last request in this run of AiTerm ended: one that ended with no answer (a timeout) may
    /// still open its tab, so the reconciler counts its minute from here.
    private(set) var settledAt: [ID: Date] = [:]

    init(workspace: WorkspaceStore, daemon: @escaping @MainActor () -> (any DaemonCommands)?, ports: OperatorPorts) {
        self.workspace = workspace
        self.daemon = daemon
        self.ports = ports
    }

    private var state: AppState { workspace.state }

    /// Asks for the tab as `attempt`, its record saved by the caller first. Opening already: it may still open.
    func open(_ id: ID, attempt: LaunchAttempt) async -> Outcome {
        guard opening.insert(id).inserted else { return .opening }
        return await ask(id, attempt: attempt)
    }

    /// A tab whose request showed none, asked for again as `attempt`, saved by the caller first.
    func relaunch(_ id: ID, attempt: LaunchAttempt) -> Task<Void, Never>? {
        guard opening.insert(id).inserted else { return nil }
        return Task { _ = await ask(id, attempt: attempt) }
    }

    /// Its command built off the main actor, then, if its record and its task still hold, the daemon asked for the tab
    /// in the task's window, in the background. A failure that leaves the tab's fate unknown is left for the reconciler;
    /// any other is recorded on the tab.
    private func ask(_ id: ID, attempt: LaunchAttempt) async -> Outcome {
        defer {
            opening.remove(id)
            settledAt[id] = ports.now()
        }
        guard let found = record(id), found.tab.launch == attempt, found.tab.sessionId == nil, Self.holds(found.task, in: state),
              let window = found.task.windowId, let daemon = daemon() else { return Self.outcome(of: record(id)?.tab) }
        let task = found.task, tab = found.tab
        let worktree = task.worktreePath, git = ports.git
        let run = task.operated.flatMap { state.run(id: $0.runId) }
        let review = run?.taskSettings?.review
        // Built here, unused by a review tab: `prompt(branch:brief:)` needs the main actor, the review's SHA the background.
        let reviewing = tab.role == .review, workerPrompt = Self.prompt(branch: task.branch, brief: tab.brief)
        let file = Self.promptFile(for: id.key)
        do {
            // The Operator's worker flags, its own prompt file: the task's other workers started in this worktree too.
            // Read the named branch when opening the review, not HEAD: the shared worktree may have moved.
            let command = try await BackgroundWork.run {
                let prompt: String
                if reviewing {
                    let sha = try git.run(["rev-parse", "--verify", "refs/heads/" + task.branch + "^{commit}"], in: worktree)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    prompt = Self.reviewPrompt(branch: task.branch, sha: sha, review: review, brief: tab.brief)
                } else {
                    prompt = workerPrompt
                }
                return try AgentCommand.build(agent: tab.agent, model: tab.model, reasoning: tab.reasoning, prompt: prompt, worktreePath: worktree,
                                              git: git, operated: true, readOnly: reviewing, promptFile: file)
            }
            // The await has passed: the task may have been taken over or ended, its window closed, or its broadcast paused.
            guard let now = record(id), now.tab.launch == attempt, now.tab.sessionId == nil, Self.holds(now.task, in: state),
                  now.task.windowId == window else { return Self.outcome(of: record(id)?.tab) }
            let session = try await daemon.createTab(windowId: window, cwd: worktree, agentCommand: command, tabKey: id.key, background: true)
            recordSession(session, of: id)
            return .opened
        } catch let error as DaemonError where [.timeout, .disconnected, .itermUnavailable].contains(error.code) {
            Log.daemon.info("An operator's extra worker tab may still open; the run reconciler looks again: \(error.message, privacy: .public)")
            return .opening
        } catch {
            let reason = error.localizedDescription
            workspace.mutate { state in
                state.updateOperated(id.task) { operated in
                    guard let i = operated.extraTabs.firstIndex(where: { $0.key == id.key }), operated.extraTabs[i].launch == attempt,
                          operated.extraTabs[i].sessionId == nil else { return }
                    operated.extraTabs[i].failure = reason
                }
            }
            return .failed(reason)
        }
    }

    /// The tabs iTerm2 lists now: each tagged with a task and a key the task records is that extra tab, opened, with the
    /// conversation its agent names.
    func tabsListed(_ sessions: [SessionInfo]) {
        for session in sessions {
            guard let task = session.taskUUID, let key = session.tabKey,
                  let tab = state.task(id: task)?.operated?.extraTabs.first(where: { $0.key == key }) else { continue }
            let conversation = session.conversationId.flatMap { TaskConversation.isResumable($0) ? $0 : nil }
            guard tab.sessionId != session.sessionId || tab.launch.openedAt == nil || (conversation != nil && conversation != tab.conversation)
            else { continue }
            recordSession(session.sessionId, of: ID(task: task, key: key), conversation: conversation)
        }
    }

    /// The tab's session, and that its request showed it: never asked for again.
    private func recordSession(_ session: String, of id: ID, conversation: String? = nil) {
        let now = ports.now()
        workspace.mutate { state in
            state.updateOperated(id.task) { operated in
                guard let i = operated.extraTabs.firstIndex(where: { $0.key == id.key }) else { return }
                operated.extraTabs[i].sessionId = session
                operated.extraTabs[i].failure = nil
                if operated.extraTabs[i].launch.openedAt == nil { operated.extraTabs[i].launch.openedAt = now }
                if let conversation { operated.extraTabs[i].conversation = conversation }
            }
        }
    }

    private func record(_ id: ID) -> (task: TaskItem, tab: ExtraTab)? {
        guard let task = state.task(id: id.task), let tab = task.operated?.extraTabs.first(where: { $0.key == id.key }) else { return nil }
        return (task, tab)
    }

    /// What a request that asked nothing leaves: its tab as it was recorded.
    static func outcome(of tab: ExtraTab?) -> Outcome {
        if let failure = tab?.failure { return .failed(failure) }
        return tab?.sessionId == nil ? .opening : .opened
    }

    /// Whether `task` may have a tab opened now: working or in review, not taken over, its worktree and window there,
    /// in a broadcast that takes work and that the person hasn't paused or stopped.
    static func holds(_ task: TaskItem, in state: AppState) -> Bool {
        guard let operated = task.operated, [.working, .inReview].contains(operated.state), !operated.takenOver,
              task.hasCheckout, task.windowId != nil, let run = state.run(id: operated.runId) else { return false }
        return [.active, .complete].contains(run.state) && run.intent == nil
    }

    /// An extra tab's first prompt: AiTerm's line on where it works (`WorkerStarter.worktreeLine`), its line on the
    /// worktree it shares, then the Operator's brief.
    static func prompt(branch: String, brief: String) -> String {
        WorkerStarter.worktreeLine(branch: branch) + "\n\n" + sharedLine + "\n\n" + brief
    }

    /// The person's review prompt, AiTerm's line on where every worker works (`WorkerStarter.worktreeLine`), its
    /// review-only instructions, the Operator's context, and the verdict block, filled with `sha`, last.
    nonisolated static func reviewPrompt(branch: String, sha: String, review: String?, brief: String) -> String {
        let parts = [review ?? "", WorkerStarter.worktreeLine(branch: branch),
                     "[AiTerm] Review commit \(sha), the head of branch \(branch) when this tab opened. "
                        + "You share this worktree with this task's other workers.",
                     "[AiTerm] This tab only reviews: it never edits, commits or pushes, so \"Commit only here\" above is for this task's "
                        + "other workers. You may start subagents and run read-only commands.",
                     brief, ReviewVerdict.block(sha: sha)]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The fixed line every extra tab's first prompt carries after `worktreeLine`, from AiTerm and never the Operator.
    static let sharedLine = "[AiTerm] You share this worktree and branch with this task's other workers. "
        + "Commit only your own changes, and leave theirs as you find them."

    /// The file under `.aiterm/` the tab's prompt goes to when it is too long to type: its own, named by its key in
    /// letters and digits only, since the name is typed into the command.
    static func promptFile(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "first-prompt-tab-\(digest).md"
    }
}
