import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct SignalWatchTests {
    private func stages(_ h: SignalHarness, at: Date, effects: OperatorInFlight = OperatorInFlight(),
                        launched: @escaping @MainActor () -> Void = {}) -> StageRunner {
        StageRunner(workspace: h.workspace, journal: h.journal, now: { at }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, _ in launched(); return "worker-window" }, restore: { $0 }),
            effects: effects)
    }
    private func ready(merged: Bool = false) -> RequestWatch.Snapshot {
        var facts = DoneCheck.Facts()
        facts.hostReadComplete = true; facts.approved = true; facts.threadsResolved = true; facts.merged = merged
        return .init(reference: SignalRequestRef(remote: "git@git.example:shop/web.git", number: 7), facts: facts,
                     head: "aabbcc", localHead: "aabbcc", approvals: true, greenChecks: true)
    }
    @Test func aDiscoveredRequestAddsTheOrdinaryClickableBadge() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }; let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        let link = MergeRequestRef(iid: 7, title: "Retries", url: "https://git.example/shop/web/-/merge_requests/7")
        var snapshot = ready(); snapshot.link = link
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in snapshot }, oracleMerge: { _, _ in false }, merge: { _, _, _ in .blocked("unused") }))
        await watch.pass()
        #expect(h.workspace.state.task(id: id)?.mr == link)
    }
    /// The watch with a scripted read, a busy switch and a Then that counts archives.
    @MainActor private final class EdgeRig {
        var snapshot: RequestWatch.Snapshot
        var busy = false, reads = 0, archived = 0
        private(set) var watch: RequestWatch!
        init(_ h: SignalHarness, world: SignalWorld, runner: StageRunner, snapshot: RequestWatch.Snapshot) {
            self.snapshot = snapshot
            let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
                workerIsWorking: { _ in false }, archive: { [unowned self] task, _ in
                    archived += 1; h.workspace.mutate { $0.moveToArchive(taskId: task.id, branch: task.branch, at: world.now) }
                }, remove: { _, _ in Issue.record("It should archive") }))
            watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
                workerIsWorking: { [unowned self] _ in busy }, read: { [unowned self] _ in reads += 1; return self.snapshot },
                oracleMerge: { _, _ in Issue.record("No merge requested"); return false }, merge: { _, _, _ in Issue.record("No merge requested"); return .blocked("unused") }))
        }
    }
    /// A merge when ready watch whose host merges when asked, and a worker that takes the carry-on line as
    /// `SignalWorkerIO.message` does: the stage goes back to working and the hand-back is saved as made.
    @MainActor private final class MergeRig {
        var merged = false, closed = false, doneMatches = false
        var oracleSays = true, reachesHost = true, answerLost = false, readLostAfterMerge = false
        var answer: MergeReadiness = .merged(commit: "m1abcdef9", head: "aabbcc")
        var hasWorker = true
        private(set) var merges = 0, archived = 0, told: [String] = []
        private(set) var watch: RequestWatch!
        init(_ h: SignalHarness, world: SignalWorld, runner: StageRunner, effects: OperatorInFlight = OperatorInFlight()) {
            let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
                workerIsWorking: { _ in false }, archive: { [unowned self] task, _ in
                    archived += 1; h.workspace.mutate { $0.moveToArchive(taskId: task.id, branch: task.branch, at: world.now) }
                }, remove: { _, _ in }))
            watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
                workerIsWorking: { _ in false }, read: { [unowned self] _ in
                    if merged, readLostAfterMerge { readLostAfterMerge = false; throw ActionUnavailable("The host did not answer.") }
                    var facts = DoneCheck.Facts()
                    facts.hostReadComplete = true; facts.approved = true; facts.threadsResolved = true
                    facts.merged = merged; facts.closed = closed; facts.doneMatches = doneMatches
                    return .init(reference: SignalRequestRef(remote: "git@git.example:shop/web.git", number: 7), facts: facts,
                                 head: "aabbcc", localHead: "aabbcc", approvals: true, greenChecks: true, mergeCommit: merged ? "m1abcdef9" : nil)
                }, oracleMerge: { [unowned self] _, _ in oracleSays },
                merge: { [unowned self] _, _, intend in
                    guard reachesHost else { throw ActionUnavailable("Its local head changed before merging.") }
                    try intend(); merges += 1
                    if case .merged = answer { merged = true }
                    if answerLost { merged = true; throw ActionUnavailable("The host did not answer.") }
                    return answer
                }, handBack: { [unowned self] task, line in
                    #expect(effects.holds(task.id), "the hand-back holds its task, so no stage result moves it on meanwhile")
                    told.append(line)
                    try h.workspace.mutate { state in
                        try state.updateSignalItem(task.id) { task in
                            guard var record = task.signalTask else { return }
                            record = try SignalTransitions.apply(.workRequested, to: record, at: world.now)
                            record.merge?.handBackOwed = false; task.signalTask = record
                        }
                    }
                    h.workspace.flush()
                }, hasWorker: { [unowned self] _ in hasWorker }), effects: effects, now: { world.now })
        }
    }
    private func done(_ matches: Bool, merged: Bool = false, closed: Bool = false) -> RequestWatch.Snapshot {
        var value = ready(merged: merged); value.facts.doneMatches = matches; value.facts.closed = closed; return value
    }
    /// A match that comes while the worker's first turn runs is not read then; the first read after it is the edge.
    @Test func aMatchDuringTheFirstTurnEndsTheStageAtTheNextRead() async throws {
        var world = SignalWorld(); let signal = world.signal(then: .archive), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = EdgeRig(h, world: world, runner: stages(h, at: world.now), snapshot: done(true))
        rig.busy = true
        await rig.watch.pass()
        #expect(rig.reads == 0 && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        rig.busy = false
        await rig.watch.pass()
        #expect(rig.reads == 1 && rig.archived == 1)
        #expect(h.workspace.state.archived(id: id)?.task.signalTask?.phase == .archived)
        await rig.watch.pass()
        #expect(rig.reads == 1 && rig.archived == 1, "an archived task is not read again")
    }
    /// A Done query that already matched at the baseline is not done; it must stop matching and match again.
    @Test func aDoneQueryMatchingAtItsBaselineWaitsForAFreshMatch() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .watching; $0.doneMatched = true }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = EdgeRig(h, world: world, runner: stages(h, at: world.now), snapshot: done(true))
        await rig.watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .watching)
        #expect(h.workspace.state.task(id: id)?.signalTask?.doneMatched == true)
        rig.snapshot = done(false); await rig.watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.doneMatched == false, "every complete read is the new observation")
        rig.snapshot = done(true); await rig.watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
    }
    /// With no observation yet, a read is the baseline: a match then is not an edge.
    @Test func aStageWithoutABaselineTakesItsFirstReadAsTheBaseline() async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .watching }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = EdgeRig(h, world: world, runner: stages(h, at: world.now), snapshot: done(true))
        await rig.watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .watching)
        #expect(h.workspace.state.task(id: id)?.signalTask?.doneMatched == true)
    }
    /// A merged or closed merge request ends the stage whatever its Done query says.
    @Test(arguments: [false, true]) func aMergedOrClosedRequestIsAlwaysDone(closed: Bool) async throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .watching; $0.doneMatched = true }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = EdgeRig(h, world: world, runner: stages(h, at: world.now), snapshot: done(true))
        await rig.watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .watching)
        rig.snapshot = done(true, merged: !closed, closed: closed); await rig.watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
    }
    /// Held for merge when ready: the line names what the merge lacks.
    @Test func aTaskHeldForItsMergeSavesWhatTheMergeLacks() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .watching; $0.doneMatched = false }
        let h = try SignalHarness(world); defer { h.cleanUp() }; let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        var snapshot = ready(); snapshot.greenChecks = false
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in snapshot },
            oracleMerge: { _, _ in Issue.record("Checks are not green"); return false }, merge: { _, _, _ in .blocked("unused") }))
        await watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.waitingOn?.mergeBlockers == [.checks])
        snapshot.greenChecks = true; snapshot.facts.threadsResolved = false; snapshot.localHead = "local"
        await watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.waitingOn?.mergeBlockers == [.threads, .push])
    }
    /// As `SignalHostIO` builds it: approved, but the host not ready while its checks run. The approval is not what
    /// the merge waits for; with every gate met, the host's own hold is.
    @Test func anApprovedRequestWhoseHostIsNotReadyNamesTheRealBlocker() {
        var facts = DoneCheck.Facts(); facts.hostReadComplete = true; facts.approved = true; facts.threadsResolved = true
        var running = RequestWatch.Snapshot(reference: nil, facts: facts, head: "h", localHead: "h",
                                            approvals: false, greenChecks: false, hostReady: false)
        #expect(running.mergeBlockers == [.checks])
        running.greenChecks = true
        #expect(running.mergeBlockers == [.host], "Green, approved, resolved and pushed, yet the host holds it: conflicts")
        running.hostReady = true; running.approvals = true
        #expect(running.mergeBlockers.isEmpty && running.canMerge)
        running.facts.approved = false; running.approvals = false
        #expect(running.mergeBlockers == [.approval])
    }
    @Test func aNewStageForgetsWhomThePreviousOneWaitedOn() throws {
        var record = SignalTask.make(item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        record.phase = .done; record.waitingOn = SignalWaitFacts(mergeBlockers: [.checks])
        let stage = SignalStage(signal: record.current.signal, item: record.current.item, matchedAt: Date(), configuration: record.current.configuration)
        let next = try SignalTransitions.apply(.matched(stage), to: record, at: Date())
        #expect(next.stage == 2 && next.waitingOn == nil)
    }
    /// Merge when ready waits on no Done query: the host's readiness and the Oracle's yes merge it, and AiTerm's own
    /// merge hands the stage back to its worker rather than ending it.
    @Test func mergeWhenReadyMergesWithoutADoneMatchAndHandsTheStageBack() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = MergeRig(h, world: world, runner: stages(h, at: world.now))
        await rig.watch.pass()
        #expect(rig.merges == 1 && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        #expect(rig.told == ["AiTerm merged !7 at m1abcde; carry on."])
        #expect(h.workspace.state.task(id: id)?.signalTask?.thenApplied != true && rig.archived == 0)
    }
    /// A review task never merges, even with merge when ready saved on its stage; its Done trigger ends it.
    @Test func aReviewTaskNeverMerges() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false }
        if let index = world.state.tasks.firstIndex(where: { $0.id == id }) { world.state.tasks[index].kind = .review }
        let h = try SignalHarness(world); defer { h.cleanUp() }; let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in done(true) },
            oracleMerge: { _, _ in Issue.record("A review task is never merged"); return false },
            merge: { _, _, _ in Issue.record("A review task is never merged"); return .blocked("unused") }))
        await watch.pass()
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .done)
    }

    @Test(arguments: ["approval", "checks", "threads", "head", "oracle", "changed-head"])
    func aMergeRequiresTheWholeFloorAndTheOraclesYes(reason: String) async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        var reads = 0, merges = 0, asked: [String?] = []
        let activity = OperatorActivityTracker()
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in
                reads += 1
                var value = ready()
                if reason == "approval" { value.approvals = false }
                if reason == "checks" { value.greenChecks = false }
                if reason == "threads" { value.facts.threadsResolved = false }
                if reason == "head" { value.localHead = "different" }
                if reason == "changed-head", reads > 1 { value.head = "different"; value.localHead = "different" }
                return value
            }, oracleMerge: { _, _ in asked.append(activity.act(for: task)); return reason != "oracle" }, merge: { _, _, intend in try intend(); merges += 1; return .merged(commit: "m1abcdef9", head: "aabbcc") }),
            activity: activity)
        await watch.pass()
        #expect(merges == 0)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase != .done)
        #expect(asked.allSatisfy { $0 == "consulting the Oracle" }, "The veto shows on the task's row while it runs.")
        #expect(activity.act(for: task) == nil && !activity.isRunning, "and is gone once the merge's body ends")
    }

    @Test func mergeWhenReadyKeepsWatchingUntilTheMergeFloorHolds() async throws {
        var world = SignalWorld()
        let signal = world.signal(then: .archive, merges: true)
        let id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        var archived = false
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in archived = true }, remove: { _, _ in }))
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in var value = done(true); value.greenChecks = false; return value },
            oracleMerge: { _, _ in Issue.record("Checks are not green"); return false }, merge: { _, _, _ in Issue.record("Checks are not green"); return .blocked("unused") }))
        await watch.pass()
        #expect(!archived && h.workspace.state.tasks.first?.signalTask?.canRunThen == false, "a fresh Done match does not end a stage before its merge")
    }

    @Test func aMergeIsConfirmedFromTheHostBeforeItsWorkerIsTold() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        var events: [String] = [], merged = false
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in events.append("read"); return ready(merged: merged) },
            oracleMerge: { _, _ in events.append("oracle"); return true },
            merge: { _, _, intend in
                #expect(h.workspace.state.task(id: task)?.signalTask?.merge == nil)
                try intend()
                #expect(h.workspace.state.task(id: task)?.signalTask?.merge == SignalMerge(request: SignalRequestRef(remote: "git@git.example:shop/web.git", number: 7), head: "aabbcc"),
                        "saved as AiTerm's before the host is asked")
                events.append("merge"); merged = true; return .merged(commit: "m1abcdef9", head: "aabbcc")
            }, handBack: { _, _ in events.append("told") }))
        await watch.pass()
        #expect(events == ["read", "oracle", "read", "merge", "read", "told"])
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase != .done)
        #expect(h.workspace.state.task(id: task)?.signalTask?.thenApplied != true)
    }

    /// The merge veto saves nothing while the Oracle reads it; its agreement alone lets the merge go ahead.
    @Test func noRoundIsSavedWhileTheMergeVetoIsHeld() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let runner = stages(h, at: world.now)
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                              ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }))
        let entered = TestLatch(), release = TestLatch()
        let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in entered.signal(); await release.wait(); return .critique("YES") }
        var merged = false
        let watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
            workerIsWorking: { _ in false }, read: { _ in ready(merged: merged) },
            oracleMerge: { task, snapshot in
                let status = OperatorDigest(state: h.workspace.state, at: world.now, oracleOn: true, task: task.id)
                if case .agreed = await oracle.consult.consult(.mergeVeto(head: snapshot.head, status: status), binding: .init(claim: SignalClaim(task))) { return true }
                return false
            }, merge: { _, _, intend in try intend(); merged = true; return .merged(commit: "m1abcdef9", head: "aabbcc") }))
        let pass = Task { await watch.pass() }
        await entered.wait()
        #expect(h.workspace.state.operatorSession?.oracleRounds.isEmpty == true && !merged)
        #expect(oracle.prompts.first.map { $0.contains("Judge this explicitly enabled automatic merge.") && $0.contains("Head: aabbcc.") } == true)
        release.signal(); await pass.value
        #expect(merged && h.workspace.state.operatorSession?.oracleRounds.isEmpty == true)
        #expect(h.workspace.state.task(id: task)?.signalTask?.merge?.accepted == true)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase != .done, "AiTerm's merge goes back to the worker")
    }

    /// A merge whose Oracle veto is held, and with `holdingTheRead` its first host read too: the watch, Then, the stage
    /// owner and the tool handler share one in-flight set.
    @MainActor private final class HeldMerge {
        let entered = TestLatch(), release = TestLatch()
        let reading = TestLatch(), read = TestLatch()
        private var holdsRead: Bool
        private(set) var merged = false
        private(set) var watch: RequestWatch!, handler: SignalOperatorToolHandler!
        init(_ h: SignalHarness, world: SignalWorld, holdingTheRead: Bool = false, ready: @escaping (Bool) -> RequestWatch.Snapshot) {
            holdsRead = holdingTheRead
            let effects = OperatorInFlight(), entered = entered, release = release
            let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
                workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, _ in "worker-window" }, restore: { $0 }), effects: effects)
            let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now },
                                  ports: .init(workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, _ in }), effects: effects)
            let oracle = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }) { _ in entered.signal(); await release.wait(); return .critique("YES") }
            watch = RequestWatch(workspace: h.workspace, stages: runner, then: then, ports: .init(
                workerIsWorking: { _ in false }, read: { [unowned self] _ in
                    if self.holdsRead { self.holdsRead = false; self.reading.signal(); await self.read.wait() }
                    return ready(self.merged)
                },
                oracleMerge: { task, snapshot in
                    let status = OperatorDigest(state: h.workspace.state, at: world.now, oracleOn: true, task: task.id)
                    if case .agreed = await oracle.consult.consult(.mergeVeto(head: snapshot.head, status: status), binding: .init(claim: SignalClaim(task))) { return true }
                    return false
                }, merge: { [unowned self] _, _, intend in try intend(); self.merged = true; return .merged(commit: "m1abcdef9", head: "aabbcc") }), effects: effects)
            let off = ScriptedOracle(h.workspace, folder: h.folder, now: { world.now }, on: false)
            handler = SignalOperatorToolHandler(workspace: h.workspace, stages: runner,
                questions: QuestionRounds(workspace: h.workspace, journal: h.journal, now: { world.now }, oracle: off.consult, ports: .init(
                    question: { _, _ in nil }, deliver: { _, _, _ in })),
                choices: AgentChoiceRounds(workspace: h.workspace, now: { world.now }, oracle: off.consult, ports: .init(weeklyUsage: { [:] }, installedAgents: { [] })),
                journal: h.journal, now: { world.now }, ports: .init(oracleEnabled: { false }, workerQuestion: { _, _ in false }, read: { _ in [:] },
                    message: { _, _, _, _ in }, openTab: { _, _, _, _, _, _ in [:] }, jiraSearch: { _ in [] }, consult: { _, _ in .unavailable(.off) }),
                effects: effects)
        }
    }

    /// A stage result of any outcome waits for the merge holding its task: the Operator's block is refused as at work,
    /// and the merge goes ahead once its veto agrees.
    @Test func aStageResultIsRefusedWhileTheMergeHoldsItsTaskAndTheMergeGoesAhead() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = HeldMerge(h, world: world, ready: { ready(merged: $0) })
        let pass = Task { await rig.watch.pass() }
        await rig.entered.wait()
        let session = try #require(h.workspace.state.operatorSession)
        let answer = await rig.handler.respond(OperatorRequest(requestId: "blocked", operatorId: session.id.uuidString, tool: "finish_stage",
            arguments: ["task": .string(task.uuidString), "stage": 1, "ownership": 0, "key": "blocked", "outcome": "blocked",
                        "evidence": "The worker gave up."], generation: session.generation))
        #expect(answer.message == SignalTransitionError.workerIsWorking.localizedDescription)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .working)
        rig.release.signal(); await pass.value
        #expect(rig.merged && h.workspace.state.task(id: task)?.signalTask?.merge?.accepted == true)
    }

    /// A block that reaches the stage while the merge's veto is out, by any path, stops the merge.
    @Test func aStageBlockedWhileTheVetoIsOutStopsTheMerge() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = HeldMerge(h, world: world, ready: { ready(merged: $0) })
        let pass = Task { await rig.watch.pass() }
        await rig.entered.wait()
        try h.workspace.mutate { state in
            try state.updateSignalTask(task) { $0 = try SignalTransitions.apply(.block("The worker gave up."), to: $0, at: world.now) }
        }
        rig.release.signal(); await pass.value
        #expect(!rig.merged)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .blocked)
    }

    /// A block that lands while the pass reads the request, before the merge holds the task, also stops the merge: the
    /// stage left the phase the pass read it in.
    @Test func aStageBlockedWhileThePassReadsTheRequestIsNeverMerged() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true)
        let task = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = HeldMerge(h, world: world, holdingTheRead: true, ready: { ready(merged: $0) })
        let pass = Task { await rig.watch.pass() }
        await rig.reading.wait()
        let session = try #require(h.workspace.state.operatorSession)
        let answer = await rig.handler.respond(OperatorRequest(requestId: "blocked", operatorId: session.id.uuidString, tool: "finish_stage",
            arguments: ["task": .string(task.uuidString), "stage": 1, "ownership": 0, "key": "blocked", "outcome": "blocked",
                        "evidence": "The worker gave up."], generation: session.generation))
        #expect(answer.message == nil, "nothing holds the task while the pass reads")
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .blocked)
        rig.read.signal(); await pass.value
        #expect(!rig.merged)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .blocked)
    }

    /// Then holds its task: a stage queued meanwhile waits for it, and starts once Then lets go.
    @Test func aStageQueuedWhileThenRunsWaitsAndStartsAfterThenReleases() async throws {
        var world = SignalWorld(); let first = world.signal(then: .archive), next = world.signal(age: 1), task = world.workingTask(signal: first)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalTask(task) { $0.phase = .done } }
        let effects = OperatorInFlight(), entered = TestLatch(), release = TestLatch()
        var launches = 0
        let runner = stages(h, at: world.now, effects: effects, launched: { launches += 1 })
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in entered.signal(); await release.wait() }, remove: { _, _ in }),
            effects: effects)
        let closing = Task { await then.apply(task) }
        await entered.wait()
        h.workspace.mutate { $0.updateSignalTask(task) { record in
            record.pendingStages.append(SignalStage(signal: next, item: world.ticket().item, matchedAt: world.now,
                                                   configuration: world.state.signal(id: next)!, prompt: "/psg:review"))
        } }
        await #expect(throws: SignalTransitionError.workerIsWorking) { try await runner.finish(task, action: .advancePending) }
        #expect(launches == 0 && h.workspace.state.task(id: task)?.signalTask?.phase == .done)
        release.signal(); await closing.value
        #expect(launches == 1)
        #expect(h.workspace.state.task(id: task)?.signalTask?.current.signal == next)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .working)
    }

    @Test func pendingWorkThatArrivesDuringCleanupPreventsThenAndContinuesTheSameTask() async throws {
        var world = SignalWorld(); let first = world.signal(then: .remove), next = world.signal(age: 1), task = world.workingTask(signal: first)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        h.workspace.mutate { $0.updateSignalTask(task) { $0.phase = .done } }
        let runner = stages(h, at: world.now)
        var removed = false
        let then = ThenRunner(workspace: h.workspace, journal: h.journal, stages: runner, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, archive: { _, _ in }, remove: { _, allowed in
                h.workspace.mutate { $0.updateSignalTask(task) { record in
                    record.pendingStages.append(SignalStage(signal: next, item: world.ticket().item, matchedAt: world.now,
                                                           configuration: world.state.signal(id: next)!, prompt: "/psg:review"))
                } }
                guard allowed() else { throw ActionUnavailable("A new stage waits.") }
                removed = true
            }))
        await then.apply(task)
        #expect(!removed && h.workspace.state.tasks.map(\.id) == [task])
        #expect(h.workspace.state.task(id: task)?.signalTask?.current.signal == next)
        #expect(h.workspace.state.task(id: task)?.signalTask?.phase == .working)
    }

    /// After AiTerm's merge the worker is told once, and the stage ends only when its Done query matches after that.
    @Test func theWorkerIsToldOnceAndTheStageEndsOnItsDoneQuery() async throws {
        var world = SignalWorld(); let signal = world.signal(then: .archive, merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = MergeRig(h, world: world, runner: stages(h, at: world.now))
        await rig.watch.pass()
        #expect(rig.told == ["AiTerm merged !7 at m1abcde; carry on."] && h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        await rig.watch.pass()
        #expect(rig.told.count == 1, "the line goes once")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working && rig.archived == 0, "merged alone no longer ends it")
        rig.doneMatches = true; await rig.watch.pass()
        #expect(rig.archived == 1 && rig.told.count == 1 && rig.merges == 1)
    }
    /// A Done query that already matched before the merge, as when the worker moved the ticket, ends the stage at the
    /// first read after the hand-back: the hand-back reads it afresh from not matching.
    @Test func aDoneQueryMatchingBeforeTheMergeEndsTheStageAfterTheHandBack() async throws {
        var world = SignalWorld(); let signal = world.signal(then: .archive, merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = true }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = MergeRig(h, world: world, runner: stages(h, at: world.now)); rig.doneMatches = true
        await rig.watch.pass()
        #expect(rig.told.count == 1 && rig.archived == 0 && h.workspace.state.task(id: id)?.signalTask?.doneMatched == false)
        await rig.watch.pass()
        #expect(rig.archived == 1)
    }
    /// A merge whose answer or confirming read was lost, or that the host had not finished, is still AiTerm's once a read
    /// shows the request merged at the head it asked for.
    @Test(arguments: ["lost read", "lost answer", "waiting"]) func aMergeTheHostConfirmsLaterIsStillAiTerms(_ how: String) async throws {
        var world = SignalWorld(); let signal = world.signal(then: .archive, merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = MergeRig(h, world: world, runner: stages(h, at: world.now))
        switch how {
        case "lost read": rig.readLostAfterMerge = true
        case "lost answer": rig.answerLost = true; rig.answer = .waiting("unused")
        default: rig.answer = .waiting("The merge is still running.")
        }
        await rig.watch.pass()
        #expect(rig.told.isEmpty && h.workspace.state.task(id: id)?.signalTask?.merge?.head == "aabbcc")
        rig.merged = true; await rig.watch.pass()
        #expect(rig.told == ["AiTerm merged !7 at m1abcde; carry on."] && rig.archived == 0)
    }
    /// Merged by someone else, with no merge of AiTerm's saved or after AiTerm's was refused or never sent, or closed:
    /// the stage ends as before and the worker is not told.
    @Test(arguments: ["no merge", "refused", "never sent", "closed"]) func aMergeBySomeoneElseOrACloseEndsTheStage(_ how: String) async throws {
        var world = SignalWorld(); let signal = world.signal(then: .archive, merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let rig = MergeRig(h, world: world, runner: stages(h, at: world.now))
        switch how {
        case "refused": rig.answer = .blocked("It has conflicts.")
        case "never sent": rig.reachesHost = false
        default: rig.oracleSays = false
        }
        await rig.watch.pass()
        #expect(rig.archived == 0 && h.workspace.state.task(id: id)?.signalTask?.merge == nil)
        if how == "closed" { rig.closed = true } else { rig.merged = true }
        await rig.watch.pass()
        #expect(rig.archived == 1 && rig.told.isEmpty)
    }
    /// With its worker gone the stage blocks, saying why; resuming it launches with the carry-on line, and a launch that
    /// fails before reaching the worker keeps the line for the next resume.
    @Test func aStageWhoseWorkerIsGoneBlocksAndResumeSendsTheLine() async throws {
        var world = SignalWorld(); let signal = world.signal(merges: true), id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.doneMatched = false; $0.phase = .watching }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        var prompts: [String] = [], fails = true
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now }, ports: .init(
            workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, prompt in
                prompts.append(prompt)
                if fails { fails = false; throw ActionUnavailable("Claude has not passed Messaging for its installed version.") }
                return "worker-window"
            }, restore: { $0 }))
        let rig = MergeRig(h, world: world, runner: runner); rig.hasWorker = false
        await rig.watch.pass()
        #expect(rig.told.isEmpty && h.workspace.state.task(id: id)?.signalTask?.phase == .blocked)
        #expect(h.workspace.state.task(id: id)?.signalTask?.blockedReason == "AiTerm merged !7 at m1abcde; its worker is gone.")
        try await runner.resume(id)
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .blocked && h.workspace.state.task(id: id)?.signalTask?.merge?.handBackOwed == true)
        try await runner.resume(id)
        #expect(prompts.count == 2 && prompts.allSatisfy { $0.hasSuffix("\n\nAiTerm merged !7 at m1abcde; carry on.") })
        let journal = try TaskJournal.read(task: id, folder: h.folder.appendingPathComponent("journals"))
        #expect(journal.contains { $0.text == .ours("AiTerm merged !7 at m1abcde; carry on.") }, "the line is journaled as a hand-back's is")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
    }
}
