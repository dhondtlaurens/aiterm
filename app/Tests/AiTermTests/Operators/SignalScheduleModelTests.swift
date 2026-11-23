import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// New Signal with a schedule and the Operator's Done: Starts on and Done when, their defaults, the cron's check and
/// next runs, and what a scheduled signal saves.
@Suite @MainActor struct SignalScheduleModelTests {
    let choice = SignalWorld.agent
    var context: SignalContext {
        SignalContext(models: [.claude: [AgentModel(id: choice.model, label: "Opus", detail: nil,
                                                   efforts: ["medium", "high"], defaultEffort: "high")]], defaults: [.claude: choice])
    }
    static let brussels: Calendar = {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!; return calendar
    }()
    func model(save: @escaping @MainActor (Signal) async throws -> Void = { _ in }) -> (SignalModel, SignalWorld) {
        let world = SignalWorld()
        let model = SignalModel(projects: world.state.projects, context: context, save: save)
        model.calendar = Self.brussels
        model.now = { Self.brussels.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))! }
        return (model, world)
    }

    @Test func aScheduleOpensOnTheOperatorsDoneAndAnItemOnAQuery() {
        let (model, world) = model()
        #expect(model.startKind == .item && model.doneKind == .query)
        model.startKind = .schedule
        #expect(model.start.source == .schedule && model.doneKind == .operatorDecides)
        #expect(model.start.project == world.project.id, "the only project is chosen")
        model.startKind = .item
        #expect(model.start.source == .jira && model.doneKind == .query)
        // Once the person chose Done when, Starts on leaves it alone.
        model.doneKind = .operatorDecides
        model.startKind = .schedule; model.startKind = .item
        #expect(model.doneKind == .operatorDecides)
    }

    @Test func switchingBackRestoresWhatWasTyped() {
        let (model, _) = model()
        model.start.query = "labels = ready"
        model.startKind = .schedule
        model.start.query = "0 9 * * 1"
        model.startKind = .item
        #expect(model.start.query == "labels = ready")
        model.startKind = .schedule
        #expect(model.start.query == "0 9 * * 1")
    }

    @Test func aScheduledSignalsQueryDoneCannotReadJira() {
        let (model, _) = model()
        model.done = SignalTrigger(source: .jira, query: "status = Done")
        model.startKind = .schedule
        model.doneKind = .query
        #expect(model.done.source == .gitLab && model.done.query.isEmpty)
    }

    @Test func theCronFieldSaysWhyAndContinueWaitsForACronAndAProject() {
        let (model, _) = model()
        model.name = "Weekly dependency update"
        model.startKind = .schedule
        model.start.project = nil
        model.start.query = "0 9 * * Mo"
        #expect(model.startRefusal?.message == "“Mo” isn’t a weekday: use 0–6 or MON–SUN.")
        #expect(!model.canAdvance(step: SignalModel.startStep) && model.nextRuns.isEmpty)
        model.start.query = "0 9 * * 1"
        #expect(model.startRefusal == nil && !model.canAdvance(step: SignalModel.startStep), "no project yet")
        model.start.project = model.projects.first?.id
        #expect(model.canAdvance(step: SignalModel.startStep))
        let wall = model.nextRuns.map { Self.brussels.dateComponents([.month, .day, .hour], from: $0) }
        #expect(wall.map(\.day) == [30, 7, 14, 21] && wall.allSatisfy { $0.hour == 9 })
        #expect(SignalNextRuns.time(model.nextRuns[0], calendar: Self.brussels) == "Mon 30 Nov 09:00")
    }

    @Test func aScheduledSignalSavesNoDescriptionsAndItsProject() async throws {
        var saved: [Signal] = []
        let (model, world) = model { saved.append($0) }
        model.name = "Weekly dependency update"
        model.startKind = .schedule
        model.start.query = " 0 9 * * 1 "
        model.prompt = "Update the dependencies"
        model.mergeWhenReady = true
        #expect(model.offersMerge && model.canWrite(start: false) == false)
        #expect(await model.create())
        let signal = try #require(saved.first)
        #expect(signal.start == SignalTrigger(source: .schedule, query: "0 9 * * 1", project: world.project.id))
        #expect(signal.done.source == .operator && signal.finish.mergesWhenReady)
        #expect(!signal.work.ticketDescription && !signal.work.requestDescription)
    }

    @Test func aScheduleReadsNoPreview() async {
        var reads = 0
        let world = SignalWorld()
        let model = SignalModel(projects: world.state.projects, context: context, preview: { _ in reads += 1; return SignalRead(items: [], complete: true) },
                                save: { _ in })
        model.startKind = .schedule
        model.start.query = "0 9 * * 1"
        await model.loadPreview()
        #expect(reads == 0 && model.previewError == nil && model.startCount == nil)
    }
}
