import Foundation
import Testing
@testable import AiTermCore

/// What the Operator's records mean, read from what they store and never saved: a question's kind, which tab a field
/// names, what became of a merge, what a challenge record is and what you asked of a run.
@Suite struct OperatorComputedViewsTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aQuestionsKindIsItsKeyAndWhatItIsAbout() {
        func question(_ id: String, about: String? = nil) -> OperatorQuestion {
            OperatorQuestion(id: id, text: "?", task: UUID(), askedAt: at, about: about)
        }
        #expect(question("prompt-\(UUID().uuidString)-1").kind == .prompt)
        #expect(question("merged-on-host-\(UUID().uuidString)").kind == .mergedOnHost)
        #expect(question("gate-3").kind == .gate)
        #expect(question("rounds", about: OperatorQuestion.fixRounds).kind == .fixRounds)
        #expect(question("which-api").kind == .asked)
        #expect([question("prompt-1"), question("gate-1")].allSatisfy { $0.channel == .there })
        #expect([question("merged-on-host-1"), question("rounds", about: OperatorQuestion.fixRounds), question("q")].allSatisfy { $0.channel == .here })
        let aiterms = [question("prompt-1"), question("merged-on-host-1"), question("gate-1")].map(\.isAiTerms)
        let others = [question("rounds", about: OperatorQuestion.fixRounds), question("q")].map(\.isAiTerms)
        #expect(aiterms == [true, true, true] && others == [false, false])
    }

    /// A tab reference reads each field's own encoding: nil and `main` are the first worker, anything else an extra tab's
    /// key, and it says itself back in either.
    @Test func aTabReferenceReadsNilAndMainAsTheFirstWorker() {
        #expect(TabReference(nil) == .first && TabReference(WorkerTab.firstKey) == .first)
        #expect(TabReference("tests") == .extra("tests"))
        #expect(TabReference.first.name == "main" && TabReference.first.key == nil)
        #expect(TabReference.extra("tests").name == "tests" && TabReference.extra("tests").key == "tests")
        #expect(WorkerTab(key: nil, agent: .claude, model: "m", session: nil).reference == .first)
        #expect(WorkerTab(key: "review", agent: .claude, model: "m", session: nil).reference == .extra("review"))
    }

    @Test func aMergeOutcomeIsMergedOrMergedWithAnotherHead() {
        #expect(TaskPublication().mergeOutcome == .notMerged && !TaskPublication().wasMerged)
        #expect(TaskPublication(merged: true, mergedSHA: "4f2a91c").mergeOutcome == .merged)
        #expect(TaskPublication(merged: true, landedSHA: "4f2a91c").mergeOutcome == .merged, "found already in its target")
        #expect(TaskPublication(mergedSHA: "9b3e07d").mergeOutcome == .mergedWithAnotherHead)
        #expect(TaskPublication(mergedSHA: "9b3e07d").wasMerged && TaskPublication(merged: true).wasMerged)
    }

    /// A relay's records are its rounds, a round saved before rounds were numbered the first; the rest are a critique or
    /// a veto, by their kind.
    @Test func aChallengeRecordsRoleIsItsKindOrItsRelayRound() {
        let relay = OperatorTool.relayQuestion.rawValue
        #expect(ChallengeRecord(id: "c", tool: "mark_task", askedAt: at).role == .critique)
        #expect(ChallengeRecord(id: "v", tool: "finish_task", kind: .veto, askedAt: at).role == .veto)
        #expect(ChallengeRecord(id: "r2", tool: relay, askedAt: at, round: 2).role == .relayRound(2))
        #expect(ChallengeRecord(id: "r", tool: relay, askedAt: at).relayRound == 1)
        #expect(ChallengeRecord(id: "c", tool: "mark_task", askedAt: at).relayRound == nil)
    }

    @Test func whatYouAskedOfARunIsItsIntent() {
        var run = OperatorRun(id: UUID(), name: "B", profile: OperatorProfile(model: "claude-opus-5-5", reasoning: nil), prompt: "Do it.", createdAt: at)
        #expect(run.youAsked == nil)
        run.intent = .paused
        #expect(run.youAsked == .pause && run.isPausedByYou && !run.hasEnded)
        run.intent = .stopped
        #expect(run.youAsked == .stop && run.hasEnded)
    }
}
