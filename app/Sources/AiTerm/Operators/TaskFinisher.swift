import Foundation
import Synchronization
import AiTermCore

/// `finish_task` (spec §6), as the app runs it: `TaskPublisher` carries the task's end forward,
/// each step saved to the workspace — and flushed — as it completes (spec §11: a crash between push
/// and MR resumes at the MR); a step that cannot be saved stops everything after it. One publication
/// per task runs at a time: a second call — the operator's retry after the daemon gave up waiting, or
/// a watch's poll — waits for the one in flight and answers what it did. A merge end that must wait
/// is watched here, polling every `OperatorTiming.mergePoll`, until it merges, the host gives a reason
/// it will not, or the wait runs out; then the operator is told (`changed`). The tool call itself never
/// waits for a merge: it answers `waitingToMerge` at once. A merge end whose accepted commit is already in its default
/// branch, merged outside `finish_task`, is recorded as merged with nothing pushed, merged or written (`finishLanded`).
///
/// The host is the one the push goes to: origin's fetch URL, never `Repository.remoteUrl()`, which
/// prefers the branch's upstream remote — the protection asked about must be the pushed repository's.
@MainActor
final class TaskFinisher {
    /// What `finish_task` answers the operator: what was done, whatever the outcome.
    struct Result: Codable, Equatable, Sendable {
        /// How the call ended, by the word the Operator reads in `result`.
        enum Kind: String, Codable, Sendable {
            case published, inReview, waitingToMerge, blocked, refused, failed, leftForYou
        }

        var result: Kind
        var reason: String?
        var mergeRequest: String?
        var pushedSHA: String?
        var merged: Bool
        var mergedSHA: String?
        /// What this call did to the request's draft state, in a few plain words (`MR !12 opened as a draft`, `opened, ready`,
        /// `left as a draft`, `marked ready`): so the Operator needn't ask the host. Nil when this call did nothing to it.
        var draftNote: String?

        init(result: Kind, reason: String? = nil, mergeRequest: String? = nil, pushedSHA: String? = nil,
             merged: Bool = false, mergedSHA: String? = nil, draftNote: String? = nil) {
            self.result = result; self.reason = reason; self.mergeRequest = mergeRequest
            self.pushedSHA = pushedSHA; self.merged = merged; self.mergedSHA = mergedSHA; self.draftNote = draftNote
        }

        init(_ publication: TaskPublication?, result: Kind, reason: String?) {
            let publication = publication ?? TaskPublication()
            self.init(result: result, reason: reason, mergeRequest: publication.mergeRequestURL,
                      pushedSHA: publication.pushedSHA, merged: publication.merged, mergedSHA: publication.mergedSHA)
        }
    }

    /// The last thing an advance did to the request's draft state, written from the publisher's task and read after it.
    private final class DraftNews: Sendable {
        private let event = Mutex<TaskPublisher.DraftEvent?>(nil)
        func record(_ new: TaskPublisher.DraftEvent) { event.withLock { $0 = new } }
        var last: TaskPublisher.DraftEvent? { event.withLock { $0 } }
    }

    /// A step done but not saved: nothing more is done outside this machine.
    struct NotSaved: Error {}
    static let notSavedReason = "AiTerm couldn’t save what it has done so far, so it stopped before the next step. Call finish_task again once the workspace saves."

