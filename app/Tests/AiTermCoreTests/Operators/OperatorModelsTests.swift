import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct OperatorModelsTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    /// A run as `state.json` saves it: a JSON object, its dates as `StateStore` writes them.
    private func saved(_ run: OperatorRun) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try #require(try JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any])
    }

    private func keys(_ run: OperatorRun) throws -> Dictionary<String, Any>.Keys { try saved(run).keys }

    private let profile = OperatorProfile(
        model: "claude-opus-5-5", reasoning: "high", slices: Slices(jira: true, review: false, merge: true),
        oracle: OracleSetting(isOn: true, agent: .codex, model: "gpt-6-astra", reasoning: "medium"),
        instructions: "Keep changes small.")

    @Test func oldOracleRefusalsBecomeSeparateNotes() throws {
        let reason = "The Oracle judged that the conditions to merge don’t hold yet: review missing."
        let data = try JSONEncoder().encode(["problem": reason])
        let publication = try JSONDecoder().decode(TaskPublication.self, from: data)
        #expect(publication.problem == nil && publication.mergeRefusal == reason)
        #expect(try roundTrip(publication).mergeRefusal == reason)
        let failure = try JSONDecoder().decode(TaskPublication.self, from: Data(#"{"problem":"Pipeline failed"}"#.utf8))
        #expect(failure.problem == "Pipeline failed" && failure.mergeRefusal == nil)
    }

    /// The raw values are what `state.json` spells: renaming a case would orphan every saved
    /// broadcast, so they are pinned.
    @Test func theSavedSpellingsArePinned() {
        #expect(OperatedState.allCases.map(\.rawValue)
                == ["planned", "queued", "working", "inReview", "blocked", "failed", "accepted", "noChange", "published", "stopped"])
        #expect(OperatedFlag.allCases.map(\.rawValue) == ["possiblyStalled", "uncertain", "upstreamReplaced", "waitingOnYou"])
        #expect(ChallengeStage.allCases.map(\.rawValue) == ["running", "ready", "delivered", "unchallenged", "acted"])
    }

    @Test func taskEndsSpellTheirRawValues() {
        #expect(TaskEnd.allCases.map(\.rawValue) == ["commit", "draftMR", "merge", "mergeLocal"])
    }

    @Test func inReviewIsOpen() {
        #expect(OperatedState.inReview.isOpen)
        #expect(OperatedState.allCases.filter(\.isOpen) == [.planned, .queued, .working, .inReview, .blocked, .failed])
    }

    /// The round-1 limits, fixed now: two retries and ninety minutes a task.
    @Test func theLimitsAreTwoRetriesAndNinetyMinutes() {
        #expect(OperatorTiming.retries == 2)
        #expect(OperatorTiming.runtimeMinutes == 90)
    }

    /// A broadcast keeps the profile it started with: Settings › Operator changed since changes the next one.
    @Test func theRunFreezesItsProfile() throws {
        let defaults = ScratchDefaults.make()
        let started = OperatorProfileStore.load(defaults, claudeDefault: (model: "claude-opus-5-5", reasoning: "high"))
        let run = OperatorRun(id: UUID(), name: "Sprint 42", profile: started, prompt: "Do the sprint", createdAt: Date(timeIntervalSince1970: 0))

        var changed = started
        changed.slices = Slices(jira: true, review: true, merge: true)
        changed.oracle.isOn = false
        try OperatorProfileStore.save(changed, defaults)

        #expect(OperatorProfileStore.load(defaults, claudeDefault: (model: "other", reasoning: nil)).slices == changed.slices)
        #expect(run.profile.slices == .none)
        #expect(run.profile.oracle == .standard)
    }

    @Test func aRunRoundTrips() throws {
        let task = UUID()
        let run = OperatorRun(
            id: UUID(), name: "Sprint 42", profile: profile, projectIds: [UUID(), UUID()], jiraProjectKeys: ["PLUTO", "SHOP"],
            prompt: "Do the sprint", review: "Jan approves each MR", done: "merged when green",
            state: .paused, intent: .paused, planRevision: 3, firstPlanSize: 5,
            questions: [OperatorQuestion(id: "q1", text: "Which API?", task: task, askedAt: Date(timeIntervalSince1970: 10), resolution: "v2")],
            decisions: [OperatorDecision(key: "d1", text: "Split it", task: nil, at: Date(timeIntervalSince1970: 20), challenge: "Why?",
                                         why: "Two changes.", objection: "One MR reads better.")],
            finds: [OffBriefFind(key: "f1", title: "A token in the logs", why: "It leaks a secret.", ticket: "PLUTO-240")],
            leftForYou: ["Marking !412 ready is yours."],
            operatorConversation: "c-1", operatorWindowId: "w1", operatorSessionId: "s1",
            challenges: [ChallengeRecord(id: "ch-1", tool: "submit_plan", stage: .acted, critique: "Split A.",
                                         actedArguments: #"{"revision":3}"#, result: #"{"submitted":true}"#,
                                         askedAt: Date(timeIntervalSince1970: 25))],
            jiraCreated: ["t1": "PLUTO-241"],
            createdAt: Date(timeIntervalSince1970: 0))
        #expect(try roundTrip(run) == run)
        #expect(run.openRevision == 4)

        let written = try keys(run)
        for key in ["profile", "jiraProjectKeys", "prompt", "review", "done", "firstPlanSize", "finds", "leftForYou", "jiraCreated"] {
            #expect(written.contains(key), "\(key) is not written")
        }
        for key in ["persona", "brief", "doneWhen", "lessons"] { #expect(!written.contains(key), "\(key) is still written") }
    }

    /// A decision saved before decisions said why has none.
    @Test func aDecisionSavedWithoutAWhyHasNone() throws {
        let json = #"{"key":"d1","text":"Split it","at":"1970-01-01T00:00:20Z"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decision = try decoder.decode(OperatorDecision.self, from: Data(json.utf8))
        #expect(decision.why == nil && decision.objection == nil && decision.reason == nil)
    }

    /// A run made without a scope, a review or a done has none; its lists are empty.
    @Test func aRunMadeWithTheLeastHasNone() throws {
        let run = OperatorRun(id: UUID(), name: "Old", profile: profile, prompt: "b", createdAt: Date(timeIntervalSince1970: 0))
        #expect(run.projectIds.isEmpty && run.jiraProjectKeys.isEmpty && run.challenges.isEmpty && run.finds.isEmpty && run.leftForYou.isEmpty
                && run.jiraCreated.isEmpty)
        #expect(run.review == nil && run.done == nil && run.firstPlanSize == nil)
        #expect(try roundTrip(run) == run)
    }

    /// What `jira_sprint` did is kept by its key, and a run that did none saves as it did before.
    @Test func whatJiraSprintDidIsKeptByItsKeyAndLeftOutWhileEmpty() throws {
        var run = OperatorRun(id: UUID(), name: "Sprint", profile: profile, prompt: "b", createdAt: Date(timeIntervalSince1970: 0))
        #expect(!(try keys(run)).contains("jiraSprinted"))
        run.jiraSprinted = ["s1": "41", "s2": "backlog"]
        #expect(try keys(run).contains("jiraSprinted"))
        #expect(try roundTrip(run) == run)
    }

    /// The comments `jira_comment` posted are kept by their key, and a run that posted none saves as it did before.
    @Test func whatJiraCommentPostedIsKeptByItsKeyAndLeftOutWhileEmpty() throws {
        var run = OperatorRun(id: UUID(), name: "Comment", profile: profile, prompt: "b", createdAt: Date(timeIntervalSince1970: 0))
        #expect(!(try keys(run)).contains("jiraCommented"))
        run.jiraCommented = ["c1": "10042"]
        #expect(try keys(run).contains("jiraCommented"))
        #expect(try roundTrip(run) == run)
    }

    /// What `leave_for_you` recorded is kept by its key, and a run that recorded none saves as it did before.
    @Test func whatLeaveForYouRecordedIsKeptByItsKeyAndLeftOutWhileEmpty() throws {
        var run = OperatorRun(id: UUID(), name: "Left", profile: profile, prompt: "b", createdAt: Date(timeIntervalSince1970: 0))
        #expect(run.leftForYouRecords.isEmpty)
        #expect(!(try keys(run)).contains("leftForYouRecords"))
        run.leftForYouRecords = ["l1": "Marking !412 ready is yours."]
        #expect(try keys(run).contains("leftForYouRecords"))
        #expect(try roundTrip(run) == run)
    }

    /// A run as b29ffc4 saved it, word for word: `leftForYouRecords` and `jiraCreated` filled, no `jiraSprinted` or
    /// `jiraCommented`, and a key this build does not know. It loads and saves back the same.
    @Test func aRunSavedByAnEarlierBuildSavesBackTheSame() throws {
        let json = #"""
        {"id":"0F3A1C2B-0000-4000-8000-0000000000B2","name":"Sprint 42",
         "profile":{"model":"claude-opus-5-5","reasoning":"high","slices":{"jira":true,"review":false,"merge":true},
                    "oracle":{"isOn":true,"agent":"codex","model":"gpt-6-astra","reasoning":"medium"},
                    "instructions":"Keep changes small."},
         "projectIds":[],"jiraProjectKeys":["PLUTO"],"prompt":"Do the sprint","state":"active","planRevision":2,
         "questions":[],"decisions":[],"finds":[],"snags":[],"leftForYou":["Marking !412 ready is yours."],
         "leftForYouRecords":{"l1":"Marking !412 ready is yours."},"challenges":[],
         "jiraCreated":{"t1":"PLUTO-241"},"threadReplies":{},"pendingWrites":[],
         "createdAt":"1970-01-01T00:00:00Z","milestone":3}
        """#
        let data = Data(json.utf8)
        let earlier = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(OperatorRun.self, from: data)
        #expect(loaded.leftForYouRecords == ["l1": "Marking !412 ready is yours."] && loaded.jiraCreated == ["t1": "PLUTO-241"])
        #expect(NSDictionary(dictionary: try saved(loaded)).isEqual(to: earlier))
    }

    /// A launch saved before AiTerm recorded its window reads as one still opening.
    @Test func aLaunchSavedBeforeItsWindowWasRecordedReadsAsStillOpening() throws {
        let read = try JSONDecoder().decode(LaunchAttempt.self, from: Data(#"{"number":2,"requestedAt":40}"#.utf8))
        #expect(read == LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSinceReferenceDate: 40)))
        #expect(read.openedAt == nil)
        let opened = LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSince1970: 40), openedAt: Date(timeIntervalSince1970: 45))
        #expect(try roundTrip(opened) == opened)
    }

    @Test func anOperatedTaskRoundTripsWithEveryFieldSet() throws {
        let parent = UUID()
        let task = OperatedTask(
            runId: UUID(), key: "PLUTO-231", state: .accepted, end: .mergeLocal, brief: "Add the gift card",
            dependsOn: [TaskDependency(task: parent, kind: .code)], stackedOn: parent, revision: 2, firstRevision: 1,
            acceptance: TaskAcceptance(resultSHA: "4f2a91c", prerequisiteSHAs: ["aa11"], checkOutput: "ok", note: "fine",
                                       at: Date(timeIntervalSince1970: 30)),
            publication: TaskPublication(pushedSHA: "4f2a91c", mergeRequestURL: "https://example.net/mr/1"),
            takenOver: true, ownership: 3, launch: LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSince1970: 40)),
            retriesUsed: 1, runtimeUsed: 600, blockedReason: "waiting", blockedFrom: .working, flags: [.uncertain, .possiblyStalled],
            lastFailure: "tests red", modelReason: "A schema change: the strongest model.", agentPinned: true, problem: "issue-7",
            branchDrift: BranchDrift(source: .head, branch: "fix/mine", sha: "b0b0b0b", found: "Its worktree is on branch fix/mine."))
        #expect(try roundTrip(task) == task)
        #expect(task.started)
    }

    /// A task made without the new fields has no model reason, no pin and no problem.
    @Test func theNewTaskFieldsDefaultToNone() throws {
        let json = """
        {"runId":"1EB4C0DE-0000-0000-0000-000000000001","key":"K","state":"queued","end":"commit","brief":"b","revision":1}
        """
        let task = try JSONDecoder().decode(OperatedTask.self, from: Data(json.utf8))
        #expect(task.modelReason == nil && !task.agentPinned && task.problem == nil && task.branchDrift == nil)
    }

    /// `lastFailure` is read when present, and none is not written.
    @Test func lastFailureIsReadWhenPresentAndWrittenOnlyWhenPresent() throws {
        let json = """
        {"runId":"1EB4C0DE-0000-0000-0000-000000000001","key":"K","state":"queued","end":"commit","brief":"b","revision":1}
        """
        var task = try JSONDecoder().decode(OperatedTask.self, from: Data(json.utf8))
        #expect(task.lastFailure == nil)
        #expect(!String(decoding: try JSONEncoder().encode(task), as: UTF8.self).contains("lastFailure"))
        task.lastFailure = "tests red"
        #expect(String(decoding: try JSONEncoder().encode(task), as: UTF8.self).contains(#""lastFailure":"tests red""#))
    }

    /// A flag is advisory: one a newer build wrote is dropped, the task still reads. Flags are
    /// written sorted, so a resave of the same task writes the same bytes.
    @Test func anUnknownFlagIsDroppedAndFlagsAreWrittenSorted() throws {
        let json = """
        {"runId":"1EB4C0DE-0000-0000-0000-000000000001","key":"K","state":"queued","end":"commit","brief":"b",
         "revision":1,"flags":["sparkly","uncertain"]}
        """
        let task = try JSONDecoder().decode(OperatedTask.self, from: Data(json.utf8))
        #expect(task.flags == [.uncertain])
        #expect(task.firstRevision == 1, "a task saved without one was added in its own revision")
        #expect(task.dependsOn.isEmpty && !task.takenOver && task.ownership == 0 && task.retriesUsed == 0 && !task.started)
        var both = task
        both.flags = [.waitingOnYou, .possiblyStalled]
        let written = String(decoding: try JSONEncoder().encode(both), as: UTF8.self)
        #expect(written.contains(#""flags":["possiblyStalled","waitingOnYou"]"#))
    }
}
