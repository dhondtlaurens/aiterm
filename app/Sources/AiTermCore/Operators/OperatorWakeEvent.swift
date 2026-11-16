import Foundation

/// The events AiTerm wakes the Operator with. The daemon types only these (`WAKE_EVENTS` in
/// `daemon/aitermd/delivery.py`); the wire manifest carries its list and `WireContractTests`
/// checks this enum against it, so a new event cannot be refused at runtime.
public enum OperatorWakeEvent: String, CaseIterable, Sendable {
    case workerEnded = "worker_ended", taskBlocked = "task_blocked", agentChoice = "agent_choice"
    case questionWaiting = "question_waiting", reconnected, signalFailed = "signal_failed"
    case settingsChanged = "settings_changed", sessionRecovered = "session_recovered"

    /// The fixed line typed into the Operator's chat: an app-owned event and UUID, never host text.
    public func line(_ id: UUID) -> String { "[AiTerm] \(rawValue) \(id.uuidString); call run_status" }
}
