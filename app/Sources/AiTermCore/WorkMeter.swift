import Synchronization

/// Counts named pieces of work for a test that budgets them: how often a status was built, the requests derived, a
/// file saved. A test binds one with `WorkMeter.$current.withValue(_:)` and reads its counts after; with none bound,
/// as in the app, `note` does nothing. A task-local, so tests running side by side each count only their own work,
/// which a counter on a pure function could not. Work a caller hands to a queue or a thread of its own is not in that
/// task and is not counted: note it where it is asked for.
public final class WorkMeter: Sendable {
    /// The work the budgets count, each noted where it is done.
    public enum Work: String, Sendable {
        /// `RunStatus.build`: one whole `run_status` snapshot.
        case statusBuild
        /// `OperatorRequests.open`: what a run needs from the person.
        case requests
        /// `TaskItem.workerTabs`: one task's worker tabs matched to the sessions.
        case workerTabs
        /// `WindowReconciler.pass`: one comparison of the rows with the windows.
        case reconcilerPass
        /// `WorkerTurnReader`: one worker's turn read: its transcript's tail read, or git asked about its branch. A turn
        /// whose transcript was not written since it was last read, and whose reply is the same, costs neither.
        case turnRead
        /// `StateStore.save`: the workspace encoded and written by the caller itself, as a flush does.
        case stateSave
        /// One file a `StateStore` writes the bytes of: the workspace, or its backup.
        case stateWrite
    }

    @TaskLocal public static var current: WorkMeter?

    private let counts = Mutex<[Work: Int]>([:])

    public init() {}

    public static func note(_ work: Work) {
        current?.counts.withLock { $0[work, default: 0] += 1 }
    }

    public subscript(work: Work) -> Int { counts.withLock { $0[work] ?? 0 } }

    /// Every count so far, and none after: for reading one step's work in a longer scenario.
    public func take() -> [Work: Int] {
        counts.withLock { counts in defer { counts = [:] }; return counts }
    }
}
