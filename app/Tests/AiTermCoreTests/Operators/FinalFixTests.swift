import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct FinalFixTests {
    @Test func acceptedPublicationStillNeedsItsEnd() {
        var run = OperatorFixtures.run()
        run.firstPlanSize = 1
        var task = OperatorFixtures.task("PAY-1", .accepted, run: run.id)
        task.operated?.end = .merge
        task.operated?.acceptance = TaskAcceptance(resultSHA: "4f2a91c", prerequisiteSHAs: [], checkOutput: "passed", note: nil, at: OperatorFixtures.epoch)
        let state = OperatorFixtures.state(run, [task])
        #expect(BroadcastBoard.progress(of: run, tasks: [task]) == "0 of 1 done")
        #expect(OperatorLine.ending(of: task.operated!) == nil)
        let board = BroadcastBoard.make(run: run, state: state, acting: OperatorActs(), requests: [])
        #expect(board.columns.first { $0.column == .inProgress }?.cards.count == 1)
    }

    @Test func finishedPromptDoesNotNotifyOrHoldTheBroadcast() {
        var run = OperatorFixtures.run()
        var task = OperatorFixtures.task("PAY-1", .accepted, run: run.id)
        task.operated?.end = .commit
        run.questions = [OperatorQuestion(id: "prompt-old", text: "Permission?", task: task.id, askedAt: OperatorFixtures.epoch)]
        let state = OperatorFixtures.state(run, [task])
        #expect(OperatorRequests.open(run: run, state: state, prompts: [task.id: "run tests"]).isEmpty)
        #expect(RunScheduler.isComplete(run, in: state))
    }

    @Test func publicationProblemNeedsYou() {
        let run = OperatorFixtures.run()
        var task = OperatorFixtures.task("PAY-1", .accepted, run: run.id)
        task.operated?.end = .merge
        task.operated?.publication = TaskPublication(problem: "CI failed.")
        let state = OperatorFixtures.state(run, [task])
        let requests = OperatorRequests.open(run: run, state: state, prompts: [:])
        #expect(requests.first?.text == "\(task.title): CI failed.")
        #expect(OperatorLine.task(task, run: run, acting: nil, requests: requests)?.look == .needsYou)
    }

    @Test func claudeWorkerHasExplicitPublicationGuards() {
        for denial in ["Bash(gh pr create:*)", "Bash(glab mr create:*)", "Bash(gh pr ready:*)", "Bash(glab mr update:*)", "Bash(git -C * push:*)", "Bash(git * push:*)"] {
            #expect(AgentCommand.operatedClaudeDenials.contains(denial))
        }
    }
}

extension FinalFixTests {
    @Test func leftForYouReachesTheEndAndSurvivesCoding() throws {
        let run = OperatorFixtures.run()
        var task = OperatorFixtures.task("PAY-1", .accepted, run: run.id, end: .draftMR)
        task.operated?.acceptance = OperatorFixtures.acceptance()
        task.operated?.publication = TaskPublication(leftForYou: true)
        let decoded = try JSONDecoder().decode(TaskPublication.self, from: JSONEncoder().encode(task.operated!.publication!))
        #expect(decoded.leftForYou)
        let board = BroadcastBoard.make(run: run, state: OperatorFixtures.state(run, [task]), acting: .none, requests: [])
        #expect(board.columns.first { $0.column == .done }?.cards.count == 1)
        #expect(RunScheduler.isComplete(run, in: OperatorFixtures.state(run, [task])))
        #expect(OperatorLine.ending(of: task.operated!) == "left for you · 4f2a91c")
    }

    @Test func firstRunOracleNeedsCodexButSavedPreferenceWins() {
        let defaults = ScratchDefaults.make()
        let first = OperatorProfileStore.load(defaults, claudeDefault: ("opus", nil), installed: [.claude])
        #expect(!first.oracle.isOn)
        var chosen = first
        chosen.oracle.isOn = true
        OperatorProfileStore.save(chosen, defaults)
        #expect(OperatorProfileStore.load(defaults, claudeDefault: ("opus", nil), installed: [.claude]).oracle.isOn)
    }

    @Test func briefNamesJiraAndRecordOnlyBoundaryAndResumeIncludesWhy() {
        var run = OperatorFixtures.run()
        run.jiraProjectKeys = ["PAY", "SHOP"]
        run.decisions = [OperatorDecision(key: "d", text: "Kept the endpoint.", task: nil, at: OperatorFixtures.epoch, why: "Clients still use it.")]
        let brief = OperatorCommand.brief(run: run, projects: [])
        #expect(brief.contains("Jira projects: PAY, SHOP"))
        #expect(brief.contains("leave_for_you(key, text)"))
        #expect(OperatorCommand.freshStartMessage(for: run, status: "{}").contains("Kept the endpoint. Why: Clients still use it."))
    }
}

extension FinalFixTests {
    @Test func acceptedUnpublishedTaskCanBeStopped() throws {
        let task = OperatorFixtures.operated("PAY-1", .accepted, end: .merge)
        let stopped = try OperatedTransitions.apply(.stop, to: task, by: .you, context: OperatedContext(runState: .active, retryLimit: 1))
        #expect(stopped.state == .stopped)
    }

    @Test func waitingPublicationUsesTheHostsQuietReason() {
        let run = OperatorFixtures.run()
        var task = OperatorFixtures.task("PAY-1", .accepted, run: run.id, end: .merge)
        task.operated?.publication = TaskPublication(waitingSince: OperatorFixtures.epoch, waitingReason: "CI is running")
        let line = OperatorLine.task(task, run: run, acting: nil, requests: [])
        #expect(line?.text == "waiting to merge · CI is running")
        #expect(line?.look == .quiet)
    }
}
