import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Snag G of broadcast "Aikido findings 2026-11": T1 was accepted, its merge end waiting on !65, which needed origin/main
/// merged in, and message_task answered "T1 is accepted and its commit is on origin: there is no worker to steer"; open_tab
/// refused too. An accepted task is steered while its request is open and not merged: it goes back to working, and no
/// publication of it runs while it is steered.
@MainActor @Suite(.blocking) struct OperatorSteerAcceptedTests {
    struct Steered {
        let world: OperatorWorld, run: OperatorRun, task: TaskItem, host: FakeMergeHost, sha: String
    }

    static let url65 = "https://git.example.net/web/acme-web/-/merge_requests/65"

    /// T1, ending in a merge with the Merge slice on and the Oracle off: accepted on its branch's commit, pushed, and its
    /// request !65 open on the host and waiting, its window `w1` open with its worker idle in it.
    func t1(daemon: RecordingDaemon = RecordingDaemon(), open: Bool = true) throws -> Steered {
        let git = GitRunner.hermetic()
        let fixture = try GitFixture.withOrigin(branch: "feat/t1")
        try git.run(["push", "-q", "origin", "feat/t1"], in: fixture.path)
        let project = OperatorServiceFixtures.project(path: fixture.path)
        var profile = OperatorServiceFixtures.profile()
        profile.slices = Slices(merge: true)
        let run = OperatorServiceFixtures.run(profile, projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "T1", state: .accepted, worktree: fixture.path,
                                                branch: "feat/t1", end: .merge)
        task.baseBranch = "main"
        task.windowId = "w1"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0))
        task.operated?.acceptance = TaskAcceptance(resultSHA: fixture.sha, prerequisiteSHAs: [], checkOutput: "12 passed", note: nil,
                                                   at: Date(timeIntervalSince1970: 0))
        task.operated?.publication = TaskPublication(pushedSHA: fixture.sha, mergeRequestURL: Self.url65, mergeRequestNumber: 65,
                                                     targetBranch: "main", waitingSince: Date(), repository: FakeMergeHost.repository)
        let host = FakeMergeHost()
        if open {
            host.update {
                $0.existing = MergeRequest(iid: 65, title: "T1: Task T1", sourceBranch: "feat/t1", targetBranch: "main", author: "aiterm",
                                           state: "opened", draft: false, url: Self.url65)
                $0.readiness = [.blocked("it has conflicts")]
            }
        }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon) { ports in
            ports.publisher = { _ in host }
            ports.hostTimeout = .seconds(600)
            // A merge watch waits between its polls, so a test sees whether one is watching; a test's end cancels it.
            ports.clock.sleep = { purpose, duration in
                guard [.wake, .merge].contains(purpose) else { throw CancellationError() }
                try await Task.sleep(for: purpose == .merge ? .seconds(3600) : duration)
            }
        }
        world.show([OperatorServiceFixtures.session("operator", window: "wop", tag: run.id),
                    OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        return Steered(world: world, run: run, task: task, host: host, sha: fixture.sha)
    }

    func operated(_ s: Steered) -> OperatedTask? { s.world.task(s.task.id)?.operated }

    @Test func t1WithItsRequestOpenIsSteeredBackToWorkAndItsNewCommitGoesToTheSameRequest() async throws {
        let s = try t1()
        defer { s.world.controller.finisher.stopAll() }
        s.world.controller.finisher.resumeWatching()
        #expect(s.world.controller.finisher.watching == [s.task.id], "its merge waits")
        let answer = await s.world.call(s.run.id, "message_task", ["task": "T1", "text": "Merge origin/main in and fix the conflicts."])
        #expect(answer.value?["result"] == "delivered" && answer.value?["reopened"] == true)
        #expect(s.world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
                == ["Merge origin/main in and fix the conflicts."])
        let reopened = try #require(operated(s))
        #expect(reopened.state == .working && reopened.acceptance == nil && reopened.reopenedFrom == s.sha)
        #expect(s.world.controller.finisher.watching.isEmpty, "a task back at work is not merged")
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })

        try GitRunner.hermetic().run(["commit", "--allow-empty", "-q", "-m", "Merge origin/main"], in: s.task.worktreePath)
        let head = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: s.task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let accepted = await s.world.call(s.run.id, "mark_task", ["task": "T1", "outcome": "accepted", "sha": .string(head), "checkOutput": "12 passed"])
        #expect(accepted.value?["state"] == "accepted")
        let finished = await s.world.call(s.run.id, "finish_task", ["task": "T1"])
        #expect(finished.message == nil)
        #expect(operated(s)?.publication?.pushedSHA == head && operated(s)?.publication?.mergeRequestNumber == 65)
        #expect(!s.host.log.contains { $0.hasPrefix("create") }, "the new commit goes to !65")
    }

    @Test func aRequestNoLongerOpenOnTheHostIsNotSteered() async throws {
        let s = try t1(open: false)
        let answer = await s.world.call(s.run.id, "message_task", ["task": "T1", "text": "Merge origin/main in."])
        #expect(answer.message == "!65 is no longer open on the host: AiTerm steers an accepted task only while its request is open.")
        #expect(s.world.daemon.requests("session.deliver").isEmpty && operated(s)?.state == .accepted)
    }

    @Test func aHostThatCantBeReadSteersNothing() async throws {
        let s = try t1()
        s.host.update { $0.existingError = URLError(.timedOut) }
        let answer = await s.world.call(s.run.id, "message_task", ["task": "T1", "text": "Merge origin/main in."])
        #expect(answer.message?.hasPrefix("AiTerm couldn’t read !65 on the host to see that it is still open:") == true)
        #expect(s.world.daemon.requests("session.deliver").isEmpty && operated(s)?.state == .accepted)
    }

    @Test func whileItsPublicationRunsItIsNotSteered() async throws {
        let s = try t1()
        let gate = HeldGate()
        s.host.update { $0.beforeReadiness = { await gate.wait() } }
        let finishing = Task { await s.world.call(s.run.id, "finish_task", ["task": "T1"]) }
        await gate.started()
        let answer = await s.world.call(s.run.id, "message_task", ["task": "T1", "text": "Merge origin/main in."])
        #expect(answer.message == "AiTerm is publishing T1 now: call message_task again once finish_task answers.")
        await gate.release()
        _ = await finishing.value
        #expect(s.world.daemon.requests("session.deliver").isEmpty)
    }

    /// The finisher holds T1 from the check to the call's end: neither a finish_task nor a merge watch merges it while its
    /// message is on the way.
    @Test func nothingMergesT1WhileItsMessageIsDelivered() async throws {
        let daemon = RecordingDaemon(holding: "session.deliver")
        let s = try t1(daemon: daemon)
        defer { s.world.controller.finisher.stopAll() }
        s.host.update { $0.readiness = [.ready(head: s.sha)] }
        s.world.controller.finisher.resumeWatching()
        let sending = Task { await s.world.call(s.run.id, "message_task", ["task": "T1", "text": "Merge origin/main in."]) }
        try await daemon.received("session.deliver")
        #expect(s.world.controller.finisher.watching.isEmpty)
        s.world.controller.finisher.resumeWatching()
        #expect(s.world.controller.finisher.watching.isEmpty, "no watch starts while it is steered")
        #expect(await s.world.call(s.run.id, "finish_task", ["task": "T1"]).value?["reason"]
                == "T1 is being steered now: call finish_task again once message_task or open_tab answers.")
        daemon.release()
        #expect(await sending.value.value?["reopened"] == true)
        #expect(!s.host.log.contains { $0.hasPrefix("merge") || $0.hasPrefix("readiness") })
    }

    /// Read fresh once the host answered: a Pause, an End or a takeover during the read delivers nothing.
    @Test(arguments: ["pause", "end", "takeover"])
    func nothingIsDeliveredOnceTheBroadcastOrTaskChangedDuringTheHostRead(_ change: String) async throws {
        let s = try t1()
        let gate = HeldGate()
        s.host.update { $0.beforeExisting = { await gate.wait() } }
        let sending = Task { await s.world.call(s.run.id, "message_task", ["task": "T1", "text": "Merge origin/main in."]) }
        await gate.started()
        s.world.workspace.mutate { state in
            switch change {
            case "pause": state.updateRun(id: s.run.id) { $0.intent = .paused }
            case "end": state.updateRun(id: s.run.id) { $0.state = .stopped; $0.intent = .stopped }
            default: state.updateOperated(s.task.id) { $0.takenOver = true; $0.ownership += 1 }
            }
        }
        await gate.release()
        #expect(await sending.value.message != nil)
        // Only the Operator's words are looked for: AiTerm's own note on a takeover may go to the worker.
        #expect(!s.world.daemon.requests("session.deliver").contains { $0.params["text"] as? String == "Merge origin/main in." })
        #expect(operated(s)?.state == .accepted)
    }

    @Test func aMessageNotDeliveredLeavesT1AcceptedAndWatchedAgain() async throws {
        let s = try t1()
        defer { s.world.controller.finisher.stopAll() }
        s.world.controller.finisher.resumeWatching()
        s.world.daemon.deliveries = [Delivery(result: .refused, reason: "you are typing")]
        let answer = await s.world.call(s.run.id, "message_task", ["task": "T1", "text": "Merge origin/main in."])
        #expect(answer.value?["result"] == "refused" && answer.value?["reopened"] == nil)
        #expect(operated(s)?.state == .accepted && operated(s)?.acceptance?.resultSHA == s.sha)
        #expect(s.world.controller.finisher.watching == [s.task.id])
    }

    @Test func aTabOnT1OpensAndSendsItBackToWork() async throws {
        let s = try t1()
        let answer = await s.world.call(s.run.id, "open_tab", ["task": "T1", "key": "fix", "agent": "claude",
                                                               "modelReason": "The same agent.", "brief": "Merge origin/main in."])
        #expect(answer.message == nil && answer.value?["key"] == "fix")
        #expect(s.world.daemon.requests("tab.create").map { $0.params["tabKey"] as? String } == ["fix"])
        #expect(operated(s)?.state == .working && operated(s)?.reopenedFrom == s.sha)
    }

    @Test func aTabOnT1WhoseRequestIsClosedIsRefused() async throws {
        let s = try t1(open: false)
        let answer = await s.world.call(s.run.id, "open_tab", ["task": "T1", "key": "fix", "agent": "claude",
                                                               "modelReason": "The same agent.", "brief": "Merge origin/main in."])
        #expect(answer.message == "!65 is no longer open on the host: AiTerm steers an accepted task only while its request is open.")
        #expect(s.world.daemon.requests("tab.create").isEmpty && operated(s)?.state == .accepted)
    }
}
