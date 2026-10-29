import Testing
import Foundation
@testable import AiTermCore

/// Current configuration values, persisted review evidence and status payloads.
@Suite struct BroadcastSettingsTests {
    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    private func saved<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try #require(try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }



    static let verdict = ReviewVerdict(tab: "review-1", sha: "4f2a91c", passed: false, round: 2, rounds: 3, critical: 1, important: 2,
                                       minor: 4, summary: "One race in the cart.", at: at)
    static let record = FinishedTaskRecord(
        task: UUID(uuidString: "1EB4C0DE-0000-0000-0000-000000000001")!, key: "PLUTO-231", title: "Gift card", ticket: "PLUTO-231",
        project: UUID(uuidString: "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")!, agent: .codex, model: "gpt-6-astra", reasoning: "medium",
        end: .merge, state: .published, acceptedSHA: "4f2a91c", branch: "feat/gift-card", mergeRequestURL: "https://example.net/mr/1",
        mergedSHA: "9e8d7c6", result: "merged !1", branchDeleted: true, at: at)
    static let check = GoalCheck(round: 1, met: false, evidence: "Two of three pages ship.", missing: ["The FAQ page"],
                                 oracleAgreed: true, at: at)

    @Test func verdictKeyIsOptionalAndSurvivesRoundTrip() throws {
        var json = try saved(Self.verdict)
        json["key"] = "review-attempt-1"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let verdict = try decoder.decode(ReviewVerdict.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(try roundTrip(verdict).key == "review-attempt-1")
        #expect(try saved(roundTrip(verdict))["key"] as? String == "review-attempt-1")
        #expect(try saved(Self.verdict)["key"] == nil)
    }

    @Test func eachNewTypeRoundTripsWithEveryFieldSet() throws {
        let row = AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")
        #expect(try roundTrip(row) == row)
        let settings = TaskSettings(review: "An adversarial review with /code-review.", end: .merge, closeWhenDone: false,
                                    deleteMergedBranch: true)
        #expect(try roundTrip(settings) == settings)
        let goal = BroadcastGoal(text: "Every page ships.", extraRounds: 0)
        #expect(try roundTrip(goal) == goal)
        #expect(try roundTrip(Self.check) == Self.check)
        #expect(try roundTrip(Self.verdict) == Self.verdict)
        #expect(try roundTrip(Self.record) == Self.record)
    }

    /// The raw values are what `state.json` and `run_status` spell, so they are pinned.
    @Test func theSavedSpellingsArePinned() throws {
        #expect([GoalOutcome.met, .notMet, .unchecked].map(\.rawValue) == ["met", "notMet", "unchecked"])
        #expect([TabRole.work, .review].map(\.rawValue) == ["work", "review"])
        let row = try saved(AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high"))
        #expect(NSDictionary(dictionary: row).isEqual(to: ["agent": "claude", "model": "claude-opus-5-5", "reasoning": "high"]))
    }



    /// A row is its combination: the same agent, model and reasoning twice is one row.
    @Test func identicalRowsAreOne() {
        let rows = [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high"),
                    AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high"),
                    AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "low")]
        #expect(Set(rows).count == 2)
    }

    @Test func aRunWithEveryNewFieldSetRoundTrips() throws {
        var run = OperatorFixtures.run(agents: OperatorFixtures.agents, taskSettings: OperatorFixtures.taskSettings,
                                       goal: OperatorFixtures.goal)
        run.goalCheckDue = true
        run.roundsUsed = 1
        run.goalChecks = [Self.check]
        run.goalOutcome = .notMet
        run.revisionAtLastCheck = 2
        run.finished = [Self.record]
        run.closedAt = Self.at
        #expect(try roundTrip(run) == run)
        let written = try saved(run).keys
        for key in ["agents", "taskSettings", "goal", "goalCheckDue", "roundsUsed", "goalChecks", "goalOutcome",
                    "revisionAtLastCheck", "finished", "closedAt"] {
            #expect(written.contains(key), "\(key) is not written")
        }
    }




    @Test func aTasksVerdictsAreKeptAndLeftOutWhileThereAreNone() throws {
        var task = OperatorFixtures.operated("A", .working)
        #expect(!(try saved(task)).keys.contains("reviewVerdicts"))
        task.reviewVerdicts = [Self.verdict]
        #expect(try saved(task).keys.contains("reviewVerdicts"))
        #expect(try roundTrip(task) == task)
    }

    /// A tab saved before roles is a work tab, and a work tab saves as it did then.
    @Test func aTabIsAWorkTabUnlessSaidOtherwise() throws {
        let json = #"{"key":"tests","agent":"codex","model":"m","modelReason":"Tests.","brief":"Do it.","agentPinned":false,"launch":{"number":1,"requestedAt":0}}"#
        let tab = try JSONDecoder().decode(ExtraTab.self, from: Data(json.utf8))
        #expect(tab.role == .work)
        let earlier = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any]))
            .isEqual(to: earlier))
        var review = tab
        review.role = .review
        #expect(try roundTrip(review).role == .review)
    }

    /// `run_status` shows the rows under `agents.allowed`, the task settings, the goal and its rounds, each task's verdicts
    /// and the closed tasks' records; a legacy run's says none of them.
    @Test func runStatusShowsTheNewFieldsOnlyForABroadcastThatHasThem() throws {
        func status(_ run: OperatorRun, _ task: TaskItem) throws -> [String: Any] {
            let built = try #require(RunStatus.build(state: OperatorFixtures.state(run, [task]), run: run.id, revision: 1, live: [:],
                                                     runLive: RunLiveFacts(agents: [.claude: RunStatus.AgentChoice(models: ["claude-opus-5-5"], defaultModel: "claude-opus-5-5")])))
            return try #require(try JSONSerialization.jsonObject(with: built.json()) as? [String: Any])
        }
        let added = ["taskSettings", "goal", "goalCheckDue", "roundsUsed"]
        var run = OperatorFixtures.run(agents: OperatorFixtures.agents, taskSettings: OperatorFixtures.taskSettings, goal: OperatorFixtures.goal)
        run.goalCheckDue = true
        run.roundsUsed = 1
        run.finished = [Self.record]
        var task = OperatorFixtures.task("A", .working)
        task.operated?.reviewVerdicts = [Self.verdict]
        let current = try status(run, task)
        let currentRun = try #require(current["run"] as? [String: Any])
        for key in added { #expect(currentRun[key] != nil, "\(key) is not said") }
        let agents = try #require(currentRun["agents"] as? [String: Any])
        #expect(agents["claude"] != nil && (agents["allowed"] as? [[String: Any]])?.count == OperatorFixtures.agents.count)
        #expect((current["finished"] as? [[String: Any]])?.first?["key"] as? String == "PLUTO-231")
        #expect(((current["tasks"] as? [[String: Any]])?.first?["reviewVerdicts"] as? [[String: Any]])?.first?["sha"] as? String == "4f2a91c")
    }

    @Test func aQuestionKeepsWhatItIsAbout() throws {
        let question = OperatorQuestion(id: "rounds-A", text: "A is out of fix rounds.", task: UUID(), askedAt: Self.at, about: OperatorQuestion.fixRounds)
        #expect(try roundTrip(question).about == "fixRounds")
        #expect(!(try saved(OperatorQuestion(id: "q", text: "?", task: nil, askedAt: Self.at))).keys.contains("about"))
    }

    /// An Agents row as the brief and the tool refusals name it.
    @Test func anAgentsRowIsNamedAgentModelReasoning() {
        #expect(AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high").label == "Claude Code · claude-opus-5-5 · high")
        #expect(AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: nil).label == "Codex · gpt-6-astra")
    }
}
