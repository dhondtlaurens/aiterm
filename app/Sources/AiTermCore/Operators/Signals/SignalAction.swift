import Foundation

public enum SignalAction: Equatable, Sendable {
    case workerStarted, workRequested, matched(SignalStage), watch(DoneWhen), finish(DoneWhen), advancePending
    case block(String), resume, archive, stop, takeOver
    /// A launching stage waits for the Operator's agent-row or project choice; `chosen` launches it.
    case needChoice, chosen
}
