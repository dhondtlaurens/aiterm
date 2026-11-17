import Foundation
import AiTermCore

/// Read each request once per observation pass, except for the explicit checks around a merge.
/// Unreadable facts never finish a stage. The host, not a successful merge RPC, confirms a merge.
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
        var oracleMerge: @MainActor (TaskItem, Snapshot) async throws -> Bool
        var merge: @MainActor (TaskItem, Snapshot) async throws -> Void
    }
    private let workspace: WorkspaceStore
    private let stages: StageRunner
    private let then: ThenRunner
    private let ports: Ports
    private var running = false
    var changed: (UUID, String) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, stages: StageRunner, then: ThenRunner, ports: Ports) {
        self.workspace = workspace; self.stages = stages; self.then = then; self.ports = ports
    }
    func pass() async {
        guard !running else { return }
        running = true; defer { running = false }
        var cache: [String: Snapshot] = [:]
        let ids = workspace.state.tasks.compactMap { task -> UUID? in
            guard let record = task.signalTask else { return nil }
            if record.phase == .working { return task.id }
            if case .watching = record.phase { return task.id }
            return nil
        }
        for id in ids {
            guard let task = workspace.state.task(id: id), let claim = SignalClaim(task), claim.allows(in: workspace), let record = task.signalTask,
                  !ports.workerIsWorking(id) else { continue }
            let signal = record.current.configuration
            let key = record.watchedRequest.flatMap { ItemRef.mergeRequest($0).identity } ?? record.current.item.identity ?? id.uuidString
            let snapshot: Snapshot
            do {
                if let saved = cache[key] { snapshot = saved }
                else { let value = try await ports.read(task); cache[key] = value; snapshot = value }
                guard allowed(claim) else { continue }
                try await check(snapshot, task: task, claim: claim, signal: signal)
            } catch {
                // A failed host read is unknown. Existing work and its phase stay as they are.
            }
        }
    }
    private func allowed(_ claim: SignalClaim) -> Bool {
        claim.allows(in: workspace) && !ports.workerIsWorking(claim.task)
    }
    private func check(_ first: Snapshot, task: TaskItem, claim: SignalClaim, signal: Signal) async throws {
        var snapshot = first
        let merges = signal.finish.mergesWhenReady
        // The done condition met and only merge when ready holding the task: the line names what the merge lacks.
        let met = DoneCheck.evaluate(signal.finish.doneWhen, facts: snapshot.facts, stageStartedAt: task.signalTask?.startedAt ?? .distantPast) == .reached
        if let reference = snapshot.reference { workspace.mutate { state in
            state.updateSignalItem(task.id) { task in
                task.signalTask?.watchedRequest = reference
                if let link = snapshot.link { task.mr = link }
                // Only a complete read speaks for whom it waits on, and each fact only when this read carried it.
                guard snapshot.facts.hostReadComplete else { return }
                var wait = task.signalTask?.waitingOn ?? SignalWaitFacts()
                if let reviewers = snapshot.facts.reviewers { wait.reviewers = reviewers }
                if let open = snapshot.facts.openThreads { wait.openThreads = open }
                wait.mergeBlockers = merges && met && !snapshot.facts.merged ? snapshot.mergeBlockers : nil
                let next = wait.isEmpty ? nil : wait
                if task.signalTask?.waitingOn != next { task.signalTask?.waitingOn = next }
            }
        } }
        if signal.finish.doneWhen == .operatorJudges && task.signalTask?.operatorJudged != true { return }
        if merges, snapshot.canMerge, workspace.state.operatorSession?.startingFresh != true {
            let roundID = UUID().uuidString, generation = workspace.state.operatorSession?.generation
            let round = OracleRound(id: roundID, tool: "merge_when_ready",
                                        askedAt: Date(), askedEvidence: task.id.uuidString)
            workspace.mutate { state in
                state.operatorSession?.oracleRounds.removeAll { $0.tool == "merge_when_ready" && $0.askedEvidence == task.id.uuidString }
                state.operatorSession?.oracleRounds.append(round)
                state.updateSignalTask(task.id) { $0.currentAct = "consulting the Oracle" }
            }
            guard workspace.flush() else { return }
            defer {
                workspace.mutate { state in
                    state.operatorSession?.oracleRounds.removeAll { $0.id == roundID }
                    if claim.holds(in: state) { state.updateSignalTask(task.id) { $0.currentAct = nil } }
                }
            }
            guard try await ports.oracleMerge(task, snapshot), allowed(claim),
                  workspace.state.operatorSession?.generation == generation else { return }
            let verified = try await ports.read(task)
            guard allowed(claim), verified.canMerge, verified.head == snapshot.head, verified.reference == snapshot.reference else { return }
            workspace.mutate { $0.updateSignalTask(task.id) { $0.currentAct = "merging it" } }
            try await ports.merge(task, verified)
            guard allowed(claim) else { return }
            snapshot = try await ports.read(task)
            guard allowed(claim), snapshot.reference == verified.reference else { return }
        }
        // Merge when ready is part of this stage's finish. A separate done condition becoming
        // true must not archive the task and stop its merge watch before checks turn green.
        if merges, !snapshot.facts.merged { return }
        guard allowed(claim), let current = workspace.state.task(id: task.id)?.signalTask,
              DoneCheck.evaluate(signal.finish.doneWhen, facts: snapshot.facts, stageStartedAt: current.startedAt) == .reached else { return }
        try await stages.finish(task.id, action: .finish(signal.finish.doneWhen))
        changed(task.id, "Its done condition was reached.")
        if claim.holds(in: workspace.state) { await then.apply(task.id) }
    }
}
