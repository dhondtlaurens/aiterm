import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// finish_task answers what is true before the daemon gives up on it (snag area C, broadcast "Aikido findings 2026-11"):
/// a publication slower than the reply budget answers `running` with what is done and goes on, a later call joins it or
/// answers what it did, a fix-round push is never judged as a merge, and a merge decision reads origin as it is now.
/// The budget is shortened here; the latches hold a push (a pre-push hook, as T2, T7 and T8 had) or a request's
/// creation past it.
@MainActor @Suite(.blocking) struct OperatorFinishReplyTests {
    @MainActor struct Finishing {
        let world: OperatorWorld, run: OperatorRun, task: TaskItem, host: FakeMergeHost, prompts: OperatorMergeTests.Prompts
        let path: String, origin: String, sha: String
        func call(_ arguments: JSONValue = ["task": "A"]) async -> ToolAnswer { await world.call(run.id, "finish_task", arguments) }
        var publication: TaskPublication? { world.task(task.id)?.operated?.publication }
        var operated: OperatedTask? { world.task(task.id)?.operated }
    }

    static let budget: Duration = .milliseconds(400)

    /// A broadcast with one accepted task `A` ending in `end` on `feat/a` of a repository with a bare origin, the Oracle
    /// on or off (answering `answer` once `gate` opens), the reply budget short. `prepare` changes the task before the
    /// world is made from it; `host` scripts the code host.
    func finishing(end: TaskEnd = .draftMR, slices: Slices = Slices(merge: true), oracle: Bool = false, answer: String? = "NO.",
                   gate: OracleGate? = nil, challengeBudget: Duration = .seconds(60), budget: Duration = Self.budget,
                   host script: FakeMergeHost.Script = .init(), git: any GitRunning = GitRunner.hermetic(), polling: Bool = false,
                   prepare: (inout TaskItem, _ path: String, _ sha: String) throws -> Void = { _, _, _ in }) throws -> Finishing {
        let fixture = try GitFixture.withOrigin(branch: "feat/a")
        let project = OperatorServiceFixtures.project(path: fixture.path)
        var profile = OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: .claude)
        profile.slices = slices
        var run = OperatorServiceFixtures.run(profile, projects: [project], state: .active, planRevision: 1)
        run.taskSettings.review = "Merge after Jan approves."
        run.taskSettings.end = end
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .accepted, worktree: fixture.path,
                                                branch: "feat/a", end: end)
        task.baseBranch = "main"
        task.operated?.acceptance = TaskAcceptance(resultSHA: fixture.sha, prerequisiteSHAs: [], checkOutput: "12 passed", note: nil,
                                                   at: Date(timeIntervalSince1970: 0))
        try prepare(&task, fixture.path, fixture.sha)
        let host = FakeMergeHost(script), prompts = OperatorMergeTests.Prompts()
        let world = try Self.world(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), host: host,
                                   prompts: prompts, answer: answer, gate: gate, challengeBudget: challengeBudget, budget: budget, git: git,
                                   polling: polling)
        world.live.sessions = [OperatorServiceFixtures.session("operator", tag: run.id), OperatorServiceFixtures.session("worker", tag: task.id)]
        let sha = task.operated?.acceptance?.resultSHA ?? fixture.sha
        return Finishing(world: world, run: run, task: task, host: host, prompts: prompts, path: fixture.path, origin: fixture.origin, sha: sha)
    }

    static func world(_ state: AppState, host: FakeMergeHost, prompts: OperatorMergeTests.Prompts, answer: String?, gate: OracleGate?,
                      challengeBudget: Duration, budget: Duration = Self.budget,
                      git: any GitRunning = GitRunner.hermetic(), polling: Bool = false) throws -> OperatorWorld {
        try OperatorWorld(state, git: git, adjust: { ports in
            // A merge watch polls at once, again and again, when `polling`; otherwise it never polls.
            if polling {
                ports.clock.sleep = { purpose, duration in
                    guard purpose == .wake || purpose == .merge else { throw CancellationError() }
                    try await Task.sleep(for: purpose == .merge ? .milliseconds(20) : duration)
                }
            }
            ports.publisher = { _ in host }
            ports.secondOpinion = OperatorMergeTests.oracle(answer, gate: gate, prompts: prompts)
            ports.challengeReplyBudget = challengeBudget
            ports.finishReplyBudget = budget
            ports.hostTimeout = .seconds(600)
        })
    }

    /// A pre-push hook that waits until the test releases it, counting the pushes it held: a hook that takes longer than
    /// the reply budget, as T2's, T7's and T8's did.
    struct Hold {
        let release: URL, count: URL
        init(in path: String) throws {
            let folder = try GitFixture.folder("hold-")
            release = URL(fileURLWithPath: folder).appendingPathComponent("release")
            count = URL(fileURLWithPath: folder).appendingPathComponent("count")
            let hook = URL(fileURLWithPath: path).appendingPathComponent(".git/hooks/pre-push")
            try "#!/bin/sh\necho push >> '\(count.path)'\nwhile [ ! -e '\(release.path)' ]; do sleep 0.05; done\nexit 0\n"
                .write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        func open() { FileManager.default.createFile(atPath: release.path, contents: Data()) }
        var pushes: Int { ((try? String(contentsOf: count, encoding: .utf8)) ?? "").split(separator: "\n").count }
    }

    /// `work`'s answer if it comes within 20 seconds, which is far past the shortened budget; nil when it doesn't.
    func promptly(_ work: @escaping @MainActor @Sendable () async -> ToolAnswer) async -> ToolAnswer? {
        try? await OperatorToolHandler.within(.seconds(20), cancelling: false) { await work() }.get()
    }

    /// The wake lines typed into the Operator's tab, once the waker has sent what it holds.
    func wakes(_ world: OperatorWorld) async -> [String] {
        await world.settled()
        await world.settled()
        return world.daemon.requests("session.deliver").filter { $0.params["wake"] as? Bool == true }.compactMap { $0.params["text"] as? String }
    }

    /// The wake's news of the task: in a line of its own, or with other news (the broadcast it completed) in one.
    static let ended = "letter-ay's finish_task ended"

    // MARK: - The cause: a publication slower than the reply budget (T2)

    /// T2: pushed at ddccfbb and opened !69 while the Operator read "AiTerm isn't answering". Its request's creation held
    /// past the budget, the call answers running with the push it did; the run goes on, wakes the Operator when it ends,
    /// and the next call answers what it did without asking the host again.
    @Test func aPublicationSlowerThanTheBudgetAnswersRunningWithWhatIsDone() async throws {
        let creating = OracleGate()
        // Long enough for the push to be done on a loaded machine; the creation is held past it.
        let f = try finishing(budget: .seconds(3), host: FakeMergeHost.Script(beforeCreate: { await creating.wait() }))
        let first = Task { await f.call() }
        let early = await promptly { await first.value }
        await creating.open()
        _ = await first.value
        let answer = try #require(early?.value, "finish_task must answer within the budget while its publication goes on")
        #expect(answer["result"] == "running")
        #expect(answer["pushedSHA"]?.stringValue == f.sha)
        #expect(answer["mergeRequest"] == nil || answer["mergeRequest"] == .null)
        #expect(answer["reason"]?.stringValue?.contains("still") == true)
        #expect(await eventually(describing: "the publication ended") { f.operated?.state == .published })
        let woken = await wakes(f.world)
        #expect(woken.count == 1 && woken.first?.contains(Self.ended) == true, "\(woken)")
        let later = await f.call()
        #expect(later.value?["result"] == "published")
        #expect(later.value?["mergeRequest"]?.stringValue == FakeMergeHost.url)
        #expect(f.host.log.filter { $0.hasPrefix("create") }.count == 1)
    }

    /// T8: befb82c landed only on the third call. Every call while the push is held answers running, and git and the host
    /// see one push and one request.
    @Test func callsWhileItRunsJoinItAndRepeatNothing() async throws {
        let f = try finishing()
        let hold = try Hold(in: f.path)
        defer { hold.open() }
        let first = Task { await f.call() }
        let early = await promptly { await first.value }
        let second = await promptly { await f.call() }
        let third = await promptly { await f.call() }
        hold.open()
        _ = await first.value
        #expect(early?.value?["result"] == "running")
        #expect(second?.value?["result"] == "running")
        #expect(third?.value?["result"] == "running")
        #expect(await eventually(describing: "the publication ended") { f.operated?.state == .published })
        #expect(hold.pushes == 1)
        #expect(f.host.log.filter { $0.hasPrefix("create") }.count == 1)
    }

    /// A merge end whose push outlived its call ends waiting to merge, and its watch polls on: the Operator is woken once
    /// that finish_task ended, never again for each poll.
    @Test func aWatchedMergeWakesOnceForTheCallThatAnsweredRunning() async throws {
        let f = try finishing(end: .merge, polling: true)
        // The watch would poll on after the test: it ends with it.
        defer { f.world.controller.stop() }
        let hold = try Hold(in: f.path)
        defer { hold.open() }
        let first = Task { await f.call() }
        let early = await promptly { await first.value }
        hold.open()
        _ = await first.value
        #expect(early?.value?["result"] == "running")
        #expect(await eventually(describing: "the watch polled several times") {
            f.host.log.filter { $0.hasPrefix("readiness") }.count >= 4
        })
        let woken = await wakes(f.world).filter { $0.contains(Self.ended) }
        #expect(woken.count == 1, "\(woken)")
        // The polls didn't use up the answer owed: the next call has it, as the latest poll left it.
        let later = await f.call()
        #expect(later.value?["result"] == "waitingToMerge", "\(later)")
        #expect(later.value?["reason"]?.stringValue?.hasPrefix(TaskFinisher.earlier(nil)) == true)
        #expect(hold.pushes == 1)
    }

    // MARK: - A fix-round push is never judged as a merge (T7)

    /// T7 on !68: a merge end in review, accepted again on its fix; the push of the fix held past the budget. Before:
    /// the Operator read "AiTerm isn't answering", retried once the push had landed and put the task back in review, and
    /// that retry was read as ending the review, so the Oracle judged a merge and refused it.
    func fixRound(oracle answer: String = "NO.") throws -> Finishing {
        try finishing(end: .merge, slices: Slices(review: true, merge: true), oracle: true, answer: answer) { task, path, sha in
            let git = GitRunner.hermetic()
            // The first round: pushed and in review on !68.
            try git.run(["push", "-q", "origin", "feat/a"], in: path)
            try git.run(["commit", "--allow-empty", "-q", "-m", "fix the review's feedback"], in: path)
            let fix = try git.run(["rev-parse", "HEAD"], in: path)
            task.operated?.publication = TaskPublication(pushedSHA: sha, mergeRequestURL: Self.request68, mergeRequestNumber: 68,
                                                         targetBranch: "main", repository: FakeMergeHost.repository)
            task.operated?.peopleReview = PeopleReview()
            task.operated?.acceptance = TaskAcceptance(resultSHA: fix, prerequisiteSHAs: [], checkOutput: "13 passed", note: nil,
                                                       at: Date(timeIntervalSince1970: 60))
        }
    }

    static let request68 = "https://git.example.net/web/acme-web/-/merge_requests/68"

    @Test func aRetriedFixRoundPushAnswersWhatItDidAndIsNeverJudgedAsAMerge() async throws {
        let f = try fixRound()
        let hold = try Hold(in: f.path)
        defer { hold.open() }
        let first = Task { await f.call() }
        let early = await promptly { await first.value }
        hold.open()
        _ = await first.value
        #expect(early?.value?["result"] == "running")
        #expect(await eventually(describing: "the fix pushed, back in review") { f.operated?.state == .inReview })
        let retry = await f.call()
        #expect(retry.value?["result"] == "inReview")
        #expect(retry.value?["pushedSHA"]?.stringValue == f.sha)
        #expect(f.prompts.list.isEmpty, "a fix-round push is never judged as a merge")
        #expect(!f.host.log.contains { $0.hasPrefix("merge") })
        #expect(f.operated?.peopleReview?.ended != true)
        // Nothing kept any more: the next call is the Operator's own, which ends the review and is judged.
        _ = await f.call()
        #expect(f.prompts.list.count == 1)
    }

    /// T7 across a restart: the fix's push landed and the task is back in review when AiTerm quits, before the retry. The
    /// saved marker says the retry is owed an answer: it answers inReview, and the Oracle isn't asked.
    @Test func aRetryAfterARestartStillAnswersInReview() async throws {
        let f = try fixRound()
        let hold = try Hold(in: f.path)
        defer { hold.open() }
        let first = Task { await f.call() }
        let early = await promptly { await first.value }
        hold.open()
        _ = await first.value
        #expect(early?.value?["result"] == "running")
        #expect(await eventually(describing: "the fix pushed, back in review") { f.operated?.state == .inReview })
        f.world.controller.stop()
        let restarted = try Self.world(f.world.state, host: f.host, prompts: f.prompts, answer: "NO.", gate: nil, challengeBudget: .seconds(60))
        restarted.live.sessions = f.world.live.sessions
        let retry = await restarted.call(f.run.id, "finish_task", ["task": "A"])
        #expect(retry.value?["result"] == "inReview")
        #expect(f.prompts.list.isEmpty)
        #expect(restarted.task(f.task.id)?.operated?.peopleReview?.ended != true)
    }

    /// A restart while a draft's push ran: the marker is saved, the run died with the app, the task still accepted. The
    /// next call isn't refused for having nothing to join: it resumes from the saved steps, through the gate as any call.
    @Test func aCallAfterARestartResumesWhatTheRunLeft() async throws {
        let f = try finishing(budget: .seconds(60)) { task, _, sha in
            task.operated?.publication = TaskPublication()
            task.operated?.publication?.unanswered = sha
        }
        let answer = await f.call()
        #expect(answer.value?["result"] == "published", "\(answer)")
        #expect(answer.value?["pushedSHA"]?.stringValue == f.sha)
        #expect(f.host.log.filter { $0.hasPrefix("create") }.count == 1)
        #expect(f.publication?.unanswered == nil)
    }

    /// A merge the Oracle said yes to, acted on with its challengeId while its push is held: that call answers running.
    /// The same call again is never answered from that saved `running`: it joins the run, then answers what it did.
    @Test func aChallengedFinishThatAnsweredRunningIsNotReplayedAsRunning() async throws {
        let judging = OracleGate()
        let f = try finishing(end: .merge, oracle: true, answer: "YES", gate: judging, challengeBudget: .milliseconds(200))
        let hold = try Hold(in: f.path)
        defer { hold.open() }
        let pending = await f.call()
        let id = try #require(pending.value?["challengeId"]?.stringValue)
        await judging.open()
        #expect(await eventually(describing: "the Oracle's yes kept") {
            f.world.run(f.run.id)?.challenges.first { $0.id == id }?.stage == .ready
        })
        let acting: JSONValue = ["task": "A", "challengeId": .string(id)]
        let first = Task { await f.call(acting) }
        let early = await promptly { await first.value }
        #expect(early?.value?["result"] == "running")
        let again = await promptly { await f.call(acting) }
        #expect(again?.value?["result"] == "running")
        hold.open()
        _ = await first.value
        #expect(await eventually(describing: "the push ended") { f.publication?.pushedSHA == f.sha && !f.world.controller.finisher.running.contains(f.task.id) })
        let after = await f.call(acting)
        #expect(after.value?["result"] != "running")
        #expect(after.value?["pushedSHA"]?.stringValue == f.sha)
        #expect(hold.pushes == 1)
    }

    // MARK: - Fetch before a merge decision (!71)

    /// !71, merged on GitLab as 988ed6c: origin's main holds the accepted commit through a merge commit made on the host,
    /// and origin/main here is stale. finish_task fetches, records it merged, and asks no Oracle and nothing of the host.
    @Test func aRequestMergedOnTheHostIsRecordedAsMergedAfterAFetch() async throws {
        // Nothing is held: the budget is long, so a slow fetch on a loaded machine is still this call's answer.
        let f = try finishing(end: .merge, oracle: true, budget: .seconds(60)) { task, path, sha in
            let git = GitRunner.hermetic()
            try git.run(["push", "-q", "origin", "feat/a"], in: path)
            let origin = try git.run(["remote", "get-url", "origin"], in: path)
            let main = try git.run(["rev-parse", "main"], in: origin)
            let tree = try git.run(["rev-parse", "\(sha)^{tree}"], in: origin)
            let merge = try git.run(["commit-tree", tree, "-p", main, "-p", sha, "-m", "Merge branch 'feat/a' into 'main'"], in: origin)
            try git.run(["update-ref", "refs/heads/main", merge], in: origin)
            task.operated?.publication = TaskPublication(pushedSHA: sha, mergeRequestURL: FakeMergeHost.url, mergeRequestNumber: 71,
                                                         targetBranch: "main", repository: FakeMergeHost.repository)
        }
        let answer = await f.call()
        #expect(answer.value?["result"] == "published", "\(answer)")
        #expect(answer.value?["merged"] == true)
        #expect(answer.value?["reason"]?.stringValue?.contains("already in main on origin") == true)
        #expect(f.prompts.list.isEmpty, "a merge made on the host is not a new merge")
        #expect(!f.host.log.contains { $0.hasPrefix("merge") || $0.hasPrefix("create") })
    }

    /// A git whose first fetch waits until the test lets it go: the task changes meanwhile.
    final class HeldFetch: GitRunning, @unchecked Sendable {
        let inner = GitRunner.hermetic(), go = DispatchSemaphore(value: 0)
        private let state = Mutex((held: false, fetching: false))
        var fetching: Bool { state.withLock { $0.fetching } }
        func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
            let hold = args.contains("fetch") && state.withLock { s in defer { s.held = true }; if !s.held { s.fetching = true }; return !s.held }
            if hold { go.wait() }
            return try inner.run(args, in: dir, timeout: timeout, environment: environment)
        }
    }

    /// !71's commit merged on the host, and accepted again on a new commit while finish_task fetched: what the fetch found
    /// was for the old commit, so the new one is never recorded as merged.
    @Test func aFetchForACommitAcceptedAgainMeanwhileIsNotUsed() async throws {
        let held = HeldFetch()
        let f = try finishing(end: .merge, budget: .seconds(60), git: held) { task, path, sha in
            let git = GitRunner.hermetic()
            try git.run(["push", "-q", "origin", "feat/a"], in: path)
            let origin = try git.run(["remote", "get-url", "origin"], in: path)
            try git.run(["update-ref", "refs/heads/main", sha], in: origin)
            task.operated?.publication = TaskPublication(pushedSHA: sha, mergeRequestURL: FakeMergeHost.url, mergeRequestNumber: 71,
                                                         targetBranch: "main", repository: FakeMergeHost.repository)
        }
        defer { held.go.signal() }
        let call = Task { await f.call() }
        #expect(await eventually(describing: "the fetch under way") { held.fetching })
        try GitRunner.hermetic().run(["commit", "--allow-empty", "-q", "-m", "more"], in: f.path)
        let newer = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: f.path)
        f.world.workspace.mutate { state in state.updateOperated(f.task.id) { $0.acceptance?.resultSHA = newer } }
        held.go.signal()
        let answer = await call.value
        #expect(answer.value?["result"] == "refused", "\(answer)")
        #expect(answer.value?["reason"]?.stringValue == PublicationGuard.changedMidway)
        #expect(f.publication?.merged != true)
        #expect(f.operated?.state == .accepted)
    }

    /// Origin can't be fetched: AiTerm can't tell whether the commit is merged already, so it says so and does nothing.
    /// With the Oracle on the call is refused before the Oracle is asked; with it off finish_task answers failed. Neither
    /// pushes nor records a problem.
    @Test(arguments: [true, false]) func aFetchThatFailsIsSaidAndNeverReadAsNotMerged(oracle: Bool) async throws {
        let f = try finishing(end: .merge, oracle: oracle, budget: .seconds(60)) { _, path, _ in
            try GitRunner.hermetic().run(["remote", "set-url", "origin", path + "-gone"], in: path)
        }
        let answer = await f.call()
        let said = answer.message ?? answer.value?["reason"]?.stringValue ?? ""
        #expect(said.contains("couldn’t fetch main from origin"), "\(answer)")
        if !oracle { #expect(answer.value?["result"] == "failed") }
        #expect(f.prompts.list.isEmpty)
        #expect(f.publication?.pushedSHA == nil)
        #expect(f.publication?.problem == nil)
        #expect(f.host.log.isEmpty)
    }

    /// The call that would end a merge end's review, with the Oracle off and origin unreachable: the fetch fails before
    /// anything changes, so the review isn't ended and the task stays in review.
    @Test func aFetchThatFailsLeavesTheReviewAsItWas() async throws {
        let f = try finishing(end: .merge, slices: Slices(review: true, merge: true), budget: .seconds(60)) { task, path, sha in
            task.operated?.state = .inReview
            task.operated?.publication = TaskPublication(pushedSHA: sha, mergeRequestURL: Self.request68, mergeRequestNumber: 68,
                                                         targetBranch: "main", repository: FakeMergeHost.repository)
            task.operated?.peopleReview = PeopleReview()
            try GitRunner.hermetic().run(["remote", "set-url", "origin", path + "-gone"], in: path)
        }
        let answer = await f.call()
        #expect(answer.value?["result"] == "failed", "\(answer)")
        #expect(answer.value?["reason"]?.stringValue?.contains("couldn’t fetch main from origin") == true)
        #expect(f.operated?.state == .inReview)
        #expect(f.operated?.peopleReview?.ended != true)
        #expect(f.host.log.isEmpty)
    }
}
