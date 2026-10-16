import Foundation
import AiTermCore

/// `finish_task` (spec §6, M3), as the app runs it: `TaskPublisher` carries the task's end forward,
/// each step saved to the workspace — and flushed — as it completes (spec §11: a crash between push
/// and MR resumes at the MR); a step that cannot be saved stops everything after it. One publication
/// per task runs at a time: a second call — the operator's retry after the daemon gave up waiting, or
/// a watch's poll — waits for the one in flight and answers what it did. A merge end that must wait
/// is watched here, polling every `OperatorTiming.mergePoll`, until it merges, the host gives a reason
/// it will not, or the wait runs out; then the operator is told (`changed`). The tool call itself never
/// waits for a merge: it answers `waitingToMerge` at once.
///
/// The host is the one the push goes to: origin's fetch URL, never `Repository.remoteUrl()`, which
/// prefers the branch's upstream remote — the protection asked about must be the pushed repository's.
@MainActor
final class TaskFinisher {
    /// What `finish_task` answers the operator: what was done, whatever the outcome.
    struct Result: Codable, Equatable, Sendable {
        var result: String
        var reason: String?
        var mergeRequest: String?
        var pushedSHA: String?
        var merged: Bool
        var mergedSHA: String?

        init(result: String, reason: String? = nil, mergeRequest: String? = nil, pushedSHA: String? = nil,
             merged: Bool = false, mergedSHA: String? = nil) {
            self.result = result; self.reason = reason; self.mergeRequest = mergeRequest
            self.pushedSHA = pushedSHA; self.merged = merged; self.mergedSHA = mergedSHA
        }

        init(_ publication: TaskPublication?, result: String, reason: String?) {
            let publication = publication ?? TaskPublication()
            self.init(result: result, reason: reason, mergeRequest: publication.mergeRequestURL,
                      pushedSHA: publication.pushedSHA, merged: publication.merged, mergedSHA: publication.mergedSHA)
        }
    }

    /// A step done but not saved: nothing more is done outside this machine.
    struct NotSaved: Error {}
    static let notSavedReason = "AiTerm couldn’t save what it has done so far, so it stopped before the next step. Call finish_task again once the workspace saves."

    private let store: WorkspaceStore
    private let git: any GitRunning
    private let connect: @Sendable (RemoteInfo) throws -> any MergeRequestPublishing
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Told when a watched merge ends — merged, blocked, out of time. The controller sets it after its own
    /// init, so this init captures no `self` of the controller's.
    var changed: @MainActor (UUID) -> Void
    /// Told when the host merged the task's request with a head nobody accepted, and why: a question for
    /// you (the controller's), never retried. Set like `changed`.
    var mergedOnHost: @MainActor (UUID, String) -> Void = { _, _ in }
    /// Each task's publication in flight.
    private var inFlight: [UUID: Task<Result, Never>] = [:]
    private var watchers: [UUID: Task<Void, Never>] = [:]
    /// How many calls found a publication in flight and waited for it; for a test.
    private(set) var joined = 0

    init(store: WorkspaceStore, git: any GitRunning,
         connect: @escaping @Sendable (RemoteInfo) throws -> any MergeRequestPublishing,
         now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
         changed: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.store = store; self.git = git; self.connect = connect; self.now = now; self.sleep = sleep; self.changed = changed
    }

    /// The tasks whose merge is being watched.
    var watching: Set<UUID> { Set(watchers.keys) }
    /// The tasks with a publication in flight.
    var running: Set<UUID> { Set(inFlight.keys) }

    /// The operator's `finish_task`: clears a recorded problem and goes on from the saved steps.
    func finish(_ id: UUID) async -> Result {
        await run(id, restart: true)
    }

    /// At launch and when an operation resumes: watch every merge end that was waiting when AiTerm last
    /// stopped. A task watched already is not watched twice.
    func resumeWatching() {
        for task in store.state.tasks { watch(task.id) }
    }

    /// On a takeover or a stopped task.
    func stopWatching(_ id: UUID) {
        watchers.removeValue(forKey: id)?.cancel()
    }

    /// On a Pause or an End: every watch of the operation's tasks.
    func stopWatching(inRun run: UUID) {
        for id in Array(watchers.keys) where store.state.task(id: id)?.operated?.runId == run { stopWatching(id) }
    }

