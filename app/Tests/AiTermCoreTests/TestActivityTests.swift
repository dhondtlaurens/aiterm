import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct TestActivityTests {
    @Test func queuedAndRunningTestsAreDistinctAndExposeTheirHolder() {
        let queued = TestActivity(runId: "own", suite: "swift", state: .queued, queuePosition: 2,
                                  holder: "all in /repo/another-worktree")
        #expect(queued.isActive && queued.line == "tests queued · #2")
        #expect(queued.statusLine.tooltip.contains("all in /repo/another-worktree"))
        let running = TestActivity(runId: "own", suite: "swift", state: .running)
        #expect(running.isActive && running.line == "running tests · swift")
        for activity in [TestActivity(runId: "own", suite: "swift", state: .completed, exitCode: 0),
                         TestActivity(runId: "own", suite: "swift", state: .completed, exitCode: 9),
                         TestActivity(runId: "own", suite: "swift", state: .interrupted)] {
            #expect(!activity.isActive)
            #expect(activity.statusLine.look == .ended)
        }
    }

    @Test func ownLiveTestsKeepAnEndedWorkerBusyUntilItsOwnExit() throws {
        let run = OperatorUIFixtures.run(), project = OperatorUIFixtures.project("web")
        let task = OperatorUIFixtures.task("Own tests", project: project.id,
            operated: OperatorUIFixtures.operated(run: run.id, key: "own", state: .working))
        var session = OperatorUIFixtures.tab("main", of: task, .done)
        session.testActivity = TestActivity(runId: "own", suite: "daemon", state: .queued, queuePosition: 1)
        #expect(SidebarModel.aggregate(tabs: [session]) == .background)
        #expect(!task.isReadyForAcceptance(in: [session]))
        #expect(OperatorLine.task(task, run: run, acting: nil, requests: [], sessions: [session])?.text == "tests queued · #1")
        session.testActivity = TestActivity(runId: "own", suite: "daemon", state: .completed, exitCode: 0)
        #expect(SidebarModel.aggregate(tabs: [session]) == .done)
        #expect(task.isReadyForAcceptance(in: [session]))
        session.state = .working
        #expect(SidebarModel.aggregate(tabs: [session]) == .working)
        #expect(SidebarModel.backgroundJobs(of: [session]).isEmpty)
    }

    /// The row's third line is the Operator's alone (29 Oct 2026): a task of your own running its tests draws no line,
    /// only background work, on its mark and its card; a driven one's line still says it.
    @Test func ownTestsDrawNoLineOnATaskOfYourOwn() throws {
        let project = OperatorUIFixtures.project("web")
        let task = OperatorUIFixtures.task("Mine", project: project.id, operated: nil)
        var state = AppState()
        state.append(project: project)
        state.tasks = [task]
        var session = OperatorUIFixtures.tab("main", of: task, .done)
        session.testActivity = TestActivity(runId: "own", suite: "swift", state: .running)
        let row = try #require(SidebarModel.sections(state: state, sessions: [session], branchByCwd: [:], projectBranch: [:])
            .first?.tasks.first)
        #expect(row.operatorLine == nil, "no line of the Operator's")
        #expect(row.status == .background, "the run shows as background work")
        session.testActivity = TestActivity(runId: "own", suite: "swift", state: .completed, exitCode: 0)
        let ended = try #require(SidebarModel.sections(state: state, sessions: [session], branchByCwd: [:], projectBranch: [:])
            .first?.tasks.first)
        #expect(ended.operatorLine == nil && ended.status == .done, "nor a result once it ends")
    }

    @Test func activityRoundTripsWithExitAndUnknownStatesEndSafely() throws {
        let value = TestActivity(runId: "1", suite: "swift", state: .completed, exitCode: 7)
        #expect(try JSONDecoder().decode(TestActivity.self, from: JSONEncoder().encode(value)) == value)
        let data = Data(#"{"runId":"1","suite":"swift","state":"future"}"#.utf8)
        #expect(try JSONDecoder().decode(TestActivity.self, from: data).state == .interrupted)
    }
}
