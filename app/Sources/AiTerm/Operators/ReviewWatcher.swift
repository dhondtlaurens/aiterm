import Foundation
import AiTermCore

/// The code host a project's requests are on, as `finish_task` finds it: origin's fetch URL, with the
/// connections Settings saved. What cannot be had is said as Settings would fix it.
@MainActor
enum ReviewHosts {
    static func host(of project: Project, git: any GitRunning,
                     connect: @Sendable (RemoteInfo) throws -> any MergeRequestPublishing) async throws -> any MergeRequestPublishing {
        let path = project.path
        let origin: String?
        do { origin = try await BackgroundWork.run { try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) } }
        catch { throw ToolRefusal(GitError.displayReason(of: error)) }
        guard let origin else { throw ToolRefusal(PublishRefusal.noOrigin.localizedDescription) }
        let remote = ProviderDetector.detect(remoteUrl: origin, repoPath: path)
        do { return try connect(remote) } catch { throw ToolRefusal(TaskFinisher.unavailable(error)) }
    }
}

/// Watches the requests people review (spec §5, the Review slice): every `OperatorTiming.reconcileInterval`,
/// on the reconcile tick, each task in review has its threads read, and its approvals where the host gives
/// them. A thread that is new and unresolved, one newly resolved or reopened, and a new approval are news:
/// the Operator is woken once for the task, `[AiTerm] review feedback on PAY-2: call run_status`. What was read
/// is kept on the task (`PeopleReview`), so a restart wakes it for what came meanwhile and for nothing else.
/// A task taken over, or one whose operation is paused or ended, is not read.
@MainActor
final class ReviewWatcher {
    private let workspace: WorkspaceStore
    private let ports: OperatorPorts
    private let waker: OperatorWaker
    private var polling: Task<Void, Never>?
    /// The latest pass, for a test to await.
    private(set) var lastPoll: Task<Void, Never>?

    init(workspace: WorkspaceStore, ports: OperatorPorts, waker: OperatorWaker) {
        self.workspace = workspace
        self.ports = ports
        self.waker = waker
    }

    private var state: AppState { workspace.state }

    /// Whether `task` is watched now: in review with a request, still the operator's, in an operation that runs
    /// and that you have neither paused nor ended.
    func isWatched(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, operated.state == .inReview, !operated.takenOver,
              operated.publication?.mergeRequestNumber != nil, let run = state.run(id: operated.runId), run.intent == nil
        else { return false }
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
        guard let task = state.task(id: id), isWatched(task), let number = task.operated?.publication?.mergeRequestNumber,
              let project = state.project(id: task.projectId) else { return }
        let threads: [ReviewThread], approvals: [String]?
        do {
            let host = try await ReviewHosts.host(of: project, git: ports.git, connect: ports.publisher)
            threads = try await host.threads(of: number)
            // Approvals only where the host gives them: one that cannot leaves them as they were.
            approvals = try? await host.approvals(of: number)
        } catch {
            Log.network.error("Reading the review of \(task.operated?.key ?? task.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Read fresh: the host was asked meanwhile.
        guard let current = state.task(id: id), isWatched(current), let operated = current.operated else { return }
        let seen = operated.peopleReview ?? PeopleReview()
        var next = seen
        next.threads = Dictionary(threads.map { ($0.id, $0.resolved) }, uniquingKeysWith: { first, _ in first })
        if let approvals { next.approvals = approvals }
        guard next != seen else { return }
        let news = Self.isNews(threads: threads, approvals: approvals ?? seen.approvals, seen: seen)
        workspace.mutate { $0.updateOperated(id) { $0.peopleReview = next } }
        if news { waker.say("review feedback on \(operated.key)", to: operated.runId, colon: true) }
    }

    /// A thread that is new and unresolved, one whose resolution changed, or an approval not seen before.
    static func isNews(threads: [ReviewThread], approvals: [String], seen: PeopleReview) -> Bool {
        threads.contains { thread in seen.threads[thread.id].map { $0 != thread.resolved } ?? !thread.resolved }
            || approvals.contains { !seen.approvals.contains($0) }
    }
}
