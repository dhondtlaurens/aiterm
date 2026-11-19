import Foundation
import Network

/// Tells the Operator each time the Mac's network is usable again, so a source read that failed while it was gone is not
/// held for the whole failure back-off (`SignalPoller.networkReturned`).
struct NetworkWatch {
    /// Starts watching and returns what stops it. `returned` runs on the main actor whenever the path is satisfied.
    var start: @MainActor (_ returned: @escaping @MainActor () -> Void) -> @MainActor () -> Void

    /// Watches nothing: the default, so a test never reads this Mac's network.
    static let none = NetworkWatch { _ in {} }
    /// An `NWPathMonitor` on the main queue. Every satisfied update counts, not only a change from unsatisfied: after a
    /// sleep the monitor may never report the path going down.
    static let live = NetworkWatch { returned in
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            MainActor.assumeIsolated { returned() }
        }
        monitor.start(queue: .main)
        return { monitor.cancel() }
    }
}
