import Foundation

public enum SignalAction: Equatable, Sendable {
    case workerStarted, workRequested, matched(SignalStage), watch(DoneWhen), finish(DoneWhen), advancePending
    case block(String), resume, archive
    /// A launching stage whose worker could not start blocks with the reason.
    case launchFailed(String)
    /// A worker found running after its launch reply was lost: the stage works on in it.
    case adopted
    /// A launching stage waits for the Operator's agent-row or project choice; `chosen` launches it.
    case needChoice, chosen
}
