import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct TestActivityTests {
    @Test func queuedAndRunningTestsAreDistinctAndExposeTheirHolder() {
        let queued = TestActivity(runId: "own", suite: "swift", state: .queued, queuePosition: 2,
                                  holder: "all in /repo/another-worktree")
        #expect(queued.isActive && queued.line == "tests queued · #2")
        #expect(queued.holder == "all in /repo/another-worktree")
        let running = TestActivity(runId: "own", suite: "swift", state: .running)
        #expect(running.isActive && running.line == "running tests · swift")
        for activity in [TestActivity(runId: "own", suite: "swift", state: .completed, exitCode: 0),
                         TestActivity(runId: "own", suite: "swift", state: .completed, exitCode: 9),
                         TestActivity(runId: "own", suite: "swift", state: .interrupted)] {
            #expect(!activity.isActive)
        }
    }

    @Test func ownLiveTestsKeepAnEndedWorkerBusyUntilItsOwnExit() throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let task = world.state.task(id: id)!
        var session = SessionInfo.make("main", task: task.id, state: .done)
        session.testActivity = TestActivity(runId: "own", suite: "daemon", state: .queued, queuePosition: 1)
        #expect(SidebarModel.aggregate(tabs: [session]) == .background)
        #expect(task.workerTabs(in: [session])[0].isStillAtWork)
        session.testActivity = TestActivity(runId: "own", suite: "daemon", state: .completed, exitCode: 0)
        #expect(SidebarModel.aggregate(tabs: [session]) == .done)
        #expect(!task.workerTabs(in: [session])[0].isStillAtWork)
        session.state = .working
        #expect(SidebarModel.aggregate(tabs: [session]) == .working)
        #expect(SidebarModel.backgroundJobs(of: [session]).isEmpty)
    }

    /// The row's third line is the Operator's alone (29 Oct 2026): a task of your own running its tests draws no line,
    /// only background work, on its mark and its card; a driven one's line still says it.
    @Test func ownTestsDrawNoLineOnATaskOfYourOwn() throws {
        let project = Project.make(name: "web")
        let task = TaskItem.make(project: project.id, title: "Mine")
        var state = AppState()
        state.append(project: project)
        state.tasks = [task]
        var session = SessionInfo.make("main", task: task.id, state: .done)
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
