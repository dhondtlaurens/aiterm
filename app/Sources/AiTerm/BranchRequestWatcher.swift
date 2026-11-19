import Foundation
import AiTermCore

/// Finds the merge or pull request a task's own branch has, so its row wears the request's mark
/// without a review opened on it first. While started it asks for every row that can still gain one
/// every minute, and for a row again when it becomes selected; an open or merged request it finds is
/// saved on the task (`TaskItem.mr`), where the row's mark, `ReviewThreadsWatcher`'s count and the
/// archive search read it. Once saved it stays, as one New Review put there does. An owner of the
/// composition root, started at launch and stopped at quit with the other watchers.
///
/// A row is asked while it is a task or a review with a checkout, no request and a branch other than
/// its base, and is not a Signal's: `RequestWatch` owns a Signal task's request. A read that fails,
/// or a host that is not connected, leaves the task as it is. Nothing here writes to GitLab or GitHub.
@MainActor
final class BranchRequestWatcher {
    /// What a pass reads with: the connections as Settings saved them, read once per pass, off the
    /// main actor.
    typealias Connect = @Sendable () -> any BranchRequestReading

    private let workspace: WorkspaceStore
    private let connect: Connect
    /// The pause between one pass ending and the next starting.
    private let interval: Duration
    private var polling: PollLoop?
    /// The pass under way, if any.
    private var pass: Task<Void, Never>?
    /// The read a selection started, if any; tests await it.
    private(set) var selectionRead: Task<Void, Never>?

    init(workspace: WorkspaceStore, focus: RowFocus, interval: Duration = .seconds(60), connect: @escaping Connect) {
        self.workspace = workspace
        self.connect = connect
        self.interval = interval
        focus.onSelectionChanged { [weak self] selection in
            if case .task(let id)? = selection { self?.selected(id) }
        }
    }

    /// Whether `task` is asked for its branch's request: see the type.
    static func isAsked(_ task: TaskItem) -> Bool {
        task.mr == nil && task.signalTask == nil && task.hasCheckout
            && !task.branch.isEmpty && task.branch != task.baseBranch
    }

    /// Asks for every row that can still gain a request now, and again `interval` after each pass
    /// ends, until `stop()`; asks for a row again when it is selected meanwhile. A second call does nothing.
    func start() {
        guard polling == nil else { return }
        let interval = self.interval
        // Weak: the loop must not keep the watcher alive, and it ends when the watcher goes.
        polling = PollLoop(interval: interval) { [weak self] in
            guard let pass = self?.refresh() else { return nil }
            await pass.value
            return interval
        }
    }

    /// Stops the polling and drops whatever is being read: no request lands after it.
    func stop() {
        polling?.cancel()
        polling = nil
        pass?.cancel()
        pass = nil
        selectionRead?.cancel()
        selectionRead = nil
    }

    /// One pass: every row that can still gain a request, asked in turn.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        pass?.cancel()
        let task = read(workspace.state.tasks.filter(Self.isAsked).map(\.id))
        pass = task
        return task
    }

    /// A row that can still gain a request was selected: ask now rather than at the next pass. Only
    /// while started, so a process that only renders — the snapshots — asks nothing of either host.
    private func selected(_ id: UUID) {
        guard polling != nil, let task = workspace.state.task(id: id), Self.isAsked(task) else { return }
        selectionRead?.cancel()
        selectionRead = read([id])
    }

    private func read(_ ids: [UUID]) -> Task<Void, Never> {
        let state = workspace.state
        let asks = ids.compactMap { id -> (id: UUID, branch: String, remote: String?)? in
            guard let task = state.task(id: id) else { return nil }
            return (id, task.branch, state.project(id: task.projectId)?.remoteUrl)
        }
        let connect = self.connect
        return Task { [weak self] in
            guard !asks.isEmpty else { return }
            let reader = await BackgroundWork.run { connect() }
            for ask in asks {
                guard !Task.isCancelled else { return }
                // `nil` for a read that failed (logged), a host not connected, or no request.
                let found = await Log.network.attempt("Looking up the request of \(ask.branch)", level: .info) {
                    try await reader.request(remoteUrl: ask.remote, branch: ask.branch)
                } ?? nil
                guard !Task.isCancelled else { return }
                if let self, let found { save(found, to: ask.id, askedFor: ask.branch, on: ask.remote) }
            }
        }
    }

    /// Saves the request only on a task still asked for, still on the branch it was asked for, in a
    /// project whose remote is still the one asked: one that went, moved, got a request meanwhile from
    /// a review opened on it, or whose project now names another repository keeps what it has.
    private func save(_ request: MergeRequestRef, to id: UUID, askedFor branch: String, on remote: String?) {
        workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == id }),
                  state.tasks[i].branch == branch, Self.isAsked(state.tasks[i]),
                  state.project(id: state.tasks[i].projectId)?.remoteUrl == remote else { return }
            state.tasks[i].mr = request
        }
    }
}
