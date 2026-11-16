import Foundation

public enum FreshStartPolicy {
    public static let contextLimit = 150_000
    public static func shouldStart(session: OperatorSession, now: Date, contextTokens: Int?, idle: Bool, wakePending: Bool) -> Bool {
        guard idle, !wakePending, !session.paused, !session.startingFresh, session.wakeAwaitingRead != true else { return false }
        return contextTokens.map { $0 >= contextLimit } == true
    }
}
