import Foundation
import AiTermCore

/// The Operator tick's schedule step: which scheduled runs are due (`ScheduleDecision`), handed to `ItemRouter`, which
/// saves their tasks (an Operator signal's) or returns their pick-ups (a project signal's), their skips and cursors in one
/// flush. Nothing of a signal is due while it may not act (`canSchedule`: none while the Operator is stopped, an Operator
/// signal's while it is paused), so the latest time missed meanwhile runs once on the first tick after; older ones are
/// dropped.
@MainActor final class SignalScheduler {
    private let workspace: WorkspaceStore
    private let router: ItemRouter
    private let now: () -> Date
    /// The Mac's calendar and time zone, followed as they change.
    var calendar: () -> Calendar = { Calendar.autoupdatingCurrent }
    /// Whether `signal`'s schedule may act now.
    var canSchedule: @MainActor (Signal) -> Bool = { _ in true }
    /// The signals with a run queued, being created or waiting to be tried again, which has no task yet
    /// (`ProjectSignals.pendingRuns`): their next time is skipped as unfinished.
    var pending: @MainActor () -> Set<UUID> = { [] }
    init(workspace: WorkspaceStore, router: ItemRouter, now: @escaping () -> Date) {
        self.workspace = workspace; self.router = router; self.now = now
    }
    /// Starts each run that is due and records each skip: the Operator tasks to launch and the project runs to pick up.
    func tick() -> ItemRouter.Routed {
        guard workspace.canChangeWorkspace else { return ItemRouter.Routed() }
        let state = workspace.state, calendar = calendar()
        let outcome = ScheduleDecision.decide(signals: state.signals, cursors: state.scheduleCursors,
                                              tasks: state.tasks, archive: state.archive.map(\.task), projects: state.projects,
                                              now: now(), calendar: calendar, mayAct: canSchedule, pending: pending())
        return router.apply(schedule: outcome, calendar: calendar)
    }
}
