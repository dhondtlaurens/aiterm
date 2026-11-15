import AiTermCore
import Foundation

/// A complete query read and the signals that share it, routed with the rest of its host's pass.
struct SignalObservation: Sendable {
    var signals: [UUID]
    var read: SignalRead
}
