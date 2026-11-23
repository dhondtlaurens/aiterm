import Foundation
import AiTermCore

/// The Operator tick's schedule step: which scheduled runs are due (`ScheduleDecision`), handed to `ItemRouter`, which
/// saves their tasks, skips and cursors in one flush. Nothing is due while the Operator is stopped or paused, so the
/// latest time missed meanwhile runs once on the first tick after; older ones are dropped.
@MainActor final class SignalScheduler {
    private let workspace: WorkspaceStore
    private let router: ItemRouter
    private let now: () -> Date
    /// The Mac's calendar and time zone, followed as they change.
    var calendar: () -> Calendar = { Calendar.autoupdatingCurrent }
    var canSchedule: @MainActor () -> Bool = { true }
    init(workspace: WorkspaceStore, router: ItemRouter, now: @escaping () -> Date) {
        self.workspace = workspace; self.router = router; self.now = now
    }
    /// Starts each run that is due and records each skip; the ids of the tasks to launch.
    func tick() -> [UUID] {
        guard workspace.canChangeWorkspace else { return [] }
        let state = workspace.state, calendar = calendar()
        let outcome = ScheduleDecision.decide(signals: state.signals, cursors: state.scheduleCursors,
                                              tasks: state.tasks + state.archive.map(\.task), projects: state.projects,
                                              now: now(), calendar: calendar, mayAct: canSchedule())
        return router.apply(schedule: outcome, calendar: calendar)
    }
}
