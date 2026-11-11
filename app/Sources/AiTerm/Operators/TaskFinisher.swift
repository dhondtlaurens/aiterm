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
/// The Operator's call waits for its publication only within its reply budget, inside the daemon's wait for the app's
/// answer: past it, the call answers `running` with what is done so far, and the publication goes on. The task's next
/// call joins it, or once it ended answers what it did (`kept`); one that ended with no call waiting on it wakes the
/// Operator (`finishedLate`). That an answer is owed is saved on the publication (`unanswered`).
///
/// The host is the one the push goes to: origin's fetch URL, never `Repository.remoteUrl()`, which
/// prefers the branch's upstream remote — the protection asked about must be the pushed repository's.
@MainActor
final class TaskFinisher {
    /// What `finish_task` answers the operator: what was done, whatever the outcome.
    struct Result: Codable, Equatable, Sendable {
        /// How the call ended, by the word the Operator reads in `result`. `running`: the publication outlived the call's
        /// reply budget and goes on.
        enum Kind: String, Codable, Sendable {
            case published, inReview, waitingToMerge, blocked, refused, failed, leftForYou, running
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

    /// The last thing an advance did to the request's draft state, and whether it couldn't assign it, written from the
    /// publisher's task and read after it.
    private final class DraftNews: Sendable {
        private let event = Mutex<TaskPublisher.DraftEvent?>(nil)
        private let unassigned = Mutex<TaskPublisher.DraftEvent?>(nil)
        func record(_ new: TaskPublisher.DraftEvent) {
            if case .notAssigned = new { unassigned.withLock { $0 = new } } else { event.withLock { $0 = new } }
        }
        var last: TaskPublisher.DraftEvent? { event.withLock { $0 } }
        var notAssigned: TaskPublisher.DraftEvent? { unassigned.withLock { $0 } }
    }

    /// The Operator's `finish_task`, as the tool handler passes it on (`finish(_:noVerify:content:budget:joinOnly:)`).
    struct Call: Sendable {
        var noVerify = false
        var content: RequestContent?
        var budget: Duration?
        var joinOnly = false
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
    /// Each task's publication in flight, and the token that tells it from a later one.
    private var inFlight: [UUID: (token: UUID, task: Task<Result, Never>)] = [:]
    /// The Operator's calls waiting on each task's publication now, within their budget.
    private var listening: [UUID: Int] = [:]
    /// What a publication that outlived its call did, for the task's next call, with the accepted commit it ran on.
    private var kept: [UUID: (sha: String, result: Result)] = [:]
    /// The publication whose call answered `running`, by its token: only its end is kept and wakes the Operator, never a
    /// merge watch's later polls.
    private var owedFlights: [UUID: UUID] = [:]
    /// Told when a publication whose call answered `running` ended with no call waiting on it. Set like `changed`.
    var finishedLate: @MainActor (UUID) -> Void = { _ in }
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

    /// The accepted tasks the Operator is steering now (`message_task`, `open_tab`), each with how many of its calls hold
    /// it: none of them is watched, and no publication of one starts, until the last call lets it go. A merge then never
    /// races a worker's new commits, not even while the message is on its way.
    private var held: [UUID: Int] = [:]

    /// Holds `id`'s publication while it is steered: its merge watch stops, and none starts.
    func hold(_ id: UUID) {
        held[id, default: 0] += 1
        stopWatching(id)
    }

    /// Lets `id`'s publication go once its last steering call ended: a task still accepted and waiting to merge (its
    /// message not delivered, its tab failed) is watched again; one back at work isn't watchable.
    func release(_ id: UUID) {
        guard let count = held[id] else { return }
        if count > 1 { held[id] = count - 1; return }
        held[id] = nil
        watch(id)
    }

    /// Why a publication of a task the Operator is steering waits.
    static func beingSteered(_ key: String) -> String {
        "\(key) is being steered now: call finish_task again once message_task or open_tab answers."
    }

