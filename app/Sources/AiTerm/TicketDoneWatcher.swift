import Foundation
import AiTermCore

/// Whether each row's Jira ticket is in a Done lane, for the check its ticket badge wears. While
/// started it asks Jira about every row's ticket every `interval`, all of them in one read, and a
/// row's answer goes into its own `PerRow` cell, so a ticket that moves redraws its row and no
/// other. Built beside `ReviewThreadsWatcher`, started at launch and stopped at quit with it.
///
/// A GitLab issue is not asked: it is not a Jira ticket. A read that fails, or no Jira connection,
/// leaves every row as it is — the last good answer, or not done if there never was one — so a
/// network blip does not make a check flicker away. A row's answer is cleared only when the row
/// goes or its task now carries another ticket. Nothing here writes to Jira.
@MainActor
final class TicketDoneWatcher {
    /// What a pass reads with: the connection as Settings saved it, read once per pass, off the
    /// main actor; nil when Jira is not connected.
    typealias Connect = @Sendable () -> (any DoneTicketsReading)?

    private let workspace: WorkspaceStore
    private let connect: Connect
    /// The pause between one pass ending and the next starting.
    private let interval: Duration
    /// Each row's answer, observed row by row.
    private let rows: PerRow<Bool>
    /// The ticket each answer was read for, so a row that went or now carries another ticket loses it.
    private var readFor: [UUID: String] = [:]
    private var hook: WorkspaceStore.Hook?
    private var polling: PollLoop?
    /// The pass under way, if any.
    private var pass: Task<Void, Never>?

    init(workspace: WorkspaceStore, interval: Duration = .seconds(60), connect: @escaping Connect) {
        self.workspace = workspace
        self.connect = connect
        self.interval = interval
        rows = PerRow(default: false, workspace: workspace)
        hook = workspace.onChange { [weak self] in self?.dropStale() }
    }

    isolated deinit {
        if let hook { workspace.removeHook(hook) }
    }

    /// Whether the row's ticket was last read as done. Read in a view's body, it is that row's alone to observe.
    func isDone(_ id: UUID) -> Bool { rows[id] }

    /// Reads every row's ticket now, and again `interval` after each pass ends, until `stop()`. A
    /// second call does nothing.
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

    /// Stops the polling and drops whatever is being read: no answer lands after it.
    func stop() {
        polling?.cancel()
        polling = nil
        pass?.cancel()
        pass = nil
    }

    /// One pass: every row whose task carries a Jira ticket, in one read.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        pass?.cancel()
        let tickets = workspace.state.tasks.compactMap { task -> (id: UUID, key: String)? in
            guard let ticket = task.jira, !ticket.isGitLabIssue else { return nil }
            return (task.id, ticket.key)
        }
        let connect = self.connect
        let task = Task { [weak self] in
            guard !tickets.isEmpty else { return }
            let keys = tickets.map(\.key).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            // `nil` for no connection, and for a read that failed (logged): every row stays as it is.
            let done = await Log.network.attempt("Reading which tickets are done", level: .info) { () -> Set<String>? in
                guard let reader = await BackgroundWork.run({ connect() }) else { return nil }
                return try await reader.doneKeys(among: keys)
            } ?? nil
            guard !Task.isCancelled, let self, let done else { return }
            for ticket in tickets { apply(done.contains(ticket.key), to: ticket.id, readFor: ticket.key) }
        }
        pass = task
        return task
    }

    /// Writes an answer only for a row that still carries the ticket it was read for.
    private func apply(_ done: Bool, to id: UUID, readFor key: String) {
        guard let ticket = workspace.state.task(id: id)?.jira, !ticket.isGitLabIssue, ticket.key == key else { return }
        readFor[id] = key
        rows[id] = done
    }

    /// An answer whose row went, or whose row's ticket changed, goes in the same change.
    private func dropStale() {
        for (id, key) in readFor where workspace.state.task(id: id)?.jira?.key != key {
            readFor[id] = nil
            rows[id] = false
        }
    }

    #if DEBUG
    /// The snapshot renderer's and the redraw tests' answers, drawn without asking Jira.
    func seedSnapshotDone(_ done: Bool, of id: UUID) { rows[id] = done }
    #endif
}