    private let store: WorkspaceStore
    private let git: any GitRunning
    private let codeHost: CodeHostCheck
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Told when a watched merge ends — merged, blocked, out of time. The controller sets it after its own
    /// init, so this init captures no `self` of the controller's.
    var changed: @MainActor (UUID) -> Void
    /// Told when the host merged the task's request with a head nobody accepted, and why: a question for
    /// you (the controller's), never retried. Set like `changed`.
    var mergedOnHost: @MainActor (UUID, String) -> Void = { _, _ in }
    /// Told when a watch stopped because a poll was refused for a reason that is not the broadcast's own
    /// state — the branch moved, the task changed hands — with that reason, recorded as the problem. Set
    /// like `changed`.
    var watchStopped: @MainActor (UUID, String) -> Void = { _, _ in }
    /// Each task's publication in flight.
    private var inFlight: [UUID: Task<Result, Never>] = [:]
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var isStopped = false
    /// How many calls found a publication in flight and waited for it; for a test.
    private(set) var joined = 0
    /// Asks the login shell again (`LoginShellLocator.refresh`), blocking: run off the main actor. A hook that
    /// did not find its tool ran with a PATH that may have changed since it was read (an install, a new nvm
    /// default), and git takes the next push's from the same answers. The old answers stand until the shell
    /// answers, so one that fails or times out under load leaves git the PATH it had, never launchd's. A test
    /// passes its own.
    var refreshLogin: @Sendable () -> Void = {
        LoginShellLocator.shared.refresh()
    }

    init(store: WorkspaceStore, git: any GitRunning,
         connect: @escaping @Sendable (RemoteInfo) throws -> any MergeRequestPublishing,
         now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
         changed: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.store = store; self.git = git; self.codeHost = CodeHostCheck(git: git, publisher: connect)
        self.now = now; self.sleep = sleep; self.changed = changed
    }

    /// The tasks whose merge is being watched.
    var watching: Set<UUID> { Set(watchers.keys) }
    /// The tasks with a publication in flight.
    var running: Set<UUID> { Set(inFlight.keys) }

    /// What a takeover records on a waiting merge: it is watched again only after a new `finish_task`.
    static let takenOverProblem = "taken over by you; call finish_task again once it's handed back"

    /// The operator's `finish_task`: clears a recorded problem and goes on from the saved steps. While its
    /// merge is watched it is one more poll, so asking again never starts the bounded wait over. `noVerify`
    /// pushes past the repository's push hooks (spec §B), the Oracle having judged the call: only once the hook
    /// refused the push of the commit accepted now and showed what it says (`TaskPublication.pushFailure(for:)`).
    /// A task with that commit pushed already, or done, answers from the record as any repeat does.
    func finish(_ id: UUID, noVerify: Bool = false) async -> Result {
        guard !isStopped else { return Result(result: .refused, reason: Self.closingReason) }
        if noVerify, let operated = store.state.task(id: id)?.operated, Self.stillToPush(operated),
           operated.publication?.pushFailure(for: operated.acceptance?.resultSHA) == nil {
            return Result(operated.publication, result: .refused, reason: Self.noFailedPush)
        }
        return await run(id, restart: watchers[id] == nil, noVerify: noVerify)
    }

    /// Why a `noVerify` is refused before any push the hook refused.
    static let noFailedPush = "Push without noVerify first, so the hook's output is known."

    /// Whether the accepted commit is still to be pushed: not on origin by AiTerm's record, and the task's end not done.
    static func stillToPush(_ operated: OperatedTask) -> Bool {
        let publication = operated.publication
        return operated.state != .published && publication?.merged != true && publication?.leftForYou != true
            && publication?.pushedSHA != operated.acceptance?.resultSHA
    }

    /// At launch, and whenever a broadcast runs again — your Resume, its operator back from offline:
    /// watch every merge end (of `run`, or of every broadcast) that was waiting and is watchable. A task
    /// watched already is not watched twice, and one with a recorded problem waits for `finish_task`.
    func resumeWatching(inRun run: UUID? = nil) {
        for task in store.state.tasks where run == nil || task.operated?.runId == run { watch(task.id) }
    }

    /// On a takeover: the watch stops, and a merge waiting is disarmed for good — its problem recorded,
    /// so neither a hand back, a Resume nor a relaunch watches it again until the operator's next
    /// `finish_task`.
    func disarm(_ id: UUID, because why: String) {
        stopWatching(id)
        guard let operated = store.state.task(id: id)?.operated, operated.end == .merge, operated.state == .accepted,
              let publication = operated.publication, publication.mergeRequestNumber != nil,
              !publication.merged, publication.mergedSHA == nil, publication.problem == nil else { return }
        store.mutate { $0.updateOperated(id) { $0.publication?.problem = why } }
        _ = store.flush()
    }

