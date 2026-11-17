import Foundation

public enum FreshStartPolicy {
    public static let contextLimit = 150_000
    /// Whether an open, idle chat (`OperatorSession.chatIsIdle`) is due for a fresh conversation.
    public static func shouldStart(session: OperatorSession, now: Date, contextTokens: Int?, idle: Bool) -> Bool {
        guard idle, !session.paused, session.lifecycle.isOpen else { return false }
        return contextTokens.map { $0 >= contextLimit } == true
    }
}
