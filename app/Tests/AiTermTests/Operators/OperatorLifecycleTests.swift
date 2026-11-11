import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite struct OperatorLifecycleTests {
    @Test func cancellingAPassDropsItsRemainingReadsAndKeepsAReplacementOwned() async {
        let work = OperatorWork(), pass = TickPass(work: work), oldGate = SleepGate(), newGate = SleepGate()
        let old = UUID(), skipped = UUID(), replacement = UUID()
        var read: [UUID] = []
        pass.run([old, skipped]) { id in read.append(id); await oldGate.wait(.zero) }
        await eventually { oldGate.asked.count == 1 }
        pass.cancel()
        pass.run([replacement]) { id in read.append(id); await newGate.wait(.zero) }
        await eventually { newGate.asked.count == 1 }
        oldGate.open()
        // The old pass ends; the replacement is still held.
        await work.settled(leaving: 1)
        pass.run([UUID()]) { read.append($0) }
        #expect(read == [old, replacement], "The old completion cannot release the new pass's slot")
        newGate.open()
        await work.settled()
    }

    @Test func stoppingDropsSummaryWaitsAndLateCallbacksCannotCompleteTheRun() async throws {
        let project = OperatorServiceFixtures.project(), gate = SleepGate()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) {
            $0.clock.overrideSleep(.summary) { await gate.wait($0) }
        }
        try world.controller.stop(task: task.id)
        await eventually { gate.asked.count == 1 }
        world.controller.stop()
        gate.open()
        await world.settled()
        #expect(world.controller.summaryWaits.isEmpty)
        #expect(world.run(run.id)?.summaryGivenUp == false)
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .active } }
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.state == .active, "A stopped runtime ignores callbacks from old jobs")
    }
}

extension OperatorWakerTests {
    @Test func stoppingDropsCoalescedNewsAndRestartOnlySendsFreshNews() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        waker.say(.reconnected, to: run.id)
        await hand.started(1)
        waker.stop()
        hand.releaseAll()
        await work.settled()
        waker.say(.broadcastComplete, to: run.id)
        waker.operatorSessionChanged(run.id)
        #expect(lines.isEmpty)
        waker.start()
        waker.say(.resumed, to: run.id)
        await hand.release(2)
        await work.settled()
        #expect(lines == ["[AiTerm] resumed, call run_status"])
    }
}

extension WorkerTurnReaderTests {
    @Test func stoppingDiscardsAnOutstandingTurnReading() async throws {
        let (world, _, task, _) = try makeWorld(worker: .idle)
        world.controller.stop()
        await world.settled()
        #expect(world.controller.turns.readings[task.id] == nil)
    }
}

// -- Stop ends everything the runtime started (plan 2026-11-10, phase 5: Stop left pause notes, the closing sweep and
// replaced registrations running) --------------------------------------------------------------------------------

extension RunControlsTests {
    /// Stop ends the pause notes still to be typed: the one the helper holds lands as it may, and none follows it.
    @Test func stoppingEndsThePauseNotesStillToBeTyped() async throws {
        let (world, run, _) = try pausingWorld(daemon: RecordingDaemon(holding: "session.deliver"))
        try world.controller.pause(run: run.id)
        try await world.daemon.received("session.deliver")
        world.controller.stop()
        world.daemon.release()
        await world.settled()
        #expect(notes(world) == ["w2: pause"], "no note after Stop")
    }

    /// A batch of notes from before a Stop types nothing after the Start that follows it (phase 5, review round 1): pause,
    /// its first note held, Stop, Start, the note let go.
    @Test func aBatchOfNotesFromBeforeAStopTypesNothingAfterAStart() async throws {
        let (world, run, _) = try pausingWorld(daemon: RecordingDaemon(holding: "session.deliver"))
        try world.controller.pause(run: run.id)
        try await world.daemon.received("session.deliver")
        world.controller.stop()
        world.controller.start()
        defer { world.controller.stop() }
        world.daemon.release()
        await world.settled()
        #expect(notes(world) == ["w2: pause"], "no note after Stop, nor after the Start that followed it")
    }
}

extension OperatorLifecycleTests {
    /// Stop ends the closing of ended broadcasts' windows after an attach: the close the helper holds lands as it may, and
    /// no other window is closed after it.
    @Test func stoppingEndsTheClosingOfEndedBroadcastsWindows() async throws {
        let project = OperatorServiceFixtures.project()
        var first = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        var second = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        first.intent = .stopped
        second.intent = .stopped
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [first, second]),
                                      daemon: RecordingDaemon(holding: "window.close"))
        world.controller.daemonAttached()
        world.show([OperatorServiceFixtures.session("op1", window: "w1", tag: first.id),
                    OperatorServiceFixtures.session("op2", window: "w2", tag: second.id)])
        try await world.daemon.received("window.close")
        world.controller.stop()
        world.daemon.release()
        await world.settled()
        #expect(world.daemon.requests("window.close").count == 1, "no window closed after Stop")
    }

    /// Stop ends a registration of the runs' tokens that a later attach replaced: neither goes on once the helper
    /// answers the registration it holds.
    @Test func stoppingEndsARegistrationALaterAttachReplaced() async throws {
        let project = OperatorServiceFixtures.project()
        let open = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var ended = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        ended.intent = .stopped
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [open, ended]),
                                      daemon: RecordingDaemon(holding: "operator.register"))
        for run in [open, ended] {
            _ = try OperatorCommand.prepare(run: run, projects: [project], home: world.ports.home, token: OperatorCommand.makeToken())
        }
        world.controller.daemonAttached()
        try await world.daemon.received("operator.register")
        world.controller.daemonAttached()
        try await world.daemon.received("operator.register", count: 2)
        world.controller.stop()
        world.daemon.release()
        await world.settled()
        #expect(world.daemon.requests("operator.revoke").isEmpty, "no token revoked after Stop")
    }
}

