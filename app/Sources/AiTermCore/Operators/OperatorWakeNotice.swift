import Foundation

/// The sidebar's Notice when the Operator's wake line was refused (`OperatorWaker`): what waits on the Operator,
/// from its `run_status`, and why AiTerm couldn't type into its tab, in one short sentence. Its links are Open the
/// Operator and, but for input that may hold unsent text, Fix in Settings. Not shown while the person types in its
/// tab, or for a prompt open there, which already waits on them (`shows`); for input that may hold unsent text only
/// once the wake has waited on it `OperatorTiming.unsentWakeNotice`, since a key that typed nothing holds it too and
/// nothing on screen says so. Taken down once the Operator calls `run_status` or a later wake line is delivered.
public struct OperatorWakeNotice: Equatable, Sendable {
    public static let title = "The Operator can’t be woken"

    /// The broadcast whose Operator it is.
    public var run: UUID
    public var description: String
    /// Whether Settings can fix the refusal: not the Operator's own input, which only its tab can send or clear.
    public var fixInSettings: Bool

    /// The Notice for `refusal`, with `status` as the Operator's `run_status` would show it now; nil when the refusal
    /// is not one to show (`shows`), or nothing was refused. `held` says the wake has waited out
    /// `OperatorTiming.unsentWakeNotice` on input that may hold unsent text.
    public init?(run: UUID, status: RunStatus?, refusal: Delivery, held: Bool = false) {
        guard refusal.result == .refused, Self.shows(refusal.code, held: held) else { return nil }
        self.run = run
        description = Self.waiting(status) + " " + Self.sentence(refusal.code)
        fixInSettings = refusal.code != .unsentInput
    }

    /// Whether a wake refused for `code` is the Notice's: not a prompt that waits on the person, nor their own typing
    /// in its tab, which the waker tries again after; input that may hold unsent text only once the wake was `held` on it.
    public static func shows(_ code: DeliveryCode?, held: Bool = false) -> Bool {
        code == .unsentInput ? held : ![.prompt, .typing].contains(code)
    }

    /// What waits on the Operator in `status`, as a sentence: "2 tasks ready to accept in “Payments”." Every reason the
    /// waker wakes it for is named. What waits on the person (a question, a prompt) is left out: the Operator only tells them.
    public static func waiting(_ status: RunStatus?) -> String {
        guard let status else { return "News waits for it." }
        let o = status.obligations
        func tasks(_ keys: [String], _ what: String) -> String? {
            keys.isEmpty ? nil : "\(keys.count) task\(keys.count == 1 ? "" : "s") \(what)"
        }
        let parts = [tasks(o.readyForAcceptance, "ready to accept"), tasks(o.possiblyStalled, "possibly stalled"),
                     tasks(o.uncertain, "uncertain"),
                     tasks(o.branchDrift, o.branchDrift.count == 1 ? "off its branch" : "off their branch"),
                     tasks(o.workerAsks.map(\.key), "asking the Operator"), tasks(o.changedAfterAcceptance, "changed after acceptance"),
                     tasks(o.finishedWithoutCommit, "finished with no commit"),
                     tasks(o.reviewQuiet, "in review with nothing waiting")].compactMap { $0 }
        let what = parts.isEmpty ? "News waits for it" : parts.sentenceList
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
        case .unsentInput: "Text may wait unsent in its input: send it there, or clear it with ⌃U."
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