    /// A publication of a task held for steering: refused with why, nothing done.
    private func steeringRefusal(_ id: UUID) -> Result? {
        guard held[id] != nil else { return nil }
        let operated = store.state.task(id: id)?.operated
        return Result(operated?.publication, result: .refused, reason: Self.beingSteered(operated?.key ?? "This task"))
    }

    /// What a takeover records on a waiting merge: it is watched again only after a new `finish_task`.
    static let takenOverProblem = "taken over by you; call finish_task again once it's handed back"

    /// The operator's `finish_task`: clears a recorded problem and goes on from the saved steps. While its
    /// merge is watched it is one more poll, so asking again never starts the bounded wait over. `noVerify`
    /// pushes past the repository's push hooks (spec §B), the Oracle having judged the call: only once the hook
    /// refused the push of the commit accepted now and showed what it says (`TaskPublication.pushFailure(for:)`).
    /// A task with that commit pushed already, or done, answers from the record as any repeat does.
    /// `content`, the Operator's title, description and assignee for the request, is saved before anything is done, so every
    /// later advance opens the request with it; only while no request is recorded, since one open is changed through
    /// `update_request`.
    ///
    /// `budget`, the Operator's call's: how long it waits for the publication before it answers `running`; nil waits until
    /// it ends. A call made while one is in flight joins it; one made once a publication outlived its call answers what it
    /// did (`owedAnswer`). `joinOnly`, a call the challenge gate let through only for that, never starts a publication.
    func finish(_ id: UUID, noVerify: Bool = false, content: RequestContent? = nil, budget: Duration? = nil,
                joinOnly: Bool = false) async -> Result {
        guard !isStopped else { return Result(result: .refused, reason: Self.closingReason) }
        // What a publication that outlived its call did is owed first, even while a merge watch's poll is in flight. With
        // nothing kept, the saved marker is read only once nothing runs: a run in flight is still the one it is owed for.
        if kept[id] != nil || inFlight[id] == nil, let owed = owedAnswer(id) { return owed }
        if let steered = steeringRefusal(id) { return steered }
        if inFlight[id] == nil, joinOnly {
            return Result(store.state.task(id: id)?.operated?.publication, result: .refused, reason: Self.nothingToJoin)
        }
        if noVerify, let operated = store.state.task(id: id)?.operated, Self.stillToPush(operated),
           operated.publication?.pushFailure(for: operated.acceptance?.resultSHA) == nil {
            return Result(operated.publication, result: .refused, reason: Self.noFailedPush)
        }
        if let content, !content.isEmpty, store.state.task(id: id)?.operated?.publication?.mergeRequestNumber == nil {
            store.mutate { state in
                state.updateOperated(id) {
                    var publication = $0.publication ?? TaskPublication()
                    publication.requested = content
                    $0.publication = publication
                }
            }
            // Unsaved, a restart would open the request without them: nothing is done.
            guard store.flush() else {
                return Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: Self.notSavedReason)
            }
        }
        let restart = watchers[id] == nil
        guard let budget else { return await run(id, restart: restart, noVerify: noVerify, operatorCall: true) }
        return await wait(for: id, restart: restart, noVerify: noVerify, budget: budget)
    }

    /// Why a call let through only to join a publication is refused when none runs or is owed any more.
    static let nothingToJoin = "No finish_task of this task is running or left to answer any more: call finish_task again, without a challengeId."

    /// Whether a `finish_task` of the task now joins a publication in flight or answers one that outlived its call: it decides
    /// nothing new, so the challenge gate neither asks the Oracle nor fetches.
    /// The saved marker alone counts only where it answers (`owedAnswer`): after a restart, a call on anything but a task in
    /// review resumes from the saved steps, through the gate as any call.
    func pending(_ id: UUID) -> Bool {
        if inFlight[id] != nil { return true }
        guard let operated = store.state.task(id: id)?.operated, let accepted = operated.acceptance?.resultSHA else { return false }
        if let late = kept[id], late.sha == accepted { return true }
        return operated.state == .inReview && operated.publication?.unanswered == accepted
    }

