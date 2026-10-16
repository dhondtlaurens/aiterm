import Foundation

/// When AiTerm notifies you (spec §4.1, "Interrupting you"). Everything shows in the overview at
/// once; this only decides whether the notification goes now or is held, bundled with the others.
/// AiTerm holds it, not the operator, so a silent or offline operator never strands a question.
public enum InterruptPolicy {
    public enum Event: Equatable, Sendable {
        /// The operator's `ask_you`. `holdsUpEverything`: no remaining task can go on without it.
        case question(holdsUpEverything: Bool)
        /// A worker waits on a permission prompt, or on one AiTerm cannot classify (spec §7.2).
        case permissionPrompt
        case unknownPrompt
        /// A plan revision waits for your approval (gated runs).
        case planWaiting
        case runBlocked
        case runComplete
    }

    public enum Decision: Equatable, Sendable { case notifyNow, hold }

    /// - Parameters:
    ///   - otherWorkCanProceed: whether any task of the run can still go on while you are away.
    ///   - waited: how long the oldest held question has waited.
    public static func decide(_ event: Event, autonomy: Autonomy, otherWorkCanProceed: Bool,
                              waited: TimeInterval) -> Decision {
        switch event {
        // At every stop: a worker's prompt, a blocked run, a plan to approve and a done run.
        case .permissionPrompt, .unknownPrompt, .planWaiting, .runBlocked, .runComplete:
            return .notifyNow
        case .question(let holdsUpEverything):
            switch autonomy {
            case .askFirst:
                return .notifyNow
            case .routine:
                if holdsUpEverything || !otherWorkCanProceed || waited >= OperatorTiming.routineBundleAfter { return .notifyNow }
                return .hold
            case .trusted:
                return otherWorkCanProceed ? .hold : .notifyNow
            case .handsOff:
                // Sent with the run's blocked or complete notification, never on its own.
                return .hold
            }
        }
    }
}