extension OperatorLifecycleTests {
    /// After a Stop and a Start, a setting saved in Settings › Operator reaches the broadcast as it did before the Stop,
    /// without waiting for a tool call or a tick (phase 5, review round 1).
    @Test func afterAStopAndAStartASavedOracleSettingReachesTheBroadcast() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true), projects: [project], state: .active,
                                              planRevision: 1)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        world.controller.stop()
        world.controller.start()
        defer { world.controller.stop() }
        var profile = run.profile
        profile.oracle.isOn = false
        try OperatorProfileStore.save(profile, world.ports.preferences)
        await eventually(describing: "the saved setting heard") { world.run(run.id)?.profile.oracle.isOn == false }
    }
}

/// Oracle cancellation reaches the child process, not just a Swift waiter. The stub runs sleep,
/// never an agent; its PID is owned by this case and cleaned up even when the regression fails.
@MainActor @Suite(.blocking) struct OperatorOracleLifecycleTests {
    @Test(arguments: ["Stop", "End"], ["gate", "critique"])
    func endingOracleWorkTerminatesItsProcess(_ ending: String, _ kind: String) async throws {
        let folder = try ScratchFolder.make("operator-oracle-stop-")
        let pidFile = folder.appendingPathComponent("child.pid")
        let runner = SecondOpinionRunner(locate: { _ in "/bin/sh" }, run: { _, _, _, _, _ in
            try await AgentProcess.run("/bin/sh", ["-c", "echo $$ > \"$1\"; exec /bin/sleep 600", "stub", pidFile.path],
                                       environment: [:], in: folder.path, timeout: .seconds(600))
        })
        let world: OperatorWorld, run: OperatorRun
        if kind == "gate" {
            (world, run, _) = try OperatorGateTests().makeWorld(runner: runner)
        } else {
            let r = try await OperatorReviewTests().reviewed(.inReview) {
                $0.secondOpinion = runner
                $0.challengeReplyBudget = .seconds(60)
            }
            world = r.world; run = r.run
            world.workspace.mutate { $0.updateRun(id: run.id) { $0.profile.oracle.isOn = true } }
            r.host.update { $0.threads = [ReviewThread(id: "d1", resolved: false, lastAuthor: "jan", lastBody: "Check this.")] }
        }
        let work = world.ports.work
        var answered = false
        work.start {
            _ = await world.call(run.id, kind == "gate" ? "gate_command" : "critique_thread",
                                 kind == "gate" ? ["command": "curl https://example.org", "directory": "/tmp"] : ["task": "A", "thread": "d1"])
            answered = true
        }
        await eventually(describing: "the stub Oracle process to start") { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try #require((try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) }; world.controller.stop() }
        if ending == "Stop" { world.controller.stop() }
        else { try await world.controller.end(run: run.id) }
        // A cancelled process is reaped before AgentProcess returns. This deadline also bounds a broken owner.
        await eventually(describing: "\(ending) to terminate the \(kind) Oracle process") { kill(pid, 0) != 0 }
        // Clean the deliberately surviving process on the old code before joining its request.
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        await work.settled()
        #expect(answered)
        if kind == "critique" { #expect(world.state.tasks.first?.operated?.threadCritiques.isEmpty == true) }
    }
}

extension OperatorOracleLifecycleTests {
    @Test func aCancelledOracleCompletionCannotClearOrSettleItsReplacement() async {
        let work = OperatorWork(), jobs = OracleJobs(work: work), run = UUID()
        let oldGate = OracleGate(), newGate = OracleGate(), prompts = OperatorMergeTests.Prompts()
        var recorded: [String] = []
        func start(_ text: String, gate: OracleGate) {
            jobs.start(.challenge("same"), run: run, task: nil,
                       runner: .answering(text, gate: gate, receivePrompt: { prompts.append($0) }),
                       opinion: OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude).oracle,
                       prompt: text, folder: URL(fileURLWithPath: "/tmp"), projects: [], acting: { _ in }) { verdict in
                if case .critique(let text) = verdict { recorded.append(text) }
            }
        }
        start("old", gate: oldGate)
        await eventually { prompts.list == ["old"] }
        jobs.cancel()
        start("new", gate: newGate)
        await eventually { prompts.list == ["old", "new"] }
        await oldGate.open()
        await work.settled(leaving: 1)
        #expect(jobs.contains(.challenge("same")) && recorded.isEmpty)
        await newGate.open()
        await work.settled()
        #expect(!jobs.contains(.challenge("same")) && recorded == ["new"])
    }
}

extension OperatorOracleLifecycleTests {
    @Test func aGateVerdictReturnedAfterCancellationCannotOpenAQuestion() async throws {
        let gate = OracleGate(), prompts = OperatorMergeTests.Prompts()
        let runner = SecondOpinionRunner.answering("ASK: the person decides.", gate: gate, receivePrompt: { prompts.append($0) })
        let (world, run, _) = try OperatorGateTests().makeWorld(runner: runner)
        var answer: ToolAnswer?
        world.ports.work.start {
            answer = await world.call(run.id, "gate_command", ["command": "npm install", "directory": "/tmp"])
        }
        await eventually { prompts.list.count == 1 }
        world.controller.stop()
        await gate.open()
        await world.ports.work.settled()
        #expect(world.run(run.id)?.questions.isEmpty == true, "A cancelled Oracle cannot ask the person later")
        #expect(answer?.value?["decision"] == "allow")
    }
}
