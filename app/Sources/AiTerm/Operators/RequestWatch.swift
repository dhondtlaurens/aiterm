import Foundation
import AiTermCore

/// Reads each task's Done trigger and merge request once per observation pass, except for the explicit checks around a
/// merge. Done is an edge: the Done query matching where it did not at the last complete read, or the merge request
/// merged or closed. Unreadable facts never finish a stage. The host, not a successful merge RPC, confirms a merge.
/// A merge AiTerm made itself does not end the stage: its worker is told once and carries on until the Done query.
@MainActor final class RequestWatch {
    struct Snapshot: Equatable, Sendable {
        var reference: SignalRequestRef?
        var facts: DoneCheck.Facts
        var head: String?, localHead: String?
        var approvals: Bool, greenChecks: Bool
        var link: MergeRequestRef? = nil
        /// The merge commit, when the host says the request merged and names it.
        var mergeCommit: String? = nil
        /// Whether the host itself would merge now (`MergeReadiness.ready`); `approvals` folds it in for `canMerge`.
        var hostReady = true
        var canMerge: Bool {
            facts.hostReadComplete && approvals && greenChecks && facts.threadsResolved
                && head != nil && head == localHead && !facts.merged && !facts.closed
        }
        /// What of `canMerge` the request still lacks, for the waiting line.
        var mergeBlockers: [SignalWaitFacts.MergeBlocker] {
            // Approval as the request has it, not `approvals`, which also holds the host's readiness: running checks
            // must not read as an approval to come.
            let gates: [(Bool, SignalWaitFacts.MergeBlocker)] = [(facts.approved, .approval), (greenChecks, .checks), (facts.threadsResolved, .threads),
                                                                 (head != nil && head == localHead, .push)]
            let missing = gates.filter { !$0.0 }.map(\.1)
            // The host holding it back for a reason none of the others names: conflicts, a draft, its own rules.
            return missing.isEmpty && !hostReady ? [.host] : missing
        }
    }
    struct Ports {
        var workerIsWorking: @MainActor (UUID) -> Bool
        var read: @MainActor (TaskItem) async throws -> Snapshot
        /// Whether the Oracle agrees to merge the task now; anything else means no merge this pass.
        var oracleMerge: @MainActor (TaskItem, Snapshot) async throws -> Bool
        /// Merges at the snapshot's head and returns the host's answer. It calls `intend` after its own checks and
        /// with no await before the host call, so a failure it knows came first leaves no merge saved as AiTerm's.
        var merge: @MainActor (TaskItem, Snapshot, _ intend: @escaping @MainActor () throws -> Void) async throws -> MergeReadiness
        /// Types the carry-on line into the idle main worker, the stage going back to working, and saves the hand-back
        /// as done with the reply it waits for.
        var handBack: @MainActor (TaskItem, String) async throws -> Void = { _, _ in throw ActionUnavailable("No worker to tell.") }
        /// Whether the task still has its main worker tab.
        var hasWorker: @MainActor (TaskItem) -> Bool = { _ in true }
    }
    private let workspace: WorkspaceStore
    private let stages: StageRunner
    private let then: ThenRunner
    private let ports: Ports
    private let effects: OperatorInFlight
    /// Where the merge's Oracle veto and the merge show as the task's act.
    private let activity: OperatorActivityTracker
    private let now: () -> Date
    var changed: (UUID, String) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, stages: StageRunner, then: ThenRunner, ports: Ports, effects: OperatorInFlight = OperatorInFlight(),
         activity: OperatorActivityTracker = OperatorActivityTracker(), now: @escaping () -> Date = { Date() }) {
        self.workspace = workspace; self.stages = stages; self.then = then; self.ports = ports; self.effects = effects; self.activity = activity
        self.now = now
    }
    /// One pass over the working and watching tasks. A task whose worker is at work or that another effect holds is
    /// skipped this pass; the merge holds its task from the Oracle's veto through the confirming read. A task whose
    /// stage leaves the phase it was read in, a block included, is left alone from then on.
    func pass() async {
        var cache: [String: Snapshot] = [:]
        let ids = workspace.state.tasks.filter { task in
            guard let record = task.signalTask else { return false }
            return Self.isRead(record.phase)
        }.map(\.id)
        for id in ids {
            guard let task = workspace.state.task(id: id), let claim = SignalClaim(task), claim.allows(in: workspace), let record = task.signalTask,
                  Self.isRead(record.phase),
                  !ports.workerIsWorking(id), !effects.holds(id) else { continue }
            let phase = record.phase
            let signal = record.current.configuration
            let item = record.watchedRequest.flatMap { ItemRef.mergeRequest($0).identity } ?? record.current.item.identity ?? id.uuidString
            let key = item + "\n" + signal.done.source.rawValue + "\n" + signal.done.query
            let snapshot: Snapshot
            do {
                if let saved = cache[key] { snapshot = saved }
                else { let value = try await ports.read(task); cache[key] = value; snapshot = value }
                guard still(claim, in: phase) else { continue }
                try await check(snapshot, task: task, claim: claim, phase: phase, signal: signal)
            } catch {
                // A failed host read is unknown. Existing work and its phase stay as they are.
            }
        }
    }
    /// The phases a pass reads a task in, working and watching, and so the only ones a merge starts from.
    private static func isRead(_ phase: TaskPhase) -> Bool {
        if case .watching = phase { return true }
        return phase == .working
    }
    private func allowed(_ claim: SignalClaim) -> Bool {
        claim.allows(in: workspace) && !ports.workerIsWorking(claim.task)
    }
    /// `allowed`, with the stage still in `phase`, the phase this pass read it in.
    private func still(_ claim: SignalClaim, in phase: TaskPhase) -> Bool {
        allowed(claim) && workspace.state.task(id: claim.task)?.signalTask?.phase == phase
    }
    private func check(_ first: Snapshot, task: TaskItem, claim: SignalClaim, phase: TaskPhase, signal: Signal) async throws {
        var snapshot = first
        // A review task never merges.
        let merges = signal.finish.mergesWhenReady && task.kind != .review
        let before = task.signalTask?.doneMatched
        workspace.mutate { state in
            state.updateSignalItem(task.id) { task in
                if let reference = snapshot.reference { task.signalTask?.watchedRequest = reference }
                if let link = snapshot.link { task.mr = link }
                if task.signalTask?.doneMatched != snapshot.facts.doneMatches { task.signalTask?.doneMatched = snapshot.facts.doneMatches }
                // While merge when ready holds the task, its line names what the merge lacks.
                let blockers = merges && snapshot.facts.hostReadComplete && !snapshot.facts.merged ? snapshot.mergeBlockers : nil
                let next = blockers.map { SignalWaitFacts(mergeBlockers: $0) }
                if task.signalTask?.waitingOn != next { task.signalTask?.waitingOn = next }
            }
        }
        // Merge when ready merges once the host can merge it, whatever the Done query says.
        if merges, snapshot.canMerge, workspace.state.operatorSession?.lifecycle.isChanging != true {
            // The merge goes on only while the stage is still in the phase the pass read it in: a block stops it.
            guard still(claim, in: phase), effects.claim(task.id) else { return }
            defer { effects.release(task.id) }
            let generation = workspace.state.operatorSession?.generation
            let merging = { [self] in still(claim, in: phase) }
            let agreed: Snapshot? = try await activity.acting(task: task.id, act: "consulting the Oracle") { [snapshot] in
                guard try await ports.oracleMerge(task, snapshot), merging(),
                      workspace.state.operatorSession?.generation == generation else { return nil }
                let verified = try await ports.read(task)
                guard merging(), verified.canMerge, verified.head == snapshot.head, verified.reference == snapshot.reference else { return nil }
                return verified
            }
            guard let verified = agreed else { return }
            let merged: Snapshot? = try await activity.acting(task: task.id, act: "merging it") {
                let answer = try await ports.merge(task, verified) { [self] in
                    guard merging(), let reference = verified.reference, let head = verified.head else {
                        throw ActionUnavailable("The task changed before merging.")
                    }
                    workspace.mutate { $0.updateSignalTask(task.id) { $0.merge = SignalMerge(request: reference, head: head) } }
                    guard workspace.flush() else { throw ActionUnavailable("The merge intent couldn’t be saved.") }
                }
                settle(task.id, answer: answer)
                guard merging() else { return nil }
                let confirmed = try await ports.read(task)
                guard merging(), confirmed.reference == verified.reference else { return nil }
                return confirmed
            }
            guard let merged else { return }
            snapshot = merged
        }
        // With merge when ready on, nothing finishes the stage before its merge request is merged, or closed for good.
        if merges, !snapshot.facts.merged, !snapshot.facts.closed { return }
        let ours = snapshot.facts.merged && workspace.state.task(id: task.id)?.signalTask?.merge?.merged(snapshot.reference, at: snapshot.head) == true
        if ours, workspace.state.task(id: task.id)?.signalTask?.merge?.handBackOwed == true {
            try await handBack(task.id, claim: claim, snapshot: snapshot)
            return
        }
        guard allowed(claim), DoneCheck.reached(snapshot.facts, before: before, mergedByAiTerm: ours) else { return }
        try await stages.finish(task.id, action: .finish)
        changed(task.id, "Its Done trigger was reached.")
        if claim.holds(in: workspace.state) { await then.apply(task.id) }
    }
    /// Saves what the host answered a merge: merged settles it as AiTerm's, a refusal clears it, and a merge the host
    /// has not finished, like a lost answer, leaves a later read to settle it.
    private func settle(_ id: UUID, answer: MergeReadiness) {
        workspace.mutate { $0.updateSignalTask(id) { record in
            switch answer {
            case .merged(let commit, _, _): record.merge?.accepted = true; if !commit.isEmpty { record.merge?.commit = commit }
            case .blocked, .ready: record.merge = nil
            case .waiting: break
            }
        } }
        workspace.flush()
    }
    /// Tells the worker AiTerm merged its request, once: the stage goes back to working and its Done query, read afresh
    /// from not matching, ends it after the worker's turn. With no worker left, the stage blocks; resuming it sends the
    /// line instead of the stage prompt.
    private func handBack(_ id: UUID, claim: SignalClaim, snapshot: Snapshot) async throws {
        // Held like the merge, so no stage result moves the stage on while the line is on its way.
        guard allowed(claim), let task = workspace.state.task(id: id), task.signalTask?.merge != nil, effects.claim(id) else { return }
        defer { effects.release(id) }
        workspace.mutate { $0.updateSignalTask(id) { record in
            if record.merge?.commit == nil, let commit = snapshot.mergeCommit, !commit.isEmpty { record.merge?.commit = commit }
            record.doneMatched = false
        } }
        guard workspace.flush(), let current = workspace.state.task(id: id), let merge = current.signalTask?.merge else { return }
        guard ports.hasWorker(current) else {
            // A watching stage cannot block, so it goes back to work first: resuming it launches with the line.
            try workspace.mutate { state in
                try state.updateSignalItem(id) { task in
                    guard let record = task.signalTask else { return }
                    let working = try SignalTransitions.apply(.workRequested, to: record, at: now())
                    task.signalTask = try SignalTransitions.apply(.block(merge.workerGone), to: working, at: now())
                }
            }
            workspace.flush()
            changed(id, "AiTerm merged its request, but its worker is gone.")
            return
        }
        let line = merge.line
        try await ports.handBack(current, line)
        changed(id, "AiTerm merged its request and handed it back to its worker.")
    }
}
