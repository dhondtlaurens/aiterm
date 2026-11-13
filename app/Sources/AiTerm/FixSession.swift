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
        case done(FixLanding), noFix(String), failed(String), unavailable
    }

    private struct Ready {
        let clone: FixClone, proposal: FixProposal, session: FixLookSession
    }

    private enum Phase {
        case offered, unavailable, looking(FixClone?), proposal(Ready), applying(Ready)
        case done(FixLanding), noFix(String), failed(String)
        #if DEBUG
        case snapshot(State)
        #endif

        var presentation: State {
            switch self {
            case .offered: .offered
            case .unavailable: .unavailable
            case .looking: .looking
            case .proposal(let ready): .proposal(ready.proposal)
            case .applying: .applying
            case .done(let landing): .done(landing)
            case .noFix(let reason): .noFix(reason)
            case .failed(let reason): .failed(reason)
            #if DEBUG
            case .snapshot(let state): state
            #endif
            }
        }

        var clone: FixClone? {
            switch self {
            case .looking(let clone): clone
            case .proposal(let ready), .applying(let ready): ready.clone
            default: nil
            }
        }
    }

    @ObservationIgnored private var phase: Phase
    /// The surface observes only a changed presentation, including while a Look acquires its clone.
    var state: State { access(keyPath: \.state); return phase.presentation }
    /// The last proposal shown, which the footer keeps on screen while it is applied.
    private(set) var lastProposal: FixProposal?
    /// The problem; a Try Again adds why the last fix failed.
    @ObservationIgnored private(set) var request: FixRequest
    let fixer: FixerAgent?
    @ObservationIgnored private let pipeline: FixPipeline
    @ObservationIgnored private let retry: @MainActor (FixLanding) async -> Void
    @ObservationIgnored private var work: Task<Void, Never>?

    init(request: FixRequest, fixer: FixerResolution, pipeline: FixPipeline, retry: @escaping @MainActor (FixLanding) async -> Void) {
        self.request = request; self.pipeline = pipeline; self.retry = retry
        self.fixer = fixer.agent
        phase = fixer.agent == nil ? .unavailable : .offered
    }

    isolated deinit {
        if let clone = phase.clone { Task { await Self.discard(clone) } }
    }

    var isBusy: Bool { state == .looking || state == .applying }
    var clonePath: String? { phase.clone?.path }

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
            set(.offered)
        case .proposal:
            let declined = phase.clone
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
        guard case .proposal(let ready) = phase, let fixer else { return }
        let clone = ready.clone
        set(.applying(ready))
        work = Task {
            do throws(FixRefusal) {
                let checked = try await pipeline.apply(fixer, clone, ready.proposal, ready.session)
                guard !Task.isCancelled else { throw FixRefusal.cancelled }
                let landing = try await pipeline.land(clone, checked)
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
    func waitForClone() async { while phase.clone == nil, state == .looking { await Task.yield() } }

    /// Every write to `self` comes after a check that this task was not cancelled: a cancelled Look
    /// has handed the surface back, and a new one may be running.
    private func look(_ fixer: FixerAgent) {
        set(.looking(nil))
        let request = request
        work = Task {
            var made: FixClone?
            do throws(FixRefusal) {
                let clone = try await pipeline.prepare(request)
                made = clone
                guard !Task.isCancelled else { return await Self.discard(clone) }
                set(.looking(clone))
                let (look, session) = try await pipeline.look(fixer, clone, request)
                guard !Task.isCancelled else { return await Self.discard(clone) }
                switch look {
                case .fix(let proposal):
                    if lastProposal != proposal { lastProposal = proposal }
                    set(.proposal(Ready(clone: clone, proposal: proposal, session: session)))
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
    private func end(_ end: Phase, removing clone: FixClone?) async {
        set(end)
        await Self.discard(clone)
    }

    private func set(_ new: Phase) {
        if phase.presentation != new.presentation {
            withMutation(keyPath: \.state) { phase = new }
        } else {
            phase = new
        }
    }

    /// Removing a checkout is blocking file work: off the main actor, and awaited so `settled()` covers it.
    private nonisolated static func discard(_ clone: FixClone?) async {
        guard let clone else { return }
        await BackgroundWork.run { clone.remove() }
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
        if let state { session.set(.snapshot(state)) }
        return session
    }
}
#endif

extension FixerResolution {
    var agent: FixerAgent? { if case .ready(let agent) = self { agent } else { nil } }
}
