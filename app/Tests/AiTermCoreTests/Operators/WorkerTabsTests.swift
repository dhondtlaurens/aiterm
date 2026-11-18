import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct WorkerTabsTests {
    func tab(_ state: SessionState, _ work: [WorkItem]) -> WorkerTab {
        var session = SessionInfo.make("main", state: state)
        session.work = work
        return WorkerTab(key: nil, agent: .claude, model: "opus", session: session)
    }

    /// Only work that holds the turn keeps a worker at work; what the card shows beside it does not.
    @Test func onlyWorkThatHoldsTheTurnKeepsAWorkerAtWork() {
        let child = WorkItem(kind: .subagent, text: "Review the fix", holdsTurn: true)
        let working = tab(.working, [child])
        #expect(working.isStillAtWork && working.background == ["Review the fix"])
        let ended = tab(.done, [WorkItem(kind: .shell, text: "npm run dev", holdsTurn: true)])
        #expect(ended.isStillAtWork && ended.background == ["npm run dev"])
        let shown = tab(.done, [WorkItem(kind: .shell, text: "npm test", holdsTurn: false),
                                WorkItem(kind: .subagent, text: "explorer", holdsTurn: false)])
        #expect(!shown.isStillAtWork && shown.background.isEmpty)
    }

    @Test func aDisplayDescriptionDoesNotChangeOperatorWorkTextOrReadiness() {
        let raw = WorkItem(kind: .shell, text: "scripts/test.sh", holdsTurn: true)
        var described = raw
        described.displayLabel = "Run full validation"
        let before = tab(.done, [raw]), after = tab(.done, [described])
        #expect(after.background == before.background && after.background == ["scripts/test.sh"])
        #expect(after.isStillAtWork == before.isStillAtWork)
        described.holdsTurn = false
        #expect(!tab(.done, [described]).isStillAtWork)
    }
}
