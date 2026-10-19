import Foundation
import AiTermCore

/// One problem's fix, as its footer or banner shows it (spec §9.1). Owns the one task running the
/// pipeline and the clone it made, and removes the clone on every way out — done, no fix, failed,
/// cancelled, declined, or let go with a proposal up — off the main actor, and only once the agent
/// that worked in it has gone. State is written only when it changes, so a surface redraws only
/// for a new state.
@MainActor
@Observable
final class FixSession {
    enum State: Equatable {
        case offered, looking, proposal(FixProposal), applying
        case done(FixLanding), noFix(String), failed(String), unavailable(String)
    }

    /// Written only through `set(_:)`, which skips an equal value.
    private(set) var state: State
    /// The last proposal shown, which the footer keeps on screen while it is applied.
    private(set) var lastProposal: FixProposal?
    /// The problem; a Try Again adds why the last fix failed.
    @ObservationIgnored private(set) var request: FixRequest
    let fixer: FixerAgent?
    @ObservationIgnored private let pipeline: FixPipeline
    @ObservationIgnored private let retry: @MainActor (FixLanding) async -> Void
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The clone a proposal was made in, and the agent's session in it, kept for Apply.
    @ObservationIgnored private var clone: FixClone?
    @ObservationIgnored private var session: String?

    init(request: FixRequest, fixer: FixerResolution, pipeline: FixPipeline, retry: @escaping @MainActor (FixLanding) async -> Void) {
        self.request = request; self.pipeline = pipeline; self.retry = retry
        switch fixer {
        case .ready(let agent): self.fixer = agent; state = .offered
        case .off: self.fixer = nil; state = .unavailable("")
        }
    }

    isolated deinit {
        if let clone { Self.remove(clone) }
    }

    /// What the offer says: what you get, not who gives it (Help with problems, option A).
    var buttonTitle: String { FixOffer.title }
    var isBusy: Bool { state == .looking || state == .applying }
    var clonePath: String? { clone?.path }

    /// Prepares a clone and asks the agent for a proposal.
    func start() {
        guard state == .offered, let fixer else { return }
        look(fixer)
    }

    /// While looking: stops the agent, then removes the clone, and goes back to offered at once. On
    /// a proposal: declines it. Nothing else — while applying, the timeout is the only stop.
    func cancel() {
        switch state {
        case .looking:
            // The task removes its clone once the agent's process group is gone.
            work?.cancel()
            clone = nil; session = nil
            set(.offered)
        case .proposal:
            let declined = clone
            clone = nil; session = nil
            set(.offered)
            work = Task { await Self.discard(declined) }
        default:
            return
        }
    }

    /// At quit: stops whatever the session's task is running, in any state — an Apply included,
    /// which `cancel()` leaves be — so no agent's process group outlives the app. Synchronous and
    /// cheap: cancelling sends the group its SIGTERM at once (`AgentProcess`); the task removes its
    /// clone if it gets to, and the next launch's sweep does otherwise.
    func stop() {
        work?.cancel()
    }

    /// Has the agent make the proposal in the clone, checks it, lands it and runs the failed action again.
    func apply() {
        guard case .proposal(let proposal) = state, let fixer, let clone, let session else { return }
        set(.applying)
        work = Task {
            do throws(FixRefusal) {
                let checked = try await pipeline.apply(fixer, clone, proposal, session)
                let landing = try await pipeline.land(clone, checked)
                self.clone = nil; self.session = nil
                set(.done(landing))
                // The action again first: removing the clone is file work it need not wait for. A
                // landing that finished as the app quits (`stop()`) starts no git write after it.
                if !Task.isCancelled { await retry(landing) }
                await Self.discard(clone)
            } catch {
                await end(.failed(error.errorDescription ?? "\(error)"), removing: clone)
            }
        }
    }

    /// A new Look in a new clone, told why the last one failed.
    func tryAgain() {
        guard case .failed(let reason) = state, let fixer else { return }
        request.previousFailure = reason
        look(fixer)
    }

    /// Test hooks: the running task's end, and the clone's existence.
    func settled() async { await work?.value }
    func waitForClone() async { while clone == nil, state == .looking { await Task.yield() } }

    /// Every write to `self` comes after a check that this task was not cancelled: a cancelled Look
    /// has handed the surface back, and a new one may be running.
    private func look(_ fixer: FixerAgent) {
        set(.looking)
        let request = request
        work = Task {
            var made: FixClone?
            do throws(FixRefusal) {
                let clone = try await pipeline.prepare(request)
                made = clone
                guard !Task.isCancelled else { return await Self.discard(clone) }
                self.clone = clone
                let (look, session) = try await pipeline.look(fixer, clone, request)
                guard !Task.isCancelled else { return await Self.discard(clone) }
                switch look {
                case .fix(let proposal):
                    self.session = session
                    if lastProposal != proposal { lastProposal = proposal }
                    set(.proposal(proposal))
                case .none(let reason):
                    await end(.noFix("\(fixer.shortName) found no fix it can stand behind: \(reason)"), removing: clone)
                }
            } catch {
                guard !Task.isCancelled, error != .cancelled else { return await Self.discard(made) }
                await end(.failed(error.errorDescription ?? "\(error)"), removing: made)
            }
        }
    }

    /// A state no task continues from: shown at once, then the clone removed.
    private func end(_ end: State, removing clone: FixClone?) async {
        self.clone = nil; session = nil
        set(end)
        await Self.discard(clone)
    }

    private func set(_ new: State) { if state != new { state = new } }

    /// Removing a checkout is blocking file work: off the main actor, and awaited so `settled()` covers it.
    private nonisolated static func discard(_ clone: FixClone?) async {
        guard let clone else { return }
        await BackgroundWork.run { clone.remove() }
    }

    private nonisolated static func remove(_ clone: FixClone) {
        DispatchQueue.global(qos: .utility).async { clone.remove() }
    }
}

extension FixSession.State {
    /// Whether the session holds its surface: the agent at work, or its proposal waiting on Apply —
    /// and the moment between landing and the action run again. Neither a new problem nor a
    /// dismissal takes the surface from it then; Cancel is the way out where there is one.
    var holdsSurface: Bool {
        switch self {
        case .looking, .proposal, .applying, .done: true
        case .offered, .noFix, .failed, .unavailable: false
        }
    }
}

#if DEBUG
extension FixSession {
    /// A session drawn in `state` — or the one `fixer` starts it in, when nil — as the snapshots
    /// show it: `proposal` is the one kept on screen while applying. Its pipeline refuses every
    /// stage, so nothing it is asked runs.
    static func snapshot(_ state: State?, fixer: FixerResolution, request: FixRequest, proposal: FixProposal? = nil) -> FixSession {
        let refuses = FixPipeline(prepare: { _ throws(FixRefusal) in throw .cancelled },
                                  look: { _, _, _ throws(FixRefusal) in throw .cancelled },
                                  apply: { _, _, _, _ throws(FixRefusal) in throw .cancelled },
                                  land: { _, _ throws(FixRefusal) in throw .cancelled })
        let session = FixSession(request: request, fixer: fixer, pipeline: refuses, retry: { _ in })
        session.lastProposal = proposal
        if let state { session.set(state) }
        return session
    }
}
#endif
