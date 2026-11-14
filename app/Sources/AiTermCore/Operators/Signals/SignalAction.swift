import Foundation

public enum SignalAction: Equatable, Sendable {
    case workerStarted, matched(SignalStage), watch(DoneWhen), finish(DoneWhen), advancePending
    case block(String), resume, archive, stop, takeOver
}
