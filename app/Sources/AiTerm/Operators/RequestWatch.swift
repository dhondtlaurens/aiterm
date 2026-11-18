import Foundation
import AiTermCore

/// Reads each task's Done trigger and merge request once per observation pass, except for the explicit checks around a
/// merge. Done is an edge: the Done query matching where it did not at the last complete read, or the merge request
/// merged or closed. Unreadable facts never finish a stage. The host, not a successful merge RPC, confirms a merge.
@MainActor final class RequestWatch {
    struct Snapshot: Equatable, Sendable {
        var reference: SignalRequestRef?
        var facts: DoneCheck.Facts
        var head: String?, localHead: String?
        var approvals: Bool, greenChecks: Bool
        var link: MergeRequestRef? = nil
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
        var merge: @MainActor (TaskItem, Snapshot) async throws -> Void
    }
    private let workspace: WorkspaceStore
    private let stages: StageRunner
    private let then: ThenRunner
    private let ports: Ports
    private let effects: OperatorInFlight
    /// Where the merge's Oracle veto and the merge show as the task's act.
    private let activity: OperatorActivityTracker
    var changed: (UUID, String) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, stages: StageRunner, then: ThenRunner, ports: Ports, effects: OperatorInFlight = OperatorInFlight(),
         activity: OperatorActivityTracker = OperatorActivityTracker()) {
        self.workspace = workspace; self.stages = stages; self.then = then; self.ports = ports; self.effects = effects; self.activity = activity
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
                try await ports.merge(task, verified)
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
        guard allowed(claim), DoneCheck.reached(snapshot.facts, before: before) else { return }
        try await stages.finish(task.id, action: .finish)
        changed(task.id, "Its Done trigger was reached.")
        if claim.holds(in: workspace.state) { await then.apply(task.id) }
    }
}