    static let closingReason = "AiTerm is closing."

    func start() { isStopped = false }

    /// When AiTerm quits: every watch. Replies to writes already sent are still saved, but cannot
    /// start a subsequent write or another watch.
    func stopAll() {
        isStopped = true
        for id in Array(watchers.keys) { stopWatching(id) }
    }

    /// On a takeover or a stopped task.
    func stopWatching(_ id: UUID) {
        watchers.removeValue(forKey: id)?.cancel()
    }

    /// On a Pause or an End: every watch of the broadcast's tasks.
    func stopWatching(inRun run: UUID) {
        for id in Array(watchers.keys) where store.state.task(id: id)?.operated?.runId == run { stopWatching(id) }
    }

    /// A merge end opened and waiting, not stuck, in a broadcast that runs and that you have neither
    /// paused nor ended, and still the operator's.
    private func isWatchable(_ id: UUID) -> Bool {
        guard !isStopped else { return false }
        guard let operated = store.state.task(id: id)?.operated, operated.end == .merge, operated.state == .accepted,
              !operated.takenOver, !operated.flags.contains(.upstreamReplaced),
              let publication = operated.publication, publication.mergeRequestNumber != nil,
              !publication.merged, publication.mergedSHA == nil, publication.problem == nil,
              let run = store.state.run(id: operated.runId), run.intent == nil
        else { return false }
        return run.state == .active || run.state == .complete
    }

    /// The one way a publication runs: joined when one is in flight for the task.
    private func run(_ id: UUID, restart: Bool, noVerify: Bool = false) async -> Result {
        guard !isStopped else { return Result(result: .refused, reason: Self.closingReason) }
        if let running = inFlight[id] {
            joined += 1
            return await running.value
        }
        let started = Task { await self.advance(id, restart: restart, noVerify: noVerify) }
        inFlight[id] = started
        let result = await started.value
        if inFlight[id] == started { inFlight[id] = nil }
        return result
    }

    /// A publication's step, and what the Merge slice kept from happening left for you once (spec §5).
    private func advance(_ id: UUID, restart: Bool, noVerify: Bool) async -> Result {
        let result = await publish(id, restart: restart, noVerify: noVerify)
        if result.result == .refused, let reason = result.reason,
           let task = store.state.task(id: id), let operated = task.operated,
           operated.state == .accepted, Self.permanent(reason) {
            let project = store.state.project(id: task.projectId)?.name ?? "its project"
            let remaining = operated.end.merges ? "Merge \(task.branch) in \(project)" : "Push \(task.branch) in \(project) and open its merge request"
            leaveForYou("\(remaining): \(reason)", in: operated.runId) { state in
                state.updateOperated(id) {
                    var publication = $0.publication ?? TaskPublication()
                    publication.leftForYou = true
                    publication.problem = nil
                    $0.publication = publication
                }
            }
        }
        return result
    }

    private static func permanent(_ reason: String) -> Bool {
        reason == PublicationGuard.mergeSliceOff || reason == PublishRefusal.noOrigin.localizedDescription
            || reason.contains("no connected code host") || reason.hasSuffix(TaskPublisher.neverPushesProtected)
            || reason.contains("branch is the default branch")
    }

    /// `sentence` in the run's Left for you, once, saved in one change with `also`.
    private func leaveForYou(_ sentence: String, in run: UUID, also: (inout AppState) -> Void = { _ in }) {
        store.mutate { state in
            also(&state)
            state.updateRun(id: run) { if !$0.leftForYou.contains(sentence) { $0.leftForYou.append(sentence) } }
        }
        _ = store.flush()
    }

