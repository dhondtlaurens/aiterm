import Foundation

/// The sidebar's Notice when the Operator's wake line was refused (`OperatorWaker`): what waits on the Operator,
/// from its `run_status`, and why AiTerm couldn't type into its tab, in one short sentence. Its links are Open the
/// Operator and Fix in Settings. Not shown while the person types in its tab, or for a prompt open there, which
/// already waits on them (`shows`); taken
/// down once the Operator calls `run_status` or a later wake line is delivered.
public struct OperatorWakeNotice: Equatable, Sendable {
    public static let title = "The Operator can’t be woken"

    /// The broadcast whose Operator it is.
    public var run: UUID
    public var description: String

    /// The Notice for `refusal`, with `status` as the Operator's `run_status` would show it now; nil when the refusal
    /// is not one to show (`shows`), or nothing was refused.
    public init?(run: UUID, status: RunStatus?, refusal: Delivery) {
        guard refusal.result == .refused, Self.shows(refusal.code) else { return nil }
        self.run = run
        description = Self.waiting(status) + " " + Self.sentence(refusal.code)
    }

    /// Whether a wake refused for `code` is the Notice's: not a prompt that waits on the person, nor their own typing
    /// or unsent text in its tab, which the waker tries again after.
    public static func shows(_ code: DeliveryCode?) -> Bool {
        ![.prompt, .typing, .unsentInput].contains(code)
    }

    /// What waits on the Operator in `status`, as a sentence: "2 tasks ready to accept in “Payments”."
    /// What waits on the person (a question, a prompt) is left out: the Operator only tells them.
    public static func waiting(_ status: RunStatus?) -> String {
        guard let status else { return "News waits for it." }
        let o = status.obligations
        func tasks(_ keys: [String], _ what: String) -> String? {
            keys.isEmpty ? nil : "\(keys.count) task\(keys.count == 1 ? "" : "s") \(what)"
        }
        let parts = [tasks(o.readyForAcceptance, "ready to accept"), tasks(o.possiblyStalled, "possibly stalled"),
                     tasks(o.uncertain, "uncertain"),
                     tasks(o.branchDrift, o.branchDrift.count == 1 ? "off its branch" : "off their branch")].compactMap { $0 }
        let what = switch parts.count {
        case 0: "News waits for it"
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        return "\(what) in “\(status.run.name)”."
    }

    /// Why the wake line was refused, in one short plain sentence: the Notice's words for each code, kept here.
    public static func sentence(_ code: DeliveryCode?) -> String {
        switch code {
        case .itermDisconnected: "iTerm2 isn’t connected."
        case .sessionClosed: "Its tab is closed."
        case .replaced: "Another program now runs in its tab."
        case .ownership: "Its tab changed hands."
        case .notChecked: "AiTerm hasn’t checked it can type into this Claude Code version."
        case .unsupported: "AiTerm can’t read prompts in its tab."
        case .typing: "You’re typing in its tab."
        case .unsentInput: "Unsent text waits in its input."
        case .screenUnread: "Its screen couldn’t be read."
        case .prompt: "A prompt in its tab waits on you."
        case .unrecognisedScreen: "Its tab doesn’t show Claude Code’s input box."
        case .itermRefused: "iTerm2 didn’t take the text."
        case .pasteOnly: "Its Enter was held back."
        case .nothing, .messageFile, .wakeText: "AiTerm couldn’t type the wake line."
        case .unknown, nil: "AiTerm couldn’t type into its tab."
        }
    }
}
