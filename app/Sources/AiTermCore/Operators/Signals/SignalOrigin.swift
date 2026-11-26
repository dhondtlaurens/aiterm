import Foundation

/// The mark a signal leaves on an ordinary task: which signal started it or ran it last, on what, and what that signal
/// still owes it. A project signal's task carries one and no `SignalTask`; a task taken over from the Operator keeps
/// one too, so its chain stays known. Optional fields are left out while nil.
public struct SignalOrigin: Codable, Equatable, Sendable {
    /// The signal that started the task, or the last one that ran it.
    public var signal: UUID
    /// That signal's name then. The live name wins while the signal exists; this one names a removed signal.
    public var name: String
    /// What matched: its identity joins the task to later matches. A scheduled run's `.run` reference too.
    public var item: ItemRef
    public var startedAt: Date
    /// The signals that ran the task before, oldest first.
    public var earlier: [SignalStep]?
    /// A prompt still to reach the task's worker.
    public var owed: OwedPrompt?
    /// The Done trigger the baseline was read for (source, newline, query), and whether it matched at the last
    /// complete read.
    public var doneKey: String?
    public var doneMatched: Bool?
    /// When the Done edge, a merge or a close was seen; no query is read after it.
    public var doneAt: Date?
    /// Then is finished: Keep at once, Archive once the teardown succeeded or refused for good. While `doneAt` is set
    /// and this is not, Then is pending.
    public var thenApplied: Bool?
    /// Why Then's archive did not happen, when it refused for good.
    public var thenNote: String?
    /// The signal's latest prompt in its worker.
    public var turn: SignalTurn?
    /// When the notification for the latest turn a signal's prompt started was posted.
    public var notifiedAt: Date?
    public init(signal: UUID, name: String, item: ItemRef, startedAt: Date, earlier: [SignalStep]? = nil,
                owed: OwedPrompt? = nil) {
        self.signal = signal; self.name = name; self.item = item; self.startedAt = startedAt
        self.earlier = earlier; self.owed = owed
    }
    /// The `doneKey` a baseline read for `done` saves: its source, a newline, its query. A signal's Done edited since
    /// no longer has it.
    public static func doneKey(_ done: SignalTrigger) -> String { done.source.rawValue + "\n" + done.query }
}

/// A signal that ran a task before the one that runs it now.
public struct SignalStep: Codable, Equatable, Sendable {
    public var signal: UUID
    /// The signal's name when it ran the task.
    public var name: String
    /// When it started running the task.
    public var at: Date
    public init(signal: UUID, name: String, at: Date) { self.signal = signal; self.name = name; self.at = at }
}

/// A prompt a signal composed that has still to reach its task's worker.
public struct OwedPrompt: Codable, Equatable, Sendable {
    public enum Kind: OpenStringEnum, Hashable, Sendable {
        /// The first prompt, given to a new agent at launch.
        case launch
        /// Typed into an existing conversation: a re-match, or a task you made that a signal matched.
        case delivery
        case unknown(String)
        static let knownCases: [Self] = [.launch, .delivery]
        var savedName: String {
            switch self {
            case .launch: "launch"
            case .delivery: "delivery"
            case .unknown(let value): value
            }
        }
    }
    /// The composed prompt.
    public var text: String
    public var at: Date
    public var kind: Kind
    public init(text: String, at: Date, kind: Kind) { self.text = text; self.at = at; self.kind = kind }
}

/// A signal's latest prompt in its task's worker, saved on every change so a restart keeps it.
public struct SignalTurn: Codable, Equatable, Sendable {
    /// When the prompt was sent: Enter pressed by the delivery, or the launch.
    public var sentAt: Date?
    /// When it was pasted with Enter left to the person.
    public var pastedAt: Date?
    /// Whether the task's session was seen working after `sentAt` or `pastedAt`.
    public var seenWorking: Bool?
    public init(sentAt: Date? = nil, pastedAt: Date? = nil, seenWorking: Bool? = nil) {
        self.sentAt = sentAt; self.pastedAt = pastedAt; self.seenWorking = seenWorking
    }
}
