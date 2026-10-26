import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Every call the Operator makes is a line of its run folder's `activity.jsonl`, whatever the answer was.
@MainActor @Suite(.blocking) struct OperatorActivityTests {
    let project = OperatorServiceFixtures.project()

    /// The lines written so far, once every recording started has landed.
    func entries(_ world: OperatorWorld, _ run: UUID) async -> [ActivityEntry] {
        await world.controller.tools.lastRecording?.value
        return ActivityLog.read(runFolder: OperatorCommand.runFolder(run, home: world.ports.home)).entries
    }

    @Test func everyCallIsRecorded() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        _ = await world.call(run.id, "run_status")
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Went with nl-BE.", "why": "The client is Flemish."])
        let recorded = await entries(world, run.id)
        #expect(recorded.map(\.tool) == ["run_status", "ask_you", "log_decision"])
        #expect(recorded.map(\.outcome) == [.ok, .ok, .ok])
        #expect(recorded.map(\.isRead) == [true, false, false])
        #expect(recorded[1].line == "Asked you: Which locale is the default?")
        #expect(recorded[1].arguments["key"] == "locale" && recorded[1].result.contains("\"question\":\"locale\""))
        #expect(recorded[2].reason == "The client is Flemish." && recorded[0].reason == nil)
        #expect(recorded.allSatisfy { abs($0.at.timeIntervalSinceNow) < 60 })
    }

    @Test func questionActivityUsesTheRecordedOutcomeOnRetries() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        _ = await world.call(run.id, "ask_you", ["key": "a", "question": "Locale?"])
        _ = await world.call(run.id, "resolve_question", ["key": "a", "summary": "Moved to a worker.", "withdrawn": true])
        _ = await world.call(run.id, "resolve_question", ["key": "a", "summary": "Yes."])
        _ = await world.call(run.id, "ask_you", ["key": "b", "question": "Locale?"])
        _ = await world.call(run.id, "resolve_question", ["key": "b", "summary": "nl-BE"])
        _ = await world.call(run.id, "resolve_question", ["key": "b", "summary": "Moot.", "withdrawn": true])
        let lines = await entries(world, run.id).filter { $0.tool == "resolve_question" }
        #expect(lines.map(\.line) == ["Withdrew question: Moved to a worker.", "Withdrew question: Moved to a worker.",
                                      "Noted your answer: nl-BE", "Noted your answer: nl-BE"])
        #expect(lines.first?.result.contains("\"withdrawn\":true") == true)
    }

    @Test func callsKeepTheOrderTheyEndedInHoweverManyAreRecordedAtOnce() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        for index in 0..<25 { _ = await world.call(run.id, "log_decision", ["key": .string("d\(index)"), "text": .string("Decision \(index).")]) }
        #expect(await entries(world, run.id).map { $0.arguments["key"] } == (0..<25).map { JSONValue.string("d\($0)") })
    }

    @Test func aRefusalIsRecordedWithItsReason() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        let answer = await world.call(run.id, "resolve_question", ["key": "nope", "summary": "Nothing."])
        let recorded = try #require(await entries(world, run.id).first)
        #expect(recorded.outcome == .refused && recorded.reason == "No question nope in this broadcast.")
        #expect(recorded.line == "note your answer: Nothing.", "what was asked, not that it happened")
        #expect(recorded.result == answer.message)
        // The recording changed nothing of the answer.
        #expect(answer.message == "No question nope in this broadcast.")
    }

    @Test func anUnknownToolIsRecordedAsRefused() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        _ = await world.call(run.id, "propose_lesson", ["key": "l1"])
        let recorded = await entries(world, run.id)
        #expect(recorded.count == 1 && recorded.first?.line == "propose_lesson" && recorded.first?.outcome == .refused)
    }

    @Test func aStoppedRunsRefusalIsRecordedAndAnUnknownRunsIsNot() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        #expect(await world.call(run.id, "run_status").message == "This broadcast has ended; its tools no longer act.")
        let recorded = await entries(world, run.id)
        #expect(recorded.count == 1 && recorded.first?.outcome == .refused && recorded.first?.reason == "This broadcast has ended; its tools no longer act.")
        let stranger = UUID()
        #expect(await world.call(stranger, "run_status").message == "This broadcast is no longer in AiTerm.")
        #expect(await entries(world, stranger).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: OperatorCommand.runFolder(stranger, home: world.ports.home).path))
    }

    @Test func aRepeatedMessageIsMarkedRepeated() async throws {
        let repo = try GitFixture.makeRepo(prefix: "op-activity-")
        let project = OperatorServiceFixtures.project(path: repo)
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        task = try TaskCreator.checkOutWorker(task, project: project, start: "main", git: GitRunner.hermetic()).task
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date())
        task.operated?.ownership = 3
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        let message: JSONValue = ["task": "PLUTO-1", "text": "Use nl-BE."]
        _ = await world.call(run.id, "message_task", message)
        _ = await world.call(run.id, "message_task", message)
        let recorded = await entries(world, run.id)
        #expect(recorded.map(\.outcome) == [.ok, .repeated])
        #expect(recorded.map(\.task) == [task.id, task.id] && recorded.map(\.taskLabel) == ["PLUTO-1", "PLUTO-1"])
        #expect(recorded.first?.line == "Told Task PLUTO-1’s worker: Use nl-BE.")
    }

    @Test func aChallengedCallIsChallengedAndTheCallThatActsIsNot() async throws {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude), projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            ports.secondOpinion = .answering("A is two tasks.")
            ports.challengeReplyBudget = .seconds(60)
        }
        _ = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "Do A.", "project": "Shop", "agent": "claude",
                                                      "model": "claude-opus-5-5", "modelReason": "The default.", "end": "commit"])
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        let id = try #require(first.value?["challengeId"]?.stringValue)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "A is one change."])
        // Asked again after it acted: the same answer, not a second challenge.
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "A is one change."])
        let plans = await entries(world, run.id).filter { $0.tool == "submit_plan" }
        #expect(plans.map(\.outcome) == [.challenged, .ok, .repeated])
        #expect(plans[0].reason == "A is two tasks.")
        #expect(plans[0].line == "submit the plan", "what was asked, not that it happened")
        #expect(plans[1].line == "Submitted the plan · kept despite the Oracle")
    }

    @Test func theTaskIsNamedByItsJiraKeyElseItsOperatedKey() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        var ticketed = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1")
        ticketed.jira = JiraRef(key: "SHOP-12", summary: "Login", url: "https://acme.atlassian.net/browse/SHOP-12")
        let plain = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2")
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [ticketed, plain]))
        _ = await world.call(run.id, "resume_task", ["task": "PLUTO-1"])
        _ = await world.call(run.id, "resume_task", ["task": "PLUTO-2"])
        let recorded = await entries(world, run.id)
        #expect(recorded.map(\.taskLabel) == ["SHOP-12", "PLUTO-2"] && recorded.map(\.task) == [ticketed.id, plain.id])
        // Neither task is blocked, so both resumes are refused: the line says what was asked.
        #expect(recorded.first?.outcome == .refused && recorded.first?.line == "put Task PLUTO-1 back to work")
    }

    @Test func aWriteThatFailsNeverChangesTheAnswer() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        // The run folder's place is a file, so nothing can be written under it.
        let folder = OperatorCommand.runFolder(run.id, home: world.ports.home)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: folder)
        #expect(await world.call(run.id, "ask_you", ["key": "q", "question": "Why?"]).value?["open"] == true)
        #expect(await entries(world, run.id).isEmpty)
    }

    @Test func onActivityFiresOncePerAppendAfterItLanded() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        var told: [Int] = []
        world.controller.tools.onActivity = { [folder = OperatorCommand.runFolder(run.id, home: world.ports.home)] _ in
            told.append(ActivityLog.read(runFolder: folder).entries.count)
        }
        #expect(world.controller.activityGeneration(of: run.id) == 0)
        _ = await world.call(run.id, "run_status")
        _ = await world.call(run.id, "run_status")
        await world.controller.tools.lastRecording?.value
        #expect(told == [1, 2])
    }

    @Test func theControllersGenerationCountsEachRunsAppends() async throws {
        let run = OperatorServiceFixtures.run(projects: [project]), other = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run, other]))
        _ = await world.call(run.id, "run_status")
        _ = await world.call(run.id, "run_status")
        _ = await world.call(other.id, "run_status")
        await world.controller.tools.lastRecording?.value
        #expect(world.controller.activityGeneration(of: run.id) == 2 && world.controller.activityGeneration(of: other.id) == 1)
    }
}
