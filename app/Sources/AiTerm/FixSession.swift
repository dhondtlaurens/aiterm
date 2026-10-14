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
        case .missing(let agent):
            self.fixer = agent
            state = .unavailable("\(agent.agent.displayName) isn’t installed. Install it in Settings › Agents, or choose another agent there.")
        case .off: self.fixer = nil; state = .unavailable("")
        }
    }

    isolated deinit {
        if let clone { Self.remove(clone) }
    }

    var buttonTitle: String { "Fix with \(fixer?.shortName ?? "AI")" }
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

    /// Has the agent make the proposal in the clone, checks it, lands it and runs the failed action again.
    func apply() {
        guard case .proposal(let proposal) = state, let fixer, let clone, let session else { return }
        set(.applying)
        work = Task {
            do throws(FixRefusal) {
                try await pipeline.apply(fixer, clone, proposal, session)
                let landing = try await pipeline.land(clone)
                await end(.done(landing), removing: clone)
                await retry(landing)
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

extension FixLanding {
    /// What the person is told when a fix landed and the action it was for did not follow: said
    /// after the action's new failure, or as a toast when there is none.
    var keptSentence: String { "The fix is in; your branch as it was is kept as \(backup)." }
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
                                  land: { _ throws(FixRefusal) in throw .cancelled })
        let session = FixSession(request: request, fixer: fixer, pipeline: refuses, retry: { _ in })
        session.lastProposal = proposal
        if let state { session.set(state) }
        return session
    }
}
#endif
