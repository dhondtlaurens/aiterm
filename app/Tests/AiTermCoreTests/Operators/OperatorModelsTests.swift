import Testing
import Foundation
@testable import AiTermCore

@Suite struct OperatorModelsTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    private let persona = OperatorPersona(
        name: "Senior engineer", handle: "senior", model: "claude-opus-5-5", effort: "high",
        secondOpinion: SecondOpinion(level: .healthyDoubt, agent: .codex, model: "gpt-6-astra", effort: "medium"),
        autonomy: .routine, alwaysAsk: ["database migrations"], persona: "You are careful.", lessons: ["Ask first."])

    /// The raw values are what `state.json` and the operator file spell: renaming a case would
    /// orphan every saved operation, so they are pinned.
    @Test func theSavedSpellingsArePinned() {
        #expect(Autonomy.allCases.map(\.rawValue) == ["askFirst", "routine", "trusted", "handsOff"])
        #expect(SecondOpinionLevel.allCases.map(\.rawValue) == ["noSelfDoubt", "healthyDoubt", "impostor"])
        #expect(TaskEnd.allCases.map(\.rawValue) == ["commit", "draftMR", "merge"])
        #expect(OperatedState.allCases.map(\.rawValue)
                == ["planned", "queued", "working", "blocked", "failed", "accepted", "noChange", "published", "stopped"])
        #expect(OperatedFlag.allCases.map(\.rawValue) == ["possiblyStalled", "uncertain", "upstreamReplaced", "waitingOnYou"])
        #expect(ChallengeStage.allCases.map(\.rawValue) == ["running", "ready", "delivered", "unchallenged", "acted"])
    }

    /// Spec §4.1: the plan gate is on at Ask first and Routine only.
    @Test func onlyAskFirstAndRoutineGateThePlan() {
        #expect(Autonomy.allCases.filter(\.gatesPlans) == [.askFirst, .routine])
    }

    @Test func openStatesAreTheOnesStopCanEnd() {
        #expect(OperatedState.allCases.filter(\.isOpen) == [.planned, .queued, .working, .blocked, .failed])
    }

    @Test func limitsDefaultToTwoRetriesAndNinetyMinutes() {
        #expect(OperatorLimits() == OperatorLimits(retries: 2, runtimeMinutes: 90))
        #expect(persona.limits == OperatorLimits())
        #expect(persona.id == "senior")
    }

    @Test func aRunRoundTripsWithEveryFieldSet() throws {
        let task = UUID()
        let run = OperatorRun(
            id: UUID(), name: "Sprint 42", persona: persona, projectIds: [UUID(), UUID()], brief: "Do the sprint",
            doneWhen: "a draft MR per ticket", state: .paused, intent: .paused, planRevision: 3, approvedRevision: 2,
            questions: [OperatorQuestion(id: "q1", text: "Which API?", task: task, askedAt: Date(timeIntervalSince1970: 10), resolution: "v2")],
            decisions: [OperatorDecision(key: "d1", text: "Split it", task: nil, at: Date(timeIntervalSince1970: 20), challenge: "Why?")],
            lessons: [ProposedLesson(key: "l1", lesson: "Ask about fields", because: "You corrected me", decided: .kept)],
            operatorConversation: "c-1", operatorWindowId: "w1", operatorSessionId: "s1",
            challenges: [ChallengeRecord(id: "ch-1", tool: "submit_plan", stage: .acted, critique: "Split A.",
                                         actedArguments: #"{"revision":3}"#, result: #"{"submitted":true}"#,
                                         askedAt: Date(timeIntervalSince1970: 25))],
            createdAt: Date(timeIntervalSince1970: 0))
        #expect(try roundTrip(run) == run)
        #expect(run.openRevision == 4)
    }

    /// A run saved before challenges were kept reads with none; one made without a scope has none.
    @Test func aRunSavedBeforeChallengesReadsWithNone() throws {
        let run = OperatorRun(id: UUID(), name: "Old", persona: persona, brief: "b", doneWhen: nil, createdAt: Date(timeIntervalSince1970: 0))
        #expect(run.projectIds.isEmpty && run.challenges.isEmpty)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any])
        object["challenges"] = nil
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(OperatorRun.self, from: JSONSerialization.data(withJSONObject: object)) == run)
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
            runId: UUID(), key: "PLUTO-231", state: .accepted, end: .merge, brief: "Add the gift card",
            dependsOn: [TaskDependency(task: parent, kind: .code)], stackedOn: parent, revision: 2, firstRevision: 1,
            acceptance: TaskAcceptance(resultSHA: "4f2a91c", prerequisiteSHAs: ["aa11"], checkOutput: "ok", note: "fine",
                                       at: Date(timeIntervalSince1970: 30)),
            publication: TaskPublication(pushedSHA: "4f2a91c", mergeRequestURL: "https://example.net/mr/1"),
            takenOver: true, ownership: 3, launch: LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSince1970: 40)),
            retriesUsed: 1, runtimeUsed: 600, blockedReason: "waiting", blockedFrom: .working, flags: [.uncertain, .possiblyStalled],
            lastFailure: "tests red")
        #expect(try roundTrip(task) == task)
        #expect(task.started)
    }

    /// `lastFailure` is new: a file without it loads as none, and none is not written.
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
