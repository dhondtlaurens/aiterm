import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A section's signals sheet: its rows, in priority order, say each signal's triggers and issues, and its menus act on
/// the signal as it is saved when they run.
@MainActor
@Suite(.serialized) struct SignalsSheetModelTests {
    private func controller(_ world: SignalWorld, prompter: Prompter = ScriptedPrompter()) throws -> AppController {
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        try controller.workspace.load()
        controller.workspace.mutate { $0 = world.state }
        return controller
    }

    private func sheet(_ controller: AppController, _ section: SidebarSection = .operator) throws -> SignalsSheetModel {
        controller.presentSignals(section)
        guard case .signals(let model)? = controller.sheet else { throw SheetMissing() }
        return model
    }
    private struct SheetMissing: Error {}

    @Test func eachSectionListsItsOwnSignalsInPriorityOrder() throws {
        var world = SignalWorld()
        let first = world.signal(name: "First"), project = world.projectSignal(name: "Reviews"), second = world.signal(name: "Second")
        let controller = try controller(world); defer { controller.shutdown() }
        let model = try sheet(controller)
        #expect(model.title == "Operator signals")
        #expect(model.rows.map(\.id) == [first, second])
        #expect(model.rows.map(\.canMoveUp) == [false, true])
        #expect(model.rows.map(\.canMoveDown) == [true, false])
        controller.sheet = nil
        let projects = try sheet(controller, .projects)
        #expect(projects.title == "Project signals")
        #expect(projects.rows.map(\.id) == [project])
        #expect(projects.rows.first?.canMoveUp == false && projects.rows.first?.canMoveDown == false)
    }

    /// A query's Starts and Done, a schedule's words with its next run, and **You decide**.
    @Test func theLinesSayEachTriggerAndASchedulesNextRun() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 8))!
        var world = SignalWorld()
        world.signal(name: "Query")
        world.scheduled(from: monday)
        world.projectSignal()
        let operatorRows = SignalsSheetModel.rows(state: world.state, section: .operator, failure: { _ in nil }, now: monday, calendar: calendar)
        #expect(operatorRows.map(\.lines) == [
            ["Starts: labels = operator", "Done: status = Done"],
            ["Starts: At 09:00 on Monday (0 9 * * 1)", "Next run: 23 Nov 2026 09:00", "Done: The Operator decides"],
        ])
        #expect(operatorRows.map(\.mark) == [ProviderIcon.source(of: .jira), ProviderIcon.source(of: .schedule)])
        let projectRows = SignalsSheetModel.rows(state: world.state, section: .projects, failure: { _ in nil }, now: monday, calendar: calendar)
        #expect(projectRows.map(\.lines) == [["Starts: labels = review", "Done: You decide"]])
        #expect(operatorRows.allSatisfy(\.issues.isEmpty) && projectRows.allSatisfy(\.issues.isEmpty))
    }

    /// What needs the person, in order: a signal this version cannot run, its source's failing read, each skipped item.
    @Test func theIssueLinesSayWhatCannotRunWhatFailsAndWhatWasSkipped() {
        var world = SignalWorld()
        let broken = world.signal(name: "Broken", done: SignalTrigger(source: .person, query: ""))
        let failing = world.signal(name: "Failing")
        world.state.signalSeen = ["PAY-9", "PAY-7"].map {
            SignalSeen(signal: failing, item: .ticket(site: "https://jira.example", key: $0), disposition: .skipped, at: world.now, reason: "No project")
        }
        let issue = SignalReadIssues.Issue(signal: failing, text: "The server answered 401.", since: world.now, attempts: 1)
        let rows = SignalsSheetModel.rows(state: world.state, section: .operator,
                                          failure: { $0 == failing ? issue : nil }, now: world.now)
        let retry = SignalReadIssues.retry(at: world.now + SignalPoller.failureBackOff, from: world.now)
        #expect(rows.first { $0.id == broken }?.issues == ["This signal can’t run as it is set up."])
        #expect(rows.first { $0.id == failing }?.issues == ["Can’t read Jira: The server answered 401. " + retry, "PAY-7: No project",
                                                            "PAY-9: No project"])
    }

    /// Move Up passes the signal of its kind above, over a project signal between them, and that order is the priority;
    /// at the top it does nothing.
    @Test func moveUpChangesTheOrderAndThePriority() throws {
        var world = SignalWorld()
        let first = world.signal(name: "First"), project = world.projectSignal(), second = world.signal(name: "Second")
        let controller = try controller(world); defer { controller.shutdown() }
        let model = try sheet(controller)
        model.move(second, .up)
        #expect(model.rows.map(\.id) == [second, first])
        #expect(controller.state.signals.map(\.id).filter { $0 != project } == [second, first], "the saved order is the priority")
        #expect(controller.state.signals.contains { $0.id == project })
        let before = controller.state.signals
        model.move(second, .up)
        #expect(controller.state.signals == before, "the first moves no further up")
    }

    @Test func switchOffSavesThroughTheController() async throws {
        var world = SignalWorld(); let id = world.signal()
        let controller = try controller(world); defer { controller.shutdown() }
        let model = try sheet(controller)
        model.switchOnOff(id)
        #expect(await eventually(describing: "the signal switched off") { controller.state.signal(id: id)?.enabled == false })
        #expect(model.rows.first?.switchedOff == true)
        model.switchOnOff(id)
        #expect(await eventually(describing: "the signal switched on") { controller.state.signal(id: id)?.enabled == true })
    }

    @Test func removeAsksFirst() async throws {
        var world = SignalWorld(); let kept = world.signal(name: "Kept"), removed = world.signal(name: "Gone")
        let prompter = ScriptedPrompter(answering: "Cancel", "Remove Signal")
        let controller = try controller(world, prompter: prompter); defer { controller.shutdown() }
        let model = try sheet(controller)
        model.remove(kept)
        #expect(await eventually(describing: "the first question") { prompter.asked.count == 1 })
        model.remove(removed)
        #expect(await eventually(describing: "the removal") { controller.state.signal(id: removed) == nil })
        #expect(prompter.asked.map(\.message) == ["Remove “Kept”?", "Remove “Gone”?"])
        #expect(model.rows.map(\.id) == [kept], "Cancel kept it; the removed one's row is gone")
    }

    /// A row's menu acts on the saved signal when it runs: once the signal is gone it does nothing, and the list stays.
    @Test func aRowsActionsResolveTheSignalWhenTheyRun() throws {
        var world = SignalWorld(); let id = world.signal()
        let controller = try controller(world); defer { controller.shutdown() }
        let model = try sheet(controller)
        controller.workspace.mutate { $0.removeSignal(id: id) }
        model.edit(id); model.switchOnOff(id); model.move(id, .up)
        guard case .signals? = controller.sheet else { Issue.record("the list closed"); return }
        #expect(model.rows.isEmpty)
    }

    /// The OPERATOR heading's signals icon says its count in words.
    @Test func theIconsLabelSaysTheCountInWords() {
        #expect(SectionSignalsButton.label(section: .operator, count: 3) == "3 Operator signals")
        #expect(SectionSignalsButton.label(section: .operator, count: 1) == "1 Operator signal")
        #expect(SectionSignalsButton.label(section: .projects, count: 2) == "2 project signals")
    }
}
