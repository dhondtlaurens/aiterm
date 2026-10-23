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
/// them. A thread that is new and unresolved, one newly resolved or reopened, a new last note on an unresolved
/// thread by anyone but the token's own user (so the Operator's own `reply_thread` is no news), and a new
/// approval are news:
/// the Operator is woken once for the task (`review feedback on PAY-2`, a reason its key keeps out of the line
/// typed: `OperatorWaker.isPlain`). What was read
/// is kept on the task (`PeopleReview`), so a restart wakes it for what came meanwhile and for nothing else.
/// A task taken over, or one whose operation is paused or ended, is not read.
@MainActor
final class ReviewWatcher {
    private let workspace: WorkspaceStore
    private let ports: OperatorPorts
    private let waker: OperatorWaker
    private let pass = TickPass()
    /// The latest pass, for a test to await.
    var lastPoll: Task<Void, Never>? { pass.last }

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
        pass.run(state.tasks.filter(isWatched).map(\.id)) { [weak self] in await self?.check($0) }
    }

    private func check(_ id: UUID) async {
        guard let task = state.task(id: id), isWatched(task), let number = task.operated?.publication?.mergeRequestNumber,
              let project = state.project(id: task.projectId) else { return }
        let threads: [ReviewThread], approvals: [String]?, own: String?
        do {
            let host = try await ReviewHosts.host(of: project, git: ports.git, connect: ports.publisher)
            // Another repository's request of the same number is not this one: origin changed since it was opened.
            if let publication = task.operated?.publication, let why = PublicationGuard.otherRepository(publication, repository: host.repository) {
                Log.network.error("Not reading the review of \(task.operated?.key ?? task.title, privacy: .public): \(why, privacy: .public)")
                return
            }
            threads = try await host.threads(of: number)
            // Approvals only where the host gives them: one that cannot leaves them as they were.
            approvals = try? await host.approvals(of: number)
            // The connection is fresh each check; Settings may now name a different token user.
            own = try? await host.currentUser()
        } catch {
            Log.network.error("Reading the review of \(task.operated?.key ?? task.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Read fresh: the host was asked meanwhile.
        guard let current = state.task(id: id), isWatched(current), let operated = current.operated,
              current.projectId == task.projectId, state.project(id: project.id)?.path == project.path,
              operated.runId == task.operated?.runId, operated.ownership == task.operated?.ownership,
              operated.acceptance == task.operated?.acceptance,
              operated.publication == task.operated?.publication else { return }
        let seen = operated.peopleReview ?? PeopleReview()
        var next = seen
        next.threads = Dictionary(threads.map { ($0.id, $0.resolved) }, uniquingKeysWith: { first, _ in first })
        if let approvals { next.approvals = approvals }
        // A note is told apart from AiTerm's own only once the token's user is known: until then the notes seen stay
        // as they were, so a reviewer's reply is still news on a later pass.
        if own != nil {
            next.notes = Dictionary(threads.map { ($0.id, Self.signature($0)) }, uniquingKeysWith: { first, _ in first })
        }
        guard next != seen else { return }
        let news = Self.isNews(threads: threads, approvals: approvals ?? seen.approvals, seen: seen, me: own)
        workspace.mutate { $0.updateOperated(id) { $0.peopleReview = next } }
        if news { waker.say("review feedback on one task", to: operated.runId, colon: true) }
    }

    /// A thread that is new and unresolved, one whose resolution changed, a new last note on an unresolved thread
    /// by someone other than `me` (nil: not known yet, so no note is news), or an approval not seen before. A thread
    /// whose last note was never recorded (a review read by an older build) has it recorded, not told.
    static func isNews(threads: [ReviewThread], approvals: [String], seen: PeopleReview, me: String?) -> Bool {
        threads.contains { thread in
            guard let resolved = seen.threads[thread.id] else { return !thread.resolved }
            if resolved != thread.resolved { return true }
            guard !thread.resolved, let me, let before = seen.notes[thread.id], before != signature(thread) else { return false }
            return thread.lastAuthor?.lowercased() != me.lowercased()
        } || approvals.contains { !seen.approvals.contains($0) }
    }

    /// A thread's last note as it is kept: its author and a hash of its text, stable across launches (FNV-1a).
    static func signature(_ thread: ReviewThread) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in thread.lastBody.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return (thread.lastAuthor ?? "") + ":" + String(hash, radix: 16)
    }
}
