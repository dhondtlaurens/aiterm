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
}
