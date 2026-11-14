import Foundation

public enum FreshStartPolicy {
    public static let contextLimit = 150_000
    public static let ageLimit: TimeInterval = 86400
    public static func shouldStart(session: OperatorSession, now: Date, contextTokens: Int?, idle: Bool, wakePending: Bool) -> Bool {
        guard idle, !wakePending, !session.paused, !session.startingFresh, session.oracleRounds.isEmpty else { return false }
        return now.timeIntervalSince(session.createdAt) >= ageLimit || contextTokens.map { $0 >= contextLimit } == true
    }
}
