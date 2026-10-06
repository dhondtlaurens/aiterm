import Foundation
import Testing
@testable import AiTermCore

@MainActor
struct WorkInFlightTests {
    /// A create and a pull each run alone in their project, beside each other and beside the same
    /// work in another project.
    @Test func workThatRunsAloneIsRefusedOnlyBesideItself() throws {
        let work = WorkInFlight()
        let project = UUID(), other = UUID()
        let creating = try #require(work.begin(.creatingTask, onProject: project))
        #expect(work.begin(.creatingTask, onProject: project) == nil)
        #expect(work.begin(.changingDefaultBranch, onProject: project) != nil)
        #expect(work.begin(.creatingTask, onProject: other) != nil)
        work.end(creating)
        #expect(work.begin(.creatingTask, onProject: project) != nil)
    }

    /// Two terminals can open in one project at once, and the project is busy until both have.
    @Test func windowsOpenSideBySideAndTheProjectIsBusyUntilTheLastHas() throws {
        let work = WorkInFlight()
        let project = UUID()
        let first = try #require(work.begin(.openingTerminal, onProject: project))
        let second = try #require(work.begin(.openingTerminal, onProject: project))
        work.end(first)
        #expect(work.isRunning(.openingTerminal, onProject: project))
        #expect(!work.isRunning(.openingTaskWindow, onProject: project))
        work.end(second)
        #expect(!work.isRunning(.openingTerminal, onProject: project))
    }

    /// A task and a terminal do one thing at a time, whatever it is.
    @Test func aTaskOrTerminalRunsOneThingAtATime() throws {
        let work = WorkInFlight()
        let task = UUID(), terminal = UUID()
        let reopening = try #require(work.begin(.reopening, onTask: task))
        #expect(work.begin(.removing(windowLetGo: false), onTask: task) == nil)
        #expect(work.operation(onTask: task) == .reopening)
        work.end(reopening)
        #expect(work.operation(onTask: task) == nil)

        let closing = try #require(work.begin(.closing, onTerminal: terminal))
        #expect(work.begin(.reopening, onTerminal: terminal) == nil)
        #expect(work.operation(onTerminal: terminal) == .closing)
        work.end(closing)
        #expect(work.operation(onTerminal: terminal) == nil)
    }

    /// A token ends its own work only: ended twice, or after its subject went on to other work, it
    /// leaves that work running.
    @Test func aTokenEndsOnlyItsOwnWork() throws {
        let work = WorkInFlight()
        let task = UUID()
        let first = try #require(work.begin(.reviewing, onTask: task))
        work.end(first)
        let second = try #require(work.begin(.closing, onTask: task))
        work.end(first)
        work.update(first, to: .removing(windowLetGo: true))
        #expect(work.operation(onTask: task) == .closing)
        work.update(second, to: .removing(windowLetGo: true))
        #expect(work.operation(onTask: task) == .removing(windowLetGo: true))
    }

    /// Whoever draws from the ledger hears each subject whose work began, changed or ended — and not
    /// of a change that changed nothing.
    @Test func eachChangeIsHeardForItsSubject() throws {
        let work = WorkInFlight()
        let task = UUID(), project = UUID()
        let heard = Recorded<WorkInFlight.Subject>()
        work.onChange { heard.values.append($0) }
        let removing = try #require(work.begin(.removing(windowLetGo: false), onTask: task))
        work.update(removing, to: .removing(windowLetGo: false))
        work.update(removing, to: .removing(windowLetGo: true))
        work.end(removing)
        work.end(removing)
        let pull = try #require(work.begin(.changingDefaultBranch, onProject: project))
        #expect(work.isRunning(.changingDefaultBranch, onProject: project))
        work.end(pull)
        #expect(heard.values == [.task(task), .task(task), .task(task), .project(project), .project(project)])
    }

    /// The row's caption while a task's work runs: a removal or a closing says so, a reopen or a
    /// review leaves whatever the row said.
    @Test func onlyRemovingAndClosingSayAnythingOnTheRow() {
        #expect(TaskOperation.removing(windowLetGo: true).removal == .removing)
        #expect(TaskOperation.closing.removal == .closing)
        #expect(TaskOperation.reopening.removal == nil)
        #expect(TaskOperation.reviewing.removal == nil)
    }
}

/// What a test's callbacks heard, in order.
@MainActor
private final class Recorded<Value> {
    var values: [Value] = []
}