    /// A merge end opened and waiting, not stuck, in an operation that runs and that you have neither
    /// paused nor ended, and still the operator's.
    private func isWatchable(_ id: UUID) -> Bool {
        guard let operated = store.state.task(id: id)?.operated, operated.end == .merge, operated.state == .accepted,
              !operated.takenOver, !operated.flags.contains(.upstreamReplaced),
              let publication = operated.publication, publication.mergeRequestNumber != nil,
              !publication.merged, publication.mergedSHA == nil, publication.problem == nil,
              let run = store.state.run(id: operated.runId), run.intent == nil
        else { return false }
        return run.state == .active || run.state == .complete
    }

    /// The one way a publication runs: joined when one is in flight for the task.
    private func run(_ id: UUID, restart: Bool) async -> Result {
        if let running = inFlight[id] {
            joined += 1
            return await running.value
        }
        let started = Task { await self.advance(id, restart: restart) }
        inFlight[id] = started
        let result = await started.value
        if inFlight[id] == started { inFlight[id] = nil }
        return result
    }

    private func advance(_ id: UUID, restart: Bool) async -> Result {
        guard let first = context(of: id) else { return Result(result: "refused", reason: PublicationGuard.gone) }
        let task = first.task, operated = first.operated, project = first.project
        // What is done is answered from the record, whatever the host's connection is now.
        if operated.state == .published || operated.publication?.merged == true {
            return apply(.published(operated.publication ?? TaskPublication()), to: id)
        }
        let repository = Repository(project.path, git: git), branch = task.branch, path = project.path, git = self.git
        let remote: RemoteInfo
        do {
            // What the plan or the operation rules out is said before any host is asked for.
            let (defaultBranch, tip) = try await BackgroundWork.run { (repository.defaultBranch(), try repository.tip(of: branch)) }
            guard let fresh = context(of: id) else { return Result(result: "refused", reason: PublicationGuard.gone) }
            if let refusal = PublicationGuard.refusal(task: fresh.task, run: fresh.run, parent: fresh.parent,
                                                      defaultBranch: defaultBranch, branchTip: tip) {
                return Result(fresh.operated.publication, result: "refused", reason: refusal)
            }
            guard let origin = try await BackgroundWork.run({ try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) }) else {
                return Result(fresh.operated.publication, result: "refused", reason: PublishRefusal.noOrigin.localizedDescription)
            }
            remote = ProviderDetector.detect(remoteUrl: origin, repoPath: path)
        } catch {
            return Result(store.state.task(id: id)?.operated?.publication, result: "failed", reason: GitError.displayReason(of: error))
        }
        let host: any MergeRequestPublishing
        do { host = try connect(remote) }
        catch { return Result(store.state.task(id: id)?.operated?.publication, result: "refused", reason: Self.unavailable(error)) }
        // Read fresh: the checks above awaited git.
        guard let current = context(of: id) else { return Result(result: "refused", reason: PublicationGuard.gone) }
        let ownership = current.operated.ownership, accepted = current.operated.acceptance?.resultSHA ?? ""
        let publisher = TaskPublisher(repository: repository, host: host, now: now)
        do {
            let outcome = try await publisher.advance(
                TaskPublisher.Context(task: current.task, run: current.run, parent: current.parent), restart: restart,
                recheck: { @MainActor [weak self] in
                    guard let self else { return PublicationGuard.gone }
                    return self.recheck(id, ownership: ownership, sha: accepted)
                },
                record: { @MainActor [weak self] publication in
                    guard let self else { throw NotSaved() }
                    try self.record(publication, for: id)
                })
            return apply(outcome, to: id)
        } catch is NotSaved {
            return Result(store.state.task(id: id)?.operated?.publication, result: "failed", reason: Self.notSavedReason)
        } catch {
            return Result(store.state.task(id: id)?.operated?.publication, result: "failed", reason: Self.failure(error, branch: branch))
        }
    }

    /// The task, its record, its operation, its project and the parent it is stacked on, as they are now.
    private struct Context {
        let task: TaskItem, operated: OperatedTask, run: OperatorRun, project: Project, parent: TaskItem?
    }

    private func context(of id: UUID) -> Context? {
        let state = store.state
        guard let task = state.task(id: id), let operated = task.operated,
              let run = state.run(id: operated.runId), let project = state.project(id: task.projectId) else { return nil }
        return Context(task: task, operated: operated, run: run, project: project, parent: operated.stackedOn.flatMap { state.task(id: $0) })
    }

    /// Read fresh before every step that changes something outside this machine.
    private func recheck(_ id: UUID, ownership: Int, sha: String) -> String? {
        let state = store.state, task = state.task(id: id)
        return PublicationGuard.recheck(task: task, run: task?.operated.flatMap { state.run(id: $0.runId) },
                                        ownership: ownership, acceptedSHA: sha)
    }

    /// A completed step: on the task, and on disk before the next step starts.
    private func record(_ publication: TaskPublication, for id: UUID) throws {
        store.mutate { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
            state.tasks[index].operated?.publication = publication
            if let number = publication.mergeRequestNumber, let url = publication.mergeRequestURL {
                state.tasks[index].mr = MergeRequestRef(iid: number, title: state.tasks[index].title, url: url)
            }
        }
        guard store.flush() else { throw NotSaved() }
    }

    private func apply(_ outcome: TaskPublisher.Outcome, to id: UUID) -> Result {
        switch outcome {
        case .refused(let reason):
            return Result(store.state.task(id: id)?.operated?.publication, result: "refused", reason: reason)
        case .published(let publication):
            // The end is carried out on the host already: the state follows whatever the save does.
            store.mutate { state in
                guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
                state.tasks[index].operated?.state = .published
            }
            _ = store.flush()
            return Result(publication, result: "published", reason: nil)
        case .waiting(let publication, let why):
            watch(id)
            return Result(publication, result: "waitingToMerge", reason: why)
        case .blocked(let publication, let why):
            // Merged on the host with commits nobody accepted: yours to decide, never polled again.
            if publication.mergedSHA != nil, !publication.merged { mergedOnHost(id, why) }
            return Result(publication, result: "blocked", reason: why)
        }
    }

    /// Polls until the merge is done or stuck, each poll through `run`, so it never overlaps the
    /// operator's own call. A poll that finds the operation paused or ended, or the task no longer the
    /// operator's, is refused and ends the watch without a word: you did that, and the operator hears
    /// of it from you. Three failures in a row to reach the host end it, as a stuck one: the operator
    /// is told and its next `finish_task` starts again. Nothing is watched that is not watchable now —
    /// a poll that answers after a Pause does not start a watch again. The entry is cleared when the
    /// poll ends — unless `stopWatching` replaced it meanwhile with a newer one.
    private func watch(_ id: UUID) {
        guard watchers[id] == nil, isWatchable(id) else { return }
        let current = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.sleep(OperatorTiming.mergePoll) } catch { return }
                guard !Task.isCancelled else { return }
                let result = await self.run(id, restart: false)
                if result.result == "waitingToMerge" { failures = 0; continue }
                if result.result == "failed" { failures += 1; if failures < 3 { continue } }
                if result.result != "refused" { self.changed(id) }
                return
            }
        }
        watchers[id] = current
        Task { [weak self] in
            _ = await current.value
            if let self, self.watchers[id] == current { self.watchers[id] = nil }
        }
    }

    /// Why a host could not be had for the project's origin, as Settings would fix it.
    static func unavailable(_ error: Error) -> String {
        switch error as? MergeRequestSearch.Unavailable {
        case .notConnected(let host)?: return "Connect \(host.name) in Settings › Integrations first."
        case .noRepositoryPath(let host)?: return "The project's origin names no repository on \(host.name)."
        case .otherGitLabHost(let remote, let configured)?:
            return "The project's origin is on \(remote ?? "another host"), not the GitLab in Settings (\(configured ?? "none"))."
        case nil: return error.localizedDescription
        }
    }

    /// A step's failure as the operator reads it. A push that ran out of time may have landed: the
    /// next call asks origin before it pushes again, so it is never said that nothing was pushed.
    static func failure(_ error: Error, branch: String) -> String {
        if error is TaskPublisher.PushTimedOut || (error as? GitError).map({ $0.timedOut && $0.args.contains("push") }) == true {
            return "The push of \(branch) timed out, so the push may have landed; call finish_task again, which asks origin before it pushes."
        }
        return GitError.displayReason(of: error)
    }
}