    /// The answer owed to this call, when a publication outlived the call that waited on it: what it did, kept since it
    /// ended. After a restart only the saved marker is left: a task back in review answers so (its fix-round push landed,
    /// and a call now must not end the review); anything else resumes from its saved steps, which repeats nothing. Either
    /// way the marker goes. Nil when nothing is owed for the commit accepted now.
    private func owedAnswer(_ id: UUID) -> Result? {
        let operated = store.state.task(id: id)?.operated, accepted = operated?.acceptance?.resultSHA
        let late = kept.removeValue(forKey: id), marked = operated?.publication?.unanswered
        owedFlights[id] = nil
        if marked != nil { setUnanswered(nil, on: id) }
        if let late, late.sha == accepted {
            var result = late.result
            result.reason = Self.earlier(result.reason)
            return result
        }
        guard let operated, late == nil, let marked, marked == accepted, operated.state == .inReview else { return nil }
        return Result(operated.publication, result: .inReview, reason: Self.earlier(Self.inReviewReason))
    }

    /// A kept answer's reason, saying it is the earlier call's.
    static func earlier(_ reason: String?) -> String {
        "This is what the earlier finish_task did after it answered running." + (reason.map { " " + $0 } ?? "")
    }

    /// The Operator's call, waiting for the publication within `budget`. One that ends in time is this call's answer, and
    /// nothing is owed. Past the budget, the call answers `running` and saves that an answer is owed: the publication's
    /// end keeps it for the next call (`ended`).
    private func wait(for id: UUID, restart: Bool, noVerify: Bool, budget: Duration) async -> Result {
        let flight = start(id, restart: restart, noVerify: noVerify, operatorCall: true)
        listening[id, default: 0] += 1
        let answered = await OperatorToolHandler.within(budget, cancelling: false) { await flight.task.value }
        listening[id, default: 1] -= 1
        if listening[id] == 0 { listening[id] = nil }
        // It may have ended in the turn the budget ran out: then its answer is this call's.
        if case .success(let result) = answered { return delivered(result, to: id) }
        if inFlight[id]?.token != flight.token { return delivered(await flight.task.value, to: id) }
        setUnanswered(store.state.task(id: id)?.operated?.acceptance?.resultSHA, on: id)
        owedFlights[id] = flight.token
        let publication = store.state.task(id: id)?.operated?.publication
        return Result(publication, result: .running, reason: Self.stillRunning(store.state.task(id: id)?.operated?.key ?? "the task"))
    }

    /// `result` answered to a call: nothing is owed any more.
    private func delivered(_ result: Result, to id: UUID) -> Result {
        kept[id] = nil
        owedFlights[id] = nil
        if store.state.task(id: id)?.operated?.publication?.unanswered != nil { setUnanswered(nil, on: id) }
        return result
    }

    /// What a call answers whose publication goes on past its budget.
    static func stillRunning(_ key: String) -> String {
        "AiTerm is still finishing \(key): pushedSHA and mergeRequest say what is done so far. It goes on; AiTerm wakes you when "
            + "it ends, and finish_task then answers what it did. A finish_task meanwhile waits for it again; it never repeats a step."
    }

    /// Saves (or clears, with nil) that the task's next call is owed a publication's answer.
    private func setUnanswered(_ sha: String?, on id: UUID) {
        guard store.state.task(id: id)?.operated != nil else { return }
        store.mutate { state in
            state.updateOperated(id) {
                var publication = $0.publication ?? TaskPublication()
                publication.unanswered = sha
                $0.publication = publication
            }
        }
        _ = store.flush()
    }

    /// Only the Operator's finish_task pushes: a merge watch's poll (`operatorCall` false) that finds the task accepted again
    /// on a commit not pushed yet pushes nothing, and stops with why, which tells the Operator. Nil when it may go on.
    static func watchMayNotPush(_ operated: OperatedTask, operatorCall: Bool) -> Result? {
        guard !operatorCall, stillToPush(operated), operated.publication?.pushedSHA != nil, let sha = operated.acceptance?.resultSHA
        else { return nil }
        return Result(operated.publication, result: .refused, reason: unpushedAcceptance(operated.key, sha: sha))
    }

