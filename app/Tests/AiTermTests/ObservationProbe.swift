import Observation
import Synchronization

/// Whether `write` changes anything `read` looked at — what a view whose body is `read` would be
/// redrawn for. `read` is usually a view's `body`, evaluated outside SwiftUI.
@MainActor
func invalidates(_ read: () -> Void, by write: () -> Void) -> Bool {
    let changed = Mutex(false)
    withObservationTracking(read) { changed.withLock { $0 = true } }
    write()
    return changed.withLock { $0 }
}
