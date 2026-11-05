import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The request `finish_task` opens, and `update_request` after it: snags !62–!65 of broadcast "Aikido findings 2026-11",
/// where drafts opened with the worker's brief as description, "KEY title" and no assignee, and the Operator had no way
/// to correct them.
@MainActor @Suite struct OperatorRequestTests {
    struct Opened {
        let world: OperatorWorld, run: OperatorRun, task: TaskItem, host: FakeMergeHost
    }

    /// A broadcast with no slices on and one accepted task `A` ending in a draft MR, on the branch of a repository with an
    /// origin; `open` records its draft as !12, opened by an earlier finish_task.
    func accepted(open: Bool = false) async throws -> Opened {
        let fixture = try GitFixture.withOrigin(branch: "feat/a")
        let project = OperatorServiceFixtures.project(path: fixture.path)
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(), projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .accepted, agent: .codex,
                                                worktree: fixture.path, branch: "feat/a", end: .draftMR)
        task.baseBranch = "main"
        task.operated?.brief = "You are T3 of the Operator's broadcast. Work in /Users/laurens/Sites/acme/.worktrees/t3."
        task.operated?.acceptance = TaskAcceptance(resultSHA: fixture.sha, prerequisiteSHAs: [], checkOutput: "12 passed", note: nil,
                                                   at: Date(timeIntervalSince1970: 0))
        let host = FakeMergeHost()
        if open {
            task.operated?.publication = TaskPublication(pushedSHA: fixture.sha, mergeRequestURL: FakeMergeHost.url, mergeRequestNumber: 12,
                                                         targetBranch: "main", repository: FakeMergeHost.repository)
            host.update {
                $0.existing = MergeRequest(iid: 12, title: "Draft: A A", sourceBranch: "feat/a", targetBranch: "main", author: "aiterm",
                                           state: "opened", draft: true, url: FakeMergeHost.url)
            }
        }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), adjust: { ports in
            ports.publisher = { _ in host }
            ports.hostTimeout = .seconds(600)
        })
        world.live.sessions = [OperatorServiceFixtures.session("operator", tag: run.id)]
        return Opened(world: world, run: run, task: task, host: host)
    }

    func publication(_ o: Opened) -> TaskPublication? { o.world.workspace.state.task(id: o.task.id)?.operated?.publication }

    // MARK: - finish_task

    @Test func finishTaskOpensTheRequestWithTheOperatorsTitleDescriptionAndAssignee() async throws {
        let o = try await accepted()
        let answer = await o.world.call(o.run.id, "finish_task", ["task": "A", "title": "PLUTO-231: Validate redirect targets",
                                                                  "description": "Validates the redirect target.", "assignee": "nathan"])
        #expect(answer.value?["result"] == "published")
        let request = try #require(o.host.request)
        #expect(request.title == "PLUTO-231: Validate redirect targets")
        #expect(request.description == "Validates the redirect target.")
        #expect(o.host.assignee == "nathan")
        #expect(publication(o)?.assignee == "nathan")
        // Called again with other words, the open request is left as it is: update_request changes it.
        _ = await o.world.call(o.run.id, "finish_task", ["task": "A", "title": "Something else"])
        #expect(o.host.request?.title == "PLUTO-231: Validate redirect targets")
        #expect(o.host.log.filter { $0.hasPrefix("create") }.count == 1)
    }

    @Test func withoutTheOperatorsWordsTheRequestNeverCarriesTheBrief() async throws {
        let o = try await accepted()
        _ = await o.world.call(o.run.id, "finish_task", ["task": "A"])
        let description = try #require(o.host.request?.description)
        #expect(!description.contains("/Users/") && !description.contains("Operator"))
        #expect(o.host.assignee == "aiterm", "the user AiTerm acts as on the host")
    }

    @Test func aRequestThatCouldNotBeAssignedSaysSo() async throws {
        let o = try await accepted()
        o.host.update { $0.editError = GitLabError.noUser("nathan") }
        let answer = await o.world.call(o.run.id, "finish_task", ["task": "A", "assignee": "nathan"])
        #expect(answer.value?["result"] == "published")
        let note = try #require(answer.value?["draftNote"]?.stringValue)
        #expect(note.contains("opened as a draft") && note.contains("couldn’t be assigned to nathan"))
        #expect(publication(o)?.assigning == true)
        // The draft is published; the next finish_task assigns it, and the one after does nothing more.
        o.host.update { $0.editError = nil }
        let again = await o.world.call(o.run.id, "finish_task", ["task": "A"])
        #expect(again.value?["result"] == "published")
        #expect(o.host.assignee == "nathan")
        #expect(publication(o)?.assignee == "nathan" && publication(o)?.assigning == nil)
        _ = await o.world.call(o.run.id, "finish_task", ["task": "A"])
        #expect(o.host.log.filter { $0.hasPrefix("edit") }.count == 2)
    }

    // MARK: - update_request

    @Test func updateRequestCorrectsTheRequestFinishTaskOpened() async throws {
        let o = try await accepted(open: true)
        let answer = await o.world.call(o.run.id, "update_request", ["task": "A", "title": "PLUTO-231: Validate redirect targets",
                                                                     "description": "Validates the redirect target.", "assignee": "nathan"])
        #expect(answer.value?["updated"] == ["title", "description", "assignee"])
        #expect(o.host.log.last == "edit 12 title PLUTO-231: Validate redirect targets; description Validates the redirect target.; assignee nathan")
        #expect(o.host.assignee == "nathan")
        #expect(publication(o)?.assignee == "nathan")
    }

    /// A request whose first assignment failed, reassigned by the Operator: the new choice is the one a later finish_task
    /// would use, and the request is no longer left to assign.
    @Test func aNewAssigneeReplacesTheChoiceStillToAssign() async throws {
        let o = try await accepted(open: true)
        o.world.workspace.mutate { $0.updateOperated(o.task.id) {
            $0.publication?.requested = RequestContent(assignee: "nathan")
            $0.publication?.assigning = true
        } }
        _ = await o.world.call(o.run.id, "update_request", ["task": "A", "assignee": "laurens"])
        #expect(publication(o)?.requested?.assignee == "laurens")
        #expect(publication(o)?.assigning == nil && publication(o)?.assignee == "laurens")
    }

    /// finish_task assigning the older choice while the Operator names a new one: the new one waits for it, so the older
    /// write never lands after it.
    @Test func aNewAssigneeWaitsForAnAssignmentInFlight() async throws {
        let o = try await accepted(open: true)
        o.world.workspace.mutate { $0.updateOperated(o.task.id) {
            $0.publication?.requested = RequestContent(assignee: "nathan")
            $0.publication?.assigning = true
        } }
        let gate = Ticker()
        o.host.update { $0.beforeEdit = { await gate.wait() } }
        let finishing = Task { await o.world.call(o.run.id, "finish_task", ["task": "A"]) }
        #expect(await eventually(describing: "finish_task to be assigning") { o.world.controller.finisher.running.contains(o.task.id) })
        let refusal = await o.world.call(o.run.id, "update_request", ["task": "A", "assignee": "laurens"]).message
        #expect(refusal?.contains("is assigning") == true)
        o.host.update { $0.beforeEdit = nil }
        await gate.tick()
        _ = await finishing.value
        #expect(o.host.assignee == "nathan")
        _ = await o.world.call(o.run.id, "update_request", ["task": "A", "assignee": "laurens"])
        #expect(o.host.assignee == "laurens")
        #expect(publication(o)?.assignee == "laurens" && publication(o)?.requested?.assignee == "laurens")
    }

    @Test func aNewAssigneeThatCannotBeSavedChangesNothing() async throws {
        let o = try await accepted(open: true)
        #expect(o.world.workspace.flush(), "the workspace saves at first")
        try FileManager.default.createDirectory(at: o.world.workspace.file.backupURL, withIntermediateDirectories: true)
        let refusal = await o.world.call(o.run.id, "update_request", ["task": "A", "assignee": "laurens"]).message
        #expect(refusal?.contains("couldn’t save the new assignee") == true)
        #expect(!o.host.log.contains { $0.hasPrefix("edit") })
    }

    @Test func updateRequestChangesOnlyWhatItIsGiven() async throws {
        let o = try await accepted(open: true)
        _ = await o.world.call(o.run.id, "update_request", ["task": "A", "description": "Better words."])
        #expect(o.host.log.last == "edit 12 description Better words.")
        #expect(await o.world.call(o.run.id, "update_request", ["task": "A", "title": "  "]).message == "Give the title, description or assignee to change.")
    }

    @Test func updateRequestNeedsARequest() async throws {
        let o = try await accepted()
        let refusal = await o.world.call(o.run.id, "update_request", ["task": "A", "title": "T"]).message
        #expect(refusal?.contains("has no merge request yet") == true)
        #expect(!o.host.log.contains { $0.hasPrefix("edit") })
    }

    @Test(arguments: ["merged", "closed", "paused", "takeover", "elsewhere"])
    func updateRequestWritesNothingOnceTheRequestOrTheTaskIsNoLongerOpenToIt(_ change: String) async throws {
        let o = try await accepted(open: true)
        switch change {
        case "merged": o.world.workspace.mutate { $0.updateOperated(o.task.id) { $0.publication?.merged = true } }
        case "closed": o.host.update { $0.existing?.state = "closed" }
        case "paused": o.world.workspace.mutate { $0.updateRun(id: o.run.id) { $0.state = .paused; $0.intent = .paused } }
        case "takeover": o.world.workspace.mutate { $0.updateOperated(o.task.id) { $0.takenOver = true; $0.ownership += 1 } }
        default: o.host.update { $0.repository = "git.example.net/other/repo" }
        }
        let answer = await o.world.call(o.run.id, "update_request", ["task": "A", "title": "T"])
        #expect(answer.value == nil, "\(change): \(answer.message ?? "")")
        #expect(!o.host.log.contains { $0.hasPrefix("edit") }, "\(change)")
    }

    // MARK: - retry_pipeline (snag G: six request pipelines failed on runner timeouts and image pulls)

    static let url69 = "https://git.example.net/web/acme-web/-/merge_requests/69"

    /// `A` with its request recorded as !69 and open on the host from its own branch, its pipeline failed on the runner.
    func failedPipeline() async throws -> Opened {
        let o = try await accepted(open: true)
        o.world.workspace.mutate { $0.updateOperated(o.task.id) { $0.publication?.mergeRequestNumber = 69; $0.publication?.mergeRequestURL = Self.url69 } }
        o.host.update {
            $0.existing = MergeRequest(iid: 69, title: "Draft: A: Task A", sourceBranch: "feat/a", targetBranch: "main", author: "aiterm",
                                       state: "opened", draft: true, url: Self.url69)
            $0.pipeline = "failed"
        }
        return o
    }

    @Test func retryPipelineRerunsTheFailedPipelineOfTheTasksOwnRequestOnce() async throws {
        let o = try await failedPipeline()
        let answer = await o.world.call(o.run.id, "retry_pipeline", ["task": "A"])
        #expect(answer.value == ["task": "A", "mergeRequest": .string(Self.url69), "retried": "pipeline 5501"])
        #expect(o.host.log == ["retry 69"], "no slice and no Oracle: nothing else is asked")
        // Asked again, the pipeline runs: nothing to retry, nothing written.
        #expect(await o.world.call(o.run.id, "retry_pipeline", ["task": "A"]).message == "!69 has nothing to retry: its pipeline is running.")
        #expect(o.host.log == ["retry 69"])
    }

    @Test(arguments: ["running", "noPipeline", "noRequest", "merged", "closed", "otherBranch", "fork", "paused", "ended", "takeover", "elsewhere"])
    func retryPipelineRetriesNothingThatIsNotTheTasksFailedOpenRequest(_ change: String) async throws {
        let o = try await failedPipeline()
        switch change {
        case "running": o.host.update { $0.pipeline = "running" }
        case "noPipeline": o.host.update { $0.pipeline = nil }
        case "noRequest": o.world.workspace.mutate { $0.updateOperated(o.task.id) { $0.publication = nil } }
        case "merged": o.world.workspace.mutate { $0.updateOperated(o.task.id) { $0.publication?.merged = true } }
        case "closed": o.host.update { $0.existing?.state = "closed" }
        case "otherBranch": o.host.update { $0.existing?.sourceBranch = "feat/b" }
        case "fork": o.host.update { $0.existing?.forkHead = "project 7:feat/a" }
        case "paused": o.world.workspace.mutate { $0.updateRun(id: o.run.id) { $0.state = .paused; $0.intent = .paused } }
        case "ended": o.world.workspace.mutate { $0.updateRun(id: o.run.id) { $0.state = .stopped; $0.intent = .stopped } }
        case "takeover": o.world.workspace.mutate { $0.updateOperated(o.task.id) { $0.takenOver = true; $0.ownership += 1 } }
        default: o.host.update { $0.repository = "git.example.net/other/repo" }
        }
        let answer = await o.world.call(o.run.id, "retry_pipeline", ["task": "A"])
        #expect(answer.value == nil, "\(change): \(answer.value.map { "\($0)" } ?? "")")
        #expect(!o.host.log.contains("retry 69"), "\(change)")
        switch change {
        case "running": #expect(answer.message == "!69 has nothing to retry: its pipeline is running.")
        case "otherBranch": #expect(answer.message == "!69 isn’t A’s request on the host: it is from feat/b, not feat/a.")
        case "closed": #expect(answer.message == "!69 is closed: AiTerm retries only an open request’s pipeline.")
        default: break
        }
    }

    /// Read fresh right before the retry: a Pause, an End or a takeover while the host was read retries nothing.
    @Test(arguments: ["paused", "ended", "takeover"])
    func retryPipelineChecksTheBroadcastAgainRightBeforeItWrites(_ change: String) async throws {
        let o = try await failedPipeline()
        let gate = HeldGate()
        o.host.update { $0.beforeRetry = { await gate.wait() } }
        let call = Task { await o.world.call(o.run.id, "retry_pipeline", ["task": "A"]) }
        await gate.started()
        o.world.workspace.mutate { state in
            switch change {
            case "paused": state.updateRun(id: o.run.id) { $0.intent = .paused }
            case "ended": state.updateRun(id: o.run.id) { $0.state = .stopped; $0.intent = .stopped }
            default: state.updateOperated(o.task.id) { $0.takenOver = true; $0.ownership += 1 }
            }
        }
        await gate.release()
        #expect(await call.value.message != nil)
        #expect(!o.host.log.contains("retry 69"))
    }
}