    /// Why a merge watch's poll pushed nothing: the task was accepted again on a commit not yet pushed, which only the
    /// Operator's `finish_task` pushes.
    static func unpushedAcceptance(_ key: String, sha: String) -> String {
        "\(key)’s accepted commit \(sha.prefix(7)) isn’t pushed: only finish_task pushes it."
    }

    /// Why a `noVerify` is refused before any push the hook refused.
    static let noFailedPush = "Push without noVerify first, so the hook's output is known."

    /// Whether the accepted commit is still to be pushed: not on origin by AiTerm's record, and the task's end not done.
    static func stillToPush(_ operated: OperatedTask) -> Bool {
        let publication = operated.publication
        return operated.state != .published && publication?.mergeOutcome != .merged && publication?.leftForYou != true
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
    func disarm(_ id: UUID, because why: String, kind: TaskPublication.ProblemKind) {
        stopWatching(id)
        guard let operated = store.state.task(id: id)?.operated, operated.end == .merge, operated.state == .accepted,
              let publication = operated.publication, publication.mergeRequestNumber != nil,
              !publication.wasMerged, publication.problem == nil else { return }
        store.mutate { $0.updateOperated(id) { $0.publication?.setProblem(why, kind: kind) } }
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
        guard !isStopped, held[id] == nil else { return false }
        guard let operated = store.state.task(id: id)?.operated, operated.end == .merge, operated.state == .accepted,
              !operated.takenOver, !operated.flags.contains(.upstreamReplaced),
              let publication = operated.publication, publication.mergeRequestNumber != nil,
              !publication.wasMerged, publication.problem == nil,
              let run = store.state.run(id: operated.runId), run.youAsked == nil,
              // Accepted again while its people review goes on: its next finish_task pushes it back into review, not to a merge.
              !TaskPublisher.Context.entersReview(operated, run: run)
        else { return false }
        return run.state == .active || run.state == .complete
    }

    /// The one way a publication runs: joined when one is in flight for the task.
    private func run(_ id: UUID, restart: Bool, noVerify: Bool = false, operatorCall: Bool = false) async -> Result {
        guard !isStopped else { return Result(result: .refused, reason: Self.closingReason) }
        if let steered = steeringRefusal(id) { return steered }
        return await start(id, restart: restart, noVerify: noVerify, operatorCall: operatorCall).task.value
    }

    /// The task's publication in flight, joined, or a new one started. `operatorCall`: started by the Operator's own call,
    /// which reads origin fresh before it decides that a merge end's commit is merged already (`finishLanded`).
    private func start(_ id: UUID, restart: Bool, noVerify: Bool, operatorCall: Bool) -> (token: UUID, task: Task<Result, Never>) {
        if let running = inFlight[id] {
            joined += 1
            return running
        }
        let token = UUID()
        let started = Task { () -> Result in
            let result = await self.advance(id, restart: restart, noVerify: noVerify, operatorCall: operatorCall)
            self.ended(id, token: token, result)
            return result
        }
        inFlight[id] = (token, started)
        return (token, started)
    }

    /// A publication's end: no longer in flight. One whose call answered `running`, with no call waiting on it now, is kept
    /// for the next call and the Operator woken; a call still waiting has it as its answer. A merge watch's poll after it
    /// keeps the answer owed up to date, its own result, and wakes nobody again: the watch has its own word when it ends.
    private func ended(_ id: UUID, token: UUID, _ result: Result) {
        guard inFlight[id]?.token == token else { return }
        inFlight[id] = nil
        if owedFlights[id] != token, let late = kept[id] {
            kept[id] = (late.sha, result)
            return
        }
        guard owedFlights[id] == token, listening[id] == nil,
              let sha = store.state.task(id: id)?.operated?.publication?.unanswered else { return }
        owedFlights[id] = nil
        kept[id] = (sha, result)
        finishedLate(id)
    }

    /// A publication's step, and what the Merge slice kept from happening left for you once (spec §5).
    private func advance(_ id: UUID, restart: Bool, noVerify: Bool, operatorCall: Bool) async -> Result {
        let publication = store.state.task(id: id)?.operated?.publication
        let before = publication?.problem, kind = publication?.problemOutcome
        let result = await publish(id, restart: restart, noVerify: noVerify, operatorCall: operatorCall)
        clearFailure(before, kind: kind, on: id, restart: restart, after: result)
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

    /// A run that went through clears the problem an earlier failed step left. Only a run with `restart` clears a problem
    /// itself (`TaskPublisher`); a merge watch's polls, and a call while one watches, go on without it, and a watch starts
    /// only with no problem: one recorded before such a run began (`before`) is a failure of that watch, which a run that
    /// ended published, in review or waiting to merge is past (T7: the push that landed after the hook refused one). One
    /// changed meanwhile, a hold (`TaskPublication.operatorHolds`) or a takeover's is kept.
    private func clearFailure(_ before: String?, kind: TaskPublication.ProblemKind?, on id: UUID, restart: Bool, after result: Result) {
        guard !restart, let before, [.published, .inReview, .waitingToMerge].contains(result.result),
              kind != .hold, before != Self.takenOverProblem,
              store.state.task(id: id)?.operated?.publication?.problem == before else { return }
        store.mutate { $0.updateOperated(id) { $0.publication?.problem = nil } }
        _ = store.flush()
    }

    private static func permanent(_ reason: String) -> Bool { TaskPublication.ProblemKind(matching: reason) == .permanent }

    /// `sentence` in the run's Left for you, once, saved in one change with `also`.
    private func leaveForYou(_ sentence: String, in run: UUID, also: (inout AppState) -> Void = { _ in }) {
        store.mutate { state in
            also(&state)
            state.updateRun(id: run) { if !$0.leftForYou.contains(sentence) { $0.leftForYou.append(sentence) } }
        }
        _ = store.flush()
    }

    private func publish(_ id: UUID, restart: Bool, noVerify: Bool, operatorCall: Bool) async -> Result {
        guard var first = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
        // The Operator's own call on a merge end reads origin fetched before it changes or decides anything (a review
        // ended, the commit read as merged or not): a fetch that fails changes nothing.
        var fetched: LandingCheck?, offline: String?
        if operatorCall, first.operated.end.merges, [.accepted, .inReview].contains(first.operated.state),
           let sha = first.operated.acceptance?.resultSHA, first.operated.publication?.wasMerged != true {
            let ownership = first.operated.ownership
            var check = await Self.landingFetched(of: sha, in: first.project.path, git: git)
            if case .unknown(let why, let note) = check {
                // A local merge pushes nothing: it goes ahead on the checkout and origin as last fetched, and says so.
                guard first.operated.end == .mergeLocal else {
                    return Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: why)
                }
                offline = note
                check = await Self.landing(of: sha, in: first.project.path, git: git)
                    .map { .landed(target: $0.target, landing: $0.landing) } ?? .notLanded
            }
            // Read fresh: the fetch awaited git. What it found holds only for the commit accepted then, by the same owner.
            guard let fresh = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
            guard fresh.operated.acceptance?.resultSHA == sha, fresh.operated.ownership == ownership else {
                return Result(fresh.operated.publication, result: .refused, reason: PublicationGuard.changedMidway)
            }
            fetched = check
            first = fresh
        }
        // A task in review: this finish_task ends the review (spec §5). A draft end is then published; a merge end
        // goes on to its merge. Only the Operator's own call ends it: a merge watch's poll changes nothing.
        if first.operated.state == .inReview {
            guard operatorCall else { return Result(first.operated.publication, result: .inReview, reason: nil) }
            if let ended = endReview(first) { return ended }
            guard let fresh = context(of: id) else { return Result(result: .refused, reason: PublicationGuard.gone) }
            first = fresh
        }
        // Merged outside finish_task, even after it was left for you: recorded as it is, nothing more done.
        if let landed = await finishLanded(first, fetched: fetched) { return Self.noting(offline, on: landed) }
        let task = first.task, operated = first.operated, project = first.project
        // What is done is answered from the record, whatever the host's connection is now.
        if operated.publication?.leftForYou == true { return Result(operated.publication, result: .leftForYou, reason: nil) }
        if operated.state == .published || operated.publication?.mergeOutcome == .merged {
            // A draft published before its request could be assigned: this call tries again.
            if operated.publication?.assigning == true, operated.publication?.mergeOutcome != .merged { return await assignAgain(first) }
            return apply(.published(operated.publication ?? TaskPublication()), to: id)
        }
        if let refused = Self.watchMayNotPush(operated, operatorCall: operatorCall) { return refused }
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
            if fresh.operated.end == .mergeLocal { return Self.noting(offline, on: await mergeLocally(fresh, repository: repository)) }
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
        // Accepted again while the reads above awaited git: checked again on what the publisher is handed.
        if let refused = Self.watchMayNotPush(current.operated, operatorCall: operatorCall) { return refused }
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

    /// A published draft whose request couldn't be assigned when it opened (`TaskPublisher.assign`), tried again. Only the
    /// broadcast running and the task still the operator's under the same ownership are read again before the write: the
    /// task is past accepted, and its request open and recorded. It answers published as before, saying if it still couldn't.
    private func assignAgain(_ current: Context) async -> Result {
        let id = current.task.id, ownership = current.operated.ownership
        var publication = current.operated.publication ?? TaskPublication()
        let host: any MergeRequestPublishing
        do { host = try await codeHost.host(of: current.project) }
        catch {
            var result = apply(.published(publication), to: id)
            result.draftNote = Self.draftNote(.notAssigned(name: publication.requested?.assignee, why: Self.unavailable(error)),
                                              request: publication.mergeRequestURL, number: publication.mergeRequestNumber)
            return result
        }
        if let why = PublicationGuard.otherRepository(publication, repository: host.repository) {
            return Result(publication, result: .refused, reason: why)
        }
        let drafted = DraftNews()
        let publisher = TaskPublisher(repository: Repository(current.project.path, git: git), host: host, now: now,
                                      noted: { drafted.record($0) })
        let recheck: @Sendable () async -> String? = { @MainActor [weak self] in
            guard let self, !self.isStopped else { return Self.closingReason }
            let state = store.state
            guard let operated = state.task(id: id)?.operated, let run = state.run(id: operated.runId) else { return PublicationGuard.gone }
            if let why = PublicationGuard.runRefusal(run) { return why }
            return operated.takenOver || operated.ownership != ownership ? PublicationGuard.changedMidway : nil
        }
        do {
            if let why = try await publisher.assign(&publication, recheck: recheck, record: steps(of: id, ownership: ownership, sha: "").record) {
                return Result(publication, result: .refused, reason: why)
            }
        } catch {
            return Result(store.state.task(id: id)?.operated?.publication, result: .failed, reason: Self.notSavedReason)
        }
        var result = apply(.published(store.state.task(id: id)?.operated?.publication ?? publication), to: id)
        result.draftNote = draftNote(drafted, of: id)
        return result
    }

    /// What this call did to the task's request, if anything: even one that failed afterwards opened or marked it ready first.
    private func draftNote(_ news: DraftNews, of id: UUID) -> String? {
        let publication = store.state.task(id: id)?.operated?.publication
        let notes = [news.last, news.notAssigned].compactMap {
            Self.draftNote($0, request: publication?.mergeRequestURL, number: publication?.mergeRequestNumber)
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
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
        case .notAssigned(let name, let why):
            return "MR \(reference) couldn’t be assigned\(name.map { " to \($0)" } ?? ""): \(why). finish_task tries again, or set one with update_request"
        }
    }

    /// A publication that failed — a push its pre-push hook refused, a host that errored — or a watch that has to
    /// stop for what it found, recorded as the task's problem and saved, so its line says `blocked` and why, not
    /// `opening the MR` for as long as it waits for you, and nothing watches it again: the next `finish_task` clears
    /// it (`TaskPublisher`). `hookSaid`, for a push the hook
    /// refused, is kept as `lastPushFailure` with the commit it refused, for the Oracle to judge a `noVerify` by.
    private func recordFailure(_ why: String, kind: TaskPublication.ProblemKind = .failure, on id: UUID,
                               hookSaid: (output: String, sha: String)? = nil) {
        store.mutate { state in
            state.updateOperated(id) {
                var publication = $0.publication ?? TaskPublication()
                publication.setProblem(why, kind: kind)
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

    /// Whether a merge end's accepted commit is already in its default branch, origin's fetched now (`landingFetched`).
    enum LandingCheck: Sendable {
        case landed(target: String, landing: Repository.Landing)
        case notLanded
        /// Origin couldn't be fetched: whether it is merged there is not known, and never read as not merged. Why, as said
        /// when nothing is done; and what a local merge, which pushes nothing and so goes ahead, says of it (`offline`).
        case unknown(String, offline: String)
    }

    /// `landing(of:in:git:)` after fetching the default branch from origin, bounded by `OperatorTiming.landedFetchTimeout`:
    /// the person may have merged the request on the host, which origin's branch as last fetched doesn't show. A project
    /// without origin reads its own branch. A fetch that fails answers `unknown` with why. Read off the main actor.
    nonisolated static func landingFetched(of sha: String, in path: String, git: any GitRunning) async -> LandingCheck {
        let repository = Repository(path, git: git)
        return await BackgroundWork.run { () -> LandingCheck in
            let target = repository.defaultBranch()
            do {
                if try repository.hasOrigin { try repository.fetchFromOrigin(target, timeout: OperatorTiming.landedFetchTimeout) }
            } catch {
                return .unknown(TaskFinisher.unfetched(target, error), offline: TaskFinisher.readAsLastFetched(target, error))
            }
            guard let landing = try? repository.landing(of: sha, in: target) else { return .notLanded }
            return .landed(target: target, landing: landing)
        }
    }

    /// A local merge's answer, saying that it went ahead with origin unread (`offline`) when it merged or recorded a merge.
    static func noting(_ offline: String?, on result: Result) -> Result {
        guard let offline, result.result == .published else { return result }
        var noted = result
        noted.reason = (result.reason.map { $0 + " " } ?? "Merged locally. ") + offline
        return noted
    }

    /// What a local merge's answer says when origin couldn't be fetched: it pushes nothing, so it went ahead on origin as last
    /// fetched.
    nonisolated static func readAsLastFetched(_ branch: String, _ error: any Error) -> String {
        "AiTerm couldn’t fetch \(branch) from origin (\(GitError.displayReason(of: error))), so it read origin as last fetched."
    }

    /// Why a merge decision isn't taken when origin couldn't be fetched.
    nonisolated static func unfetched(_ branch: String, _ error: any Error) -> String {
        "AiTerm couldn’t fetch \(branch) from origin, so it can’t tell whether the accepted commit is merged there already: "
            + "\(GitError.displayReason(of: error)). Nothing was done: call finish_task again."
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
    /// `fetched`, for the Operator's own call: what `publish` read with origin fetched (a fetch that failed answered there,
    /// before anything changed). Without it, a merge watch's poll reads the host, and origin as last fetched.
    private func finishLanded(_ first: Context, fetched: LandingCheck?) async -> Result? {
        let id = first.task.id, operated = first.operated
        guard operated.end.merges, operated.state == .accepted, let sha = operated.acceptance?.resultSHA,
              operated.publication?.wasMerged != true else { return nil }
        let target: String, landing: Repository.Landing
        switch fetched {
        case .landed(let branch, let found)?: (target, landing) = (branch, found)
        case .notLanded?, .unknown?: return nil
        case nil:
            guard let found = await Self.landing(of: sha, in: first.project.path, git: git) else { return nil }
            (target, landing) = found
        }
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
                OperatedTransitions.record(.publish, on: &task)
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
            var publication = Self.keepingNewerRequest(publication, over: operated.publication)
            // Progress from an awaited step must not restore authority invalidated by newer settings/evidence.
            publication.conditionsHeld = operated.publication?.conditionsHeld
            publication.conditionsEvidence = operated.publication?.conditionsEvidence
            publication.mergeRefusal = operated.publication?.mergeRefusal
            if operated.ownership != ownership, let problem = operated.publication?.problem, let kind = operated.publication?.problemOutcome {
                publication.setProblem(problem, kind: kind)
            }
            state.tasks[index].operated?.publication = publication
            if let number = publication.mergeRequestNumber, let url = publication.mergeRequestURL {
                state.tasks[index].mr = MergeRequestRef(iid: number, title: state.tasks[index].title, url: url)
            }
        }
        guard store.flush() else { throw NotSaved() }
    }

    /// `publication`, a step's, saved over `saved` without undoing what `update_request` changed while the step awaited the
    /// host: the Operator's content is always the saved one, and a request saved as assigned stays assigned, so a stale step
    /// never assigns it again to an older choice.
    static func keepingNewerRequest(_ publication: TaskPublication, over saved: TaskPublication?) -> TaskPublication {
        guard let saved else { return publication }
        var kept = publication
        kept.requested = saved.requested
        // Whether a call is owed this publication's answer is the finisher's, never a step's.
        kept.unanswered = saved.unanswered
        if saved.assigning != true, let assignee = saved.assignee {
            kept.assigning = nil
            kept.assignee = assignee
        }
        return kept
    }

    /// The task's broadcast does not run now — paused, ended, its operator offline, its plan not submitted:
    /// a watch refused for that is suspended, not stopped, and picked up when the broadcast runs again.
    private func isSuspended(_ id: UUID) -> Bool {
        guard let operated = store.state.task(id: id)?.operated, let run = store.state.run(id: operated.runId) else { return false }
        return run.youAsked != nil || !(run.state == .active || run.state == .complete)
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
            state.updateOperated(id) { OperatedTransitions.record(.endReview(merges: merges), on: &$0) }
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
                state.updateOperated(id) { OperatedTransitions.record(.enterReview(at: now()), on: &$0) }
            }
            _ = store.flush()
            return Result(publication, result: .inReview, reason: Self.inReviewReason)
        case .published(let publication):
            // The end is carried out on the host already: the state follows whatever the save does.
            store.mutate { $0.updateOperated(id) { OperatedTransitions.record(.publish, on: &$0) } }
            _ = store.flush()
            return Result(publication, result: .published, reason: nil)
        case .waiting(let publication, let why):
            store.mutate { $0.updateOperated(id) { $0.publication?.waitingReason = why } }
            _ = store.flush()
            watch(id)
            return Result(publication, result: .waitingToMerge, reason: why)
        case .blocked(let publication, let why):
            // Merged on the host with commits nobody accepted: yours to decide, never polled again.
            if publication.mergeOutcome == .mergedWithAnotherHead { mergedOnHost(id, why) }
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
    /// - merged, blocked or out of time, the operator is told (`changed`);
    /// - back in people review, it ends quietly: the review watcher has the word, and only finish_task ends a review.
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
                case .inReview:
                    // People review it: nothing merges until the Operator ends the review, and the review watcher wakes
                    // it on the review's news, so the watch ends without a word.
                    return
                case .refused:
                    guard !self.isSuspended(id), self.store.state.task(id: id)?.operated != nil else { return }
                    var why = result.reason ?? PublicationGuard.changedMidway
                    // The Oracle's yes no longer covers the evidence (mark_task refreshed it): the merge waits for the
                    // Operator's finish_task, which the Oracle judges, not for you.
                    if self.awaitsOracle(id, refusedFor: why) { why = PublicationGuard.oracleYesNeeded }
                    // A refusal is recorded as the kind its words are, until refusals carry their kind themselves.
                    self.recordFailure(why, kind: TaskPublication.ProblemKind(matching: why), on: id)
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

    /// Whether a watch's poll was refused, `why`, for the Oracle's yes no longer covering the task's evidence, as it stands now.
    private func awaitsOracle(_ id: UUID, refusedFor why: String) -> Bool {
        let state = store.state
        guard let task = state.task(id: id), let run = task.operated.flatMap({ state.run(id: $0.runId) }) else { return false }
        return PublicationGuard.oracleRefusal(task, in: run) == why
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
