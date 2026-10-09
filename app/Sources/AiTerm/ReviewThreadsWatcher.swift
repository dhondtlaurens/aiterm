import Foundation
import AiTermCore

/// How many of each merge request's review threads are resolved, for the row that carries it — a
/// review, or a task a review was opened in. While started it reads every such row every minute,
/// and a row again when it becomes selected; each count goes into the row's own `PerRow` cell, so a
/// count that moves redraws its row and no other. An owner of the composition root, built after the
/// selection it listens to, started at launch and stopped at quit with the rest.
///
/// A read that fails, or a host that is not connected, leaves the row's count as it is — the last
/// good answer, or none if there never was one — so a network blip does not make a count flicker
/// away. A count is cleared only when its row goes or its task now carries another merge request.
/// Nothing here writes to GitLab or GitHub.
@MainActor
final class ReviewThreadsWatcher {
    /// What a pass reads with: the connections as Settings saved them, read once per pass, off the
    /// main actor.
    typealias Connect = @Sendable () -> any ReviewThreadsReading

    private let workspace: WorkspaceStore
    private let connect: Connect
    /// The pause between one pass ending and the next starting.
    private let interval: Duration
    /// Each row's count, observed row by row.
    private let rows: PerRow<ReviewThreads?>
    /// The merge request each count held was read for, so a row that went or now carries another
    /// merge request loses its count in the change that did it.
    private var readFor: [UUID: String] = [:]
    private var hook: WorkspaceStore.Hook?
    private var polling: Task<Void, Never>?
    /// The pass under way, if any.
    private var pass: Task<Void, Never>?
    /// The read a selection started, if any; tests await it.
    private(set) var selectionRead: Task<Void, Never>?

    init(workspace: WorkspaceStore, focus: RowFocus, interval: Duration = .seconds(60), connect: @escaping Connect) {
        self.workspace = workspace
        self.connect = connect
        self.interval = interval
        rows = PerRow(default: nil, workspace: workspace)
        hook = workspace.onChange { [weak self] in self?.dropStale() }
        focus.onSelectionChanged { [weak self] selection in
            if case .task(let id)? = selection { self?.selected(id) }
        }
    }

    isolated deinit {
        if let hook { workspace.removeHook(hook) }
    }

    /// The row's count as last read successfully; `nil` until one is. A read that fails or finds no
    /// connected host does not change it. Read in a view's body, it is that row's alone to observe.
    func threads(of id: UUID) -> ReviewThreads? { rows[id] }

    /// Reads every row with a merge request now, and again `interval` after each pass ends, until
    /// `stop()`; reads a row again when it is selected meanwhile. A second call does nothing.
    func start() {
        guard polling == nil else { return }
        let interval = self.interval
        // Weak: the loop must not keep the watcher alive, and it ends when the watcher goes.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let pass = self?.refresh() else { return }
                await pass.value
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Stops the polling and drops whatever is being read: no count lands after it.
    func stop() {
        polling?.cancel()
        polling = nil
        pass?.cancel()
        pass = nil
        selectionRead?.cancel()
        selectionRead = nil
    }

    /// One pass: every row whose task carries a merge request, read in turn.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let task = read(workspace.state.tasks.filter { $0.mr != nil }.map(\.id))
        pass = task
        return task
    }

    /// A row with a merge request was selected: read it now rather than at the next pass. Only
    /// while started, so a process that only renders — the snapshots — asks nothing of either host.
    private func selected(_ id: UUID) {
        guard polling != nil, workspace.state.task(id: id)?.mr != nil else { return }
        selectionRead?.cancel()
        selectionRead = read([id])
    }

    private func read(_ ids: [UUID]) -> Task<Void, Never> {
        let requests = ids.compactMap { id in workspace.state.task(id: id)?.mr.map { (id: id, mr: $0) } }
        let connect = self.connect
        return Task { [weak self] in
            guard !requests.isEmpty else { return }
            let reader = await BackgroundWork.run { connect() }
            for request in requests {
                guard !Task.isCancelled else { return }
                // `nil` for a read that failed (logged) and for a host not connected: the cell stays.
                let threads = await Log.network.attempt("Reading the review threads of \(request.mr.reference)", level: .info) {
                    try await reader.threads(of: request.mr)
                } ?? nil
                guard !Task.isCancelled else { return }
                if let threads { self?.apply(threads, to: request.id, readFor: request.mr) }
            }
        }
    }

    /// Writes a count only for a row that still carries the merge request it was read for: one that
    /// went, or now carries another, while it was read gets nothing.
    private func apply(_ threads: ReviewThreads, to id: UUID, readFor mr: MergeRequestRef) {
        guard workspace.state.task(id: id)?.mr == mr else { return }
        readFor[id] = mr.url
        rows[id] = threads
    }

    /// A count whose row went, or whose row's merge request changed, goes in the same change; its
    /// cell then holds the default, which `PerRow` drops at the next.
    private func dropStale() {
        for (id, url) in readFor where workspace.state.task(id: id)?.mr?.url != url {
            readFor[id] = nil
            rows[id] = nil
        }
    }

    #if DEBUG
    /// The snapshot renderer's and the redraw tests' counts, drawn without reading either host.
    func seedSnapshotThreads(_ threads: ReviewThreads?, of id: UUID) { rows[id] = threads }
    #endif
}