    private func publish(_ id: UUID, restart: Bool, noVerify: Bool) async -> Result {
        guard var first = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
        // A task in review: this finish_task ends the review (spec §5). A draft end is then published; a merge end
        // goes on to its merge.
        if first.operated.state == .inReview {
            if let ended = endReview(first) { return ended }
            guard let fresh = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
            first = fresh
        }
        // Merged outside finish_task, even after it was left for you: recorded as it is, nothing more done.
        if let landed = await finishLanded(first) { return landed }
        let task = first.task, operated = first.operated, project = first.project
        // What is done is answered from the record, whatever the host's connection is now.
        if operated.publication?.leftForYou == true { return Result(operated.publication, result: .leftForYou, reason: nil) }
        if operated.state == .published || operated.publication?.merged == true {
            return apply(.published(operated.publication ?? TaskPublication()), to: id)
        }
        let repository = Repository(project.path, git: git), branch = task.branch
        let host: any MergeRequestPublishing
        do {
            // What the plan or the broadcast rules out is said before any host is asked for.
            let (defaultBranch, tip) = try await BackgroundWork.run { (repository.defaultBranch(), try repository.tip(of: branch)) }
            guard let fresh = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
            if let refusal = PublicationGuard.refusal(task: fresh.task, run: fresh.run, parent: fresh.parent,
                                                      defaultBranch: defaultBranch, branchTip: tip) {
                return Result(fresh.operated.publication, result: .refused, reason: refusal)
            }
            // A local merge asks no host and pushes nothing.
            if fresh.operated.end == .mergeLocal { return await mergeLocally(fresh, repository: repository) }
            host = try await codeHost.host(of: project)
        } catch CodeHostCheck.Failure.noOrigin {
            return Result(store.state.task(id: id)?.operated?.publication, result: .refused, reason: PublishRefusal.noOrigin.localizedDescription)
        } catch CodeHostCheck.Failure.unavailable(let error) {
            let reason = error is MergeRequestSearch.Unavailable ? "\(project.name) has no connected code host." : Self.unavailable(error)
            return Result(store.state.task(id: id)?.operated?.publication, result: .refused, reason: reason)
        } catch {
            let cause = if case CodeHostCheck.Failure.unreadable(let gitError) = error { gitError } else { error }
            let why = GitError.displayReason(of: cause)
            recordFailure(why, on: id)
            return Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: why)
        }
        // Read fresh: the checks above awaited git.
        guard let current = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
        let ownership = current.operated.ownership, accepted = current.operated.acceptance?.resultSHA ?? ""
        let drafted = DraftNews(), step = steps(of: id, ownership: ownership, sha: accepted)
        let publisher = TaskPublisher(repository: repository, host: host, now: now, noted: { drafted.record($0) })
        do {
            let outcome = try await publisher.advance(
                TaskPublisher.Context(task: current.task, run: current.run, parent: current.parent,
                                      forReview: TaskPublisher.Context.entersReview(current.operated, run: current.run)),
                restart: restart, noVerify: noVerify, recheck: step.recheck, record: step.record)
            var result = apply(outcome, to: id, forReview: TaskPublisher.Context.entersReview(current.operated, run: current.run))
            result.draftNote = draftNote(drafted, of: id)
            return result
        } catch is NotSaved {
            var failed = Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: Self.notSavedReason)
            failed.draftNote = draftNote(drafted, of: id)
            return failed
        } catch {
            let why = Self.failure(error, branch: branch)
            if let git = error as? GitError, Self.commandNotFound(git) {
                let refresh = refreshLogin
                await BackgroundWork.run { refresh() }
            }
            recordFailure(why, on: id, hookSaid: (error as? GitError).flatMap(Self.hookRefusal).map { ($0, accepted) })
            var failed = Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: why)
            failed.draftNote = draftNote(drafted, of: id)
            return failed
        }
    }

    /// What this call did to the task's request, if anything: even one that failed afterwards opened or marked it ready first.
    private func draftNote(_ news: DraftNews, of id: UUID) -> String? {
        let publication = store.state.task(id: id)?.operated?.publication
        return Self.draftNote(news.last, request: publication?.mergeRequestURL, number: publication?.mergeRequestNumber)
    }

    /// `event` in the words `Result.draftNote` says: `MR !12 opened as a draft`, with `#12` on GitHub. Nil without a request.
    static func draftNote(_ event: TaskPublisher.DraftEvent?, request url: String?, number: Int?) -> String? {
        guard let event, let url, let number else { return nil }
        let reference = CodeHost(webURL: url).reference(number)
        switch event {
        case .opened(draft: true): return "MR \(reference) opened as a draft"
        case .opened(draft: false): return "MR \(reference) opened, ready"
        case .leftDraft: return "MR \(reference) left as a draft"
        case .markedReady: return "MR \(reference) marked ready"
        case .leftReady: return nil
        }
    }

    /// A publication that failed — a push its pre-push hook refused, a host that errored — or a watch that has to
    /// stop for what it found, recorded as the task's problem and saved, so its line says `blocked` and why, not
    /// `opening the MR` for as long as it waits for you, and nothing watches it again: the next `finish_task` clears
    /// it (`TaskPublisher`). `hookSaid`, for a push the hook
    /// refused, is kept as `lastPushFailure` with the commit it refused, for the Oracle to judge a `noVerify` by.
    private func recordFailure(_ why: String, on id: UUID, hookSaid: (output: String, sha: String)? = nil) {
        store.mutate { state in
            state.updateOperated(id) {
                var publication = $0.publication ?? TaskPublication()
                publication.problem = why
                if let hookSaid { publication.lastPushFailure = hookSaid.output; publication.lastPushFailureSHA = hookSaid.sha }
                $0.publication = publication
            }
        }
        _ = store.flush()
    }

    /// A local merge end (spec §5): merged into the project's own checkout's default branch and recorded as published;
    /// pushing that branch is left for you.
    private func mergeLocally(_ current: Context, repository: Repository) async -> Result {
        let id = current.task.id
        let step = steps(of: id, ownership: current.operated.ownership, sha: current.operated.acceptance?.resultSHA ?? "")
        do {
            let outcome = try await TaskPublisher.mergeLocally(
                TaskPublisher.Context(task: current.task, run: current.run, parent: current.parent), repository: repository,
                recheck: step.recheck, record: step.record)
            let result = apply(outcome, to: id)
            if result.result == .published, let into = result.merged ? store.state.task(id: id)?.operated?.publication?.targetBranch : nil {
                leaveForYou("Push \(into) in \(current.project.name): merged locally.", in: current.run.id)
            }
            return result
        } catch is NotSaved {
            return Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: Self.notSavedReason)
        } catch {
            let why = GitError.displayReason(of: error)
            recordFailure(why, on: id)
            return Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: why)
        }
    }

    /// Where `sha` already is in the default branch of the checkout at `path`, the branch a merge end merges into, and which
    /// branch that is (`Repository.landing`); nil when it is in neither that branch nor origin's as last fetched, or git
    /// couldn't say. Read off the main actor.
    nonisolated static func landing(of sha: String, in path: String, git: any GitRunning) async -> (target: String, landing: Repository.Landing)? {
        let repository = Repository(path, git: git)
        return await BackgroundWork.run {
            let target = repository.defaultBranch()
            guard let landing = try? repository.landing(of: sha, in: target) else { return nil }
            return (target, landing)
        }
    }

    /// A merge end whose accepted commit reached its target outside `finish_task` (a worker's or your merge), recorded as
    /// merged: nil when it has not, and for anything but an accepted merge end. Nothing is pushed or merged and the host
    /// is only read, so none of what authorises those is asked for: not the Merge slice, the Oracle's yes, the branch's
    /// tip nor a stacked parent's end (`PublicationGuard.landedRefusal`). Its problem and the Oracle's refusal go with it.
    /// Left for you: pushing a target that has it only here, and closing a request still open from its branch.
    private func finishLanded(_ first: Context) async -> Result? {
        let id = first.task.id, operated = first.operated
        guard operated.end.merges, operated.state == .accepted, let sha = operated.acceptance?.resultSHA,
              operated.publication?.merged != true, operated.publication?.mergedSHA == nil,
              let (target, landing) = await Self.landing(of: sha, in: first.project.path, git: git) else { return nil }
        // Read fresh: the look awaited git. It holds only for the commit accepted now, by the owner it was looked at under.
        guard let current = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
        guard current.operated.acceptance?.resultSHA == sha, current.operated.ownership == operated.ownership else {
            return Result(current.operated.publication, result: .refused, reason: PublicationGuard.changedMidway)
        }
        if let refusal = PublicationGuard.landedRefusal(task: current.task, run: current.run) {
            return Result(current.operated.publication, result: .refused, reason: refusal)
        }
        store.mutate { state in
            state.updateOperated(id) { task in
                var publication = task.publication ?? TaskPublication()
                publication.merged = true
                publication.landedSHA = sha
                publication.targetBranch = target
                publication.problem = nil
                publication.mergeRefusal = nil
                publication.waitingSince = nil
                publication.readySince = nil
                publication.waitingReason = nil
                publication.leftForYou = false
                task.publication = publication
                task.state = .published
            }
        }
        _ = store.flush()
        let project = current.project.name, key = current.operated.key
        var left: [String] = []
        if !landing.origin { left.append("Push \(target) in \(project): \(key)'s commit is in it locally, not in origin/\(target) as last fetched.") }
        if let request = await openRequest(of: current) {
            let unread = request.read ? "" : " if it is still open"
            left.append("Close \(request.name) in \(project) without merging\(unread): its commit is already in \(target).")
        }
        for sentence in left { leaveForYou(sentence, in: current.run.id) }
        let place = landing.origin ? "already in \(target) on origin" : "already in \(target) locally"
        let reason = "\(key)'s accepted commit \(sha.prefix(7)) is \(place), so AiTerm recorded it as merged without pushing, merging or "
            + "writing to the host." + (left.isEmpty ? "" : " Left for you: " + left.joined(separator: " "))
        return Result(store.state.task(id: id)?.operated?.publication, result: .published, reason: reason)
    }

    /// The request still open from `current`'s branch, as the host reads it (`read`), named as `requestName` does. When the
    /// host can't be read, the one recorded, if any, unread; nil when the host has none open.
    private func openRequest(of current: Context) async -> (name: String, read: Bool)? {
        let recorded = current.operated.publication.flatMap { publication in
            publication.mergeRequestNumber.map { (name: Self.requestName($0, url: publication.mergeRequestURL ?? ""), read: false) }
        }
        guard let host = try? await codeHost.host(of: current.project) else { return recorded }
        do {
            return try await host.existingRequest(from: current.task.branch).map { (name: Self.requestName($0.iid, url: $0.url), read: true) }
        } catch {
            return recorded
        }
    }

    /// A request by its host's own words: `PR #3` on GitHub, `MR !12` on GitLab.
    static func requestName(_ number: Int, url: String) -> String {
        let host = CodeHost(webURL: url)
        return (host == .gitHub ? "PR " : "MR ") + host.reference(number)
    }

    /// The task, its record, its broadcast, its project and the parent it is stacked on, as they are now.
    private struct Context {
        let task: TaskItem, operated: OperatedTask, run: OperatorRun, project: Project, parent: TaskItem?
    }

    private func context(of id: UUID) -> Context? {
        let state = store.state
        guard let task = state.task(id: id), let operated = task.operated,
              let run = state.run(id: operated.runId), let project = state.project(id: task.projectId) else { return nil }
        return Context(task: task, operated: operated, run: run, project: project, parent: operated.stackedOn.flatMap { state.task(id: $0) })
    }

    /// What a publication of `id` checks before each step and saves after it (`recheck`, `record`), under the ownership
    /// and accepted commit it started with.
    private func steps(of id: UUID, ownership: Int, sha: String)
        -> (recheck: @Sendable () async -> String?, record: @Sendable (TaskPublication) async throws -> Void) {
        let evidence = context(of: id).map { PublicationGuard.evidence(task: $0.task, run: $0.run) }
        return ({ @MainActor [weak self] in
            guard let self else { return PublicationGuard.gone }
            return self.recheck(id, ownership: ownership, sha: sha, evidence: evidence)
        }, { @MainActor [weak self] publication in
            guard let self else { throw NotSaved() }
            try self.record(publication, for: id, ownership: ownership)
        })
    }

    /// Read fresh before every step that changes something outside this machine.
    private func recheck(_ id: UUID, ownership: Int, sha: String, evidence: String?) -> String? {
        guard !isStopped else { return Self.closingReason }
        let state = store.state, task = state.task(id: id)
        return PublicationGuard.recheck(task: task, run: task?.operated.flatMap { state.run(id: $0.runId) },
                                        ownership: ownership, acceptedSHA: sha, expectedEvidence: evidence)
    }

    /// A completed step: on the task, and on disk before the next step starts. A task gone from the
    /// workspace holds nothing, so the step is not saved. A problem recorded since the publication began
    /// under another owner — a takeover's — is kept: only the operator's own `finish_task` clears it.
    private func record(_ publication: TaskPublication, for id: UUID, ownership: Int) throws {
        guard store.state.task(id: id)?.operated != nil else { throw NotSaved() }
        store.mutate { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }), let operated = state.tasks[index].operated else { return }
            var publication = publication
            // Progress from an awaited step must not restore authority invalidated by newer settings/evidence.
            publication.conditionsHeld = operated.publication?.conditionsHeld
            publication.conditionsEvidence = operated.publication?.conditionsEvidence
            publication.mergeRefusal = operated.publication?.mergeRefusal
            if operated.ownership != ownership, let problem = operated.publication?.problem { publication.problem = problem }
            state.tasks[index].operated?.publication = publication
            if let number = publication.mergeRequestNumber, let url = publication.mergeRequestURL {
                state.tasks[index].mr = MergeRequestRef(iid: number, title: state.tasks[index].title, url: url)
            }
        }
        guard store.flush() else { throw NotSaved() }
    }

    /// The task's broadcast does not run now — paused, ended, its operator offline, its plan not submitted:
    /// a watch refused for that is suspended, not stopped, and picked up when the broadcast runs again.
    private func isSuspended(_ id: UUID) -> Bool {
        guard let operated = store.state.task(id: id)?.operated, let run = store.state.run(id: operated.runId) else { return false }
        return run.intent != nil || !(run.state == .active || run.state == .complete)
    }

    /// What `finish_task` answers once a task went into review.
    static let inReviewReason = "People review it now: AiTerm wakes you when a reviewer opens or resolves a thread or approves it. "
        + "Have its agent fix the feedback, accept the new commit and call finish_task to push it. Call finish_task once more to end the review."

    /// Ends a task's review: nil once a merge end is accepted again and may go on to its merge, otherwise the
    /// answer. Refused while the broadcast does not run or you have the task.
    private func endReview(_ context: Context) -> Result? {
        let id = context.task.id, operated = context.operated
        if let why = PublicationGuard.runRefusal(context.run) { return Result(operated.publication, result: .refused, reason: why) }
        if operated.takenOver {
            return Result(operated.publication, result: .refused, reason: "You've taken \(operated.key) over; its review ends only once you hand it back.")
        }
        let merges = operated.end == .merge
        store.mutate { state in
            state.updateOperated(id) { task in
                var review = task.peopleReview ?? PeopleReview()
                review.ended = true
                task.peopleReview = review
                task.state = merges ? .accepted : .published
            }
        }
        _ = store.flush()
        return merges ? nil : Result(operated.publication, result: .published, reason: nil)
    }

    private func apply(_ outcome: TaskPublisher.Outcome, to id: UUID, forReview: Bool = false) -> Result {
        switch outcome {
        case .refused(let reason):
            return Result(store.state.task(id: id)?.operated?.publication, result: .refused, reason: reason)
        case .published(let publication) where forReview:
            // Its request is open as a draft: people review it now, and nothing ends until the review does.
            store.mutate { state in
                state.updateOperated(id) { task in
                    task.state = .inReview
                    var review = task.peopleReview ?? PeopleReview()
                    if review.startedAt == nil { review.startedAt = now() }
                    task.peopleReview = review
                }
            }
            _ = store.flush()
            return Result(publication, result: .inReview, reason: Self.inReviewReason)
        case .published(let publication):
            // The end is carried out on the host already: the state follows whatever the save does.
            store.mutate { state in
                guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
                state.tasks[index].operated?.state = .published
            }
            _ = store.flush()
            return Result(publication, result: .published, reason: nil)
        case .waiting(let publication, let why):
            store.mutate { $0.updateOperated(id) { $0.publication?.waitingReason = why } }
            _ = store.flush()
            watch(id)
            return Result(publication, result: .waitingToMerge, reason: why)
        case .blocked(let publication, let why):
            // Merged on the host with commits nobody accepted: yours to decide, never polled again.
            if publication.mergedSHA != nil, !publication.merged { mergedOnHost(id, why) }
            return Result(publication, result: .blocked, reason: why)
        }
    }

    /// Polls until the merge is done or stuck, each poll through `run`, so it never overlaps the
    /// operator's own call. A watch never ends without a word:
    /// - refused while the broadcast does not run (a pause, an end, the operator offline), it is
    ///   suspended — your own act has its own line, and the operator back is told `reconnected` — and
    ///   `resumeWatching(inRun:)` picks it up when the broadcast runs again;
    /// - refused for anything else (the branch moved, the task changed hands, gone), the reason is
    ///   recorded as the problem and the operator told once (`watchStopped`);
    /// - three failures in a row to reach the host end it as a stuck one, the last reason recorded;
    /// - merged, blocked or out of time, the operator is told (`changed`).
    /// A watch stopped meanwhile (`stopWatching`, `disarm`) says nothing. Nothing is watched that is not
    /// watchable now — a poll that answers after a Pause does not start a watch again. The entry is
    /// cleared when the poll ends — unless `stopWatching` replaced it meanwhile with a newer one.
    private func watch(_ id: UUID) {
        guard watchers[id] == nil, isWatchable(id) else { return }
        let current = Task { [weak self] in
            // Not cancelled, it is still the task's watch (`stopWatching` cancels the one it removes): its entry goes with it.
            defer { if !Task.isCancelled { self?.watchers[id] = nil } }
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.sleep(OperatorTiming.mergePoll) } catch { return }
                guard !Task.isCancelled else { return }
                let result = await self.run(id, restart: false)
                guard !Task.isCancelled else { return }
                switch result.result {
                case .waitingToMerge:
                    failures = 0
                    continue
                case .refused:
                    guard !self.isSuspended(id), self.store.state.task(id: id)?.operated != nil else { return }
                    let why = result.reason ?? PublicationGuard.changedMidway
                    self.recordFailure(why, on: id)
                    self.watchStopped(id, why)
                case .failed:
                    failures += 1
                    if failures < 3 { continue }
                    self.recordFailure(result.reason ?? "AiTerm couldn’t reach the host", on: id)
                    self.changed(id)
                default:
                    self.changed(id)
                }
                return
            }
        }
        watchers[id] = current
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
        if let git = error as? GitError, let said = hookRefusal(git) {
            return "The pre-push hook refused the push of \(branch): \(said)"
        }
        return GitError.displayReason(of: error)
    }

    /// A push whose hook (or git) said a command was not found: the PATH it ran with did not have it.
    static func commandNotFound(_ error: GitError) -> Bool {
        error.args.contains("push") && !error.timedOut
            && (error.pushReason.contains("command not found") || error.stderr.contains("command not found"))
    }

    /// What a pre-push hook said when it refused a push, all of it (`GitError.pushReason`); nil for any other
    /// failure. git says only "failed to push some refs" then, and a push that reached origin prints `To <url>`
    /// first, so one that failed without it never left this machine.
    static func hookRefusal(_ error: GitError) -> String? {
        guard error.args.contains("push"), !error.timedOut, error.stderr.contains("failed to push some refs"),
              !error.stdout.split(separator: "\n").contains(where: { $0.hasPrefix("To ") }) else { return nil }
        let said = error.pushReason
        return said.isEmpty ? "it said nothing" : said
    }
}
