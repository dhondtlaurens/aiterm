import Foundation

public struct OperatorSession: Codable, Equatable, Sendable {
    /// The sidebar row exists before any CLI or persisted session does.
    public static let rowID = UUID(uuidString: "6AF39C02-7591-4EB4-9420-2D56565F9A1B")!
    public struct Question: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var task: UUID?
        public var text: String
        public var openedAt: Date
        public var resolvedAt: Date?
        public var answer: String?
        public var stage: Int?
        public var ownership: Int?
        public var tab: String?
        public var workerQuestion: String?
        public var workerBinding: String?
        public var deliveredAt: Date?
        public var gate: GateRequest?
        public var gateConsumedAt: Date?
        public init(id: String, task: UUID?, text: String, openedAt: Date, resolvedAt: Date? = nil) {
            self.id = id; self.task = task; self.text = text; self.openedAt = openedAt; self.resolvedAt = resolvedAt
        }
        /// Open, or a worker's question whose answer has not reached the worker yet.
        public var isPending: Bool { resolvedAt == nil || (workerQuestion != nil && answer != nil && deliveredAt == nil) }
    }
    public struct LedgerEntry: Codable, Equatable, Sendable {
        public var key: String
        public var arguments: String?
        public var result: JSONValue
        public var at: Date
        public init(key: String, result: JSONValue, at: Date, arguments: String? = nil) { self.key = key; self.result = result; self.at = at; self.arguments = arguments }
    }
    public var id: UUID
    public var generation = 1
    public var createdAt: Date
    public var window: String?
    public var conversation: String?
    public var session: String?
    public var pausedWorkers: [PausedWorker]?
    public var sourceFailures: [String: String]?
    public var paused = false
    /// Where the chat is in its life.
    public var lifecycle: Lifecycle = .idle
    public var questions: [Question] = []
    public var oracleRounds: [OracleRound] = []
    public var ledger: [LedgerEntry] = []
    public var snags: [OperatorSnag] = []
    public init(id: UUID = UUID(), createdAt: Date) { self.id = id; self.createdAt = createdAt }
    public var waitingOnYou: Int { questions.filter { $0.resolvedAt == nil }.count }
    public mutating func cached(key: String, at: Date) -> JSONValue? {
        ledger.removeAll { at.timeIntervalSince($0.at) > 7 * 86400 }
        guard let index = ledger.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = ledger.remove(at: index); ledger.append(entry)
        return entry.result
    }
    public mutating func remember(key: String, result: JSONValue, at: Date, arguments: String? = nil) {
        ledger.removeAll { $0.key == key || at.timeIntervalSince($0.at) > 7 * 86400 }
        ledger.append(LedgerEntry(key: key, result: result, at: at, arguments: arguments))
        ledger = Array(ledger.suffix(500))
    }
    public mutating func prune(at now: Date = Date()) {
        ledger = Array(ledger.filter { now.timeIntervalSince($0.at) <= 7 * 86400 }.suffix(500))
        snags = Array(snags.suffix(100))
        let closed = questions.filter { !$0.isPending }.sorted { $0.resolvedAt! > $1.resolvedAt! }.prefix(50)
        questions = questions.filter(\.isPending) + closed
    }
}

public extension OperatorSession {
    /// The chat's life, saved so a relaunch continues it where it was: no chat, a generation to open,
    /// an open chat, or the old chat being closed and then its token revoked, before a fresh chat
    /// (`renew`) or none (`retire`). The window being closed is the session's `window`.
    enum Lifecycle: KindTaggedEnum, Equatable, Sendable {
        /// What a wake typed into the open chat left: a line sent and not yet read by a global
        /// `run_status`, or a line that may sit unsent in the chat.
        public enum Wake: String, Codable, Sendable { case sent, maybeUnsent }
        /// What follows the close and the revoke.
        public enum Then: String, Codable, Sendable { case renew, retire }
        case idle
        /// The session's generation is to be opened: the open is in flight, or its reply was lost.
        case opening
        /// The chat is open; `since` is when AiTerm opened it in its current window.
        case open(since: Date, wake: Wake?)
        case closing(then: Then)
        case revoking(then: Then)
        /// Written by a newer build: inert.
        case unknown(JSONValue)

        private struct Opened: Codable { var since: Date; var wake: Wake? }

        static let preservesInvalidValue = true

        static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self? {
            switch kind {
            case "idle": return .idle
            case "opening": return .opening
            case "open":
                let opened = try value.decode(Opened.self)
                return .open(since: opened.since, wake: opened.wake)
            case "closing": return .closing(then: try value.decode(Then.self))
            case "revoking": return .revoking(then: try value.decode(Then.self))
            default: return nil
            }
        }
        var savedCase: SavedEnumCase {
            get throws {
                switch self {
                case .idle: return .known("idle")
                case .opening: return .known("opening")
                case .open(let since, let wake): return .known("open", try JSONValue(encoding: Opened(since: since, wake: wake)))
                case .closing(let then): return .known("closing", .string(then.rawValue))
                case .revoking(let then): return .known("revoking", .string(then.rawValue))
                case .unknown(let value): return .unknown(value)
                }
            }
        }

        public var isOpen: Bool { if case .open = self { true } else { false } }
        /// Opening, closing, revoking, or unknown: no chat serves the workload now.
        public var isChanging: Bool {
            switch self {
            case .opening, .closing, .revoking, .unknown: true
            case .idle, .open: false
            }
        }
        /// Closing or revoking with no chat to follow.
        public var isRetiring: Bool {
            switch self {
            case .closing(.retire), .revoking(.retire): true
            default: false
            }
        }
        /// The open chat's unread wake.
        public var wake: Wake? { if case .open(_, let wake) = self { wake } else { nil } }
    }

    /// Whether the chat is idle enough to retire or renew: no tracked act runs, no wake is unread, its
    /// window holds at most its own tab, and its live tab, if any, ended its turn and is not stopped on an error.
    static func chatIsIdle(tab: SessionInfo?, tabsInWindow: Int, actsRunning: Bool, wakeUnread: Bool) -> Bool {
        !actsRunning && !wakeUnread && tabsInWindow <= 1 && (tab.map { $0.state.turnEnded && $0.stoppedOn == nil } ?? true)
    }
}

public enum FreshStartPolicy {
    public static let contextLimit = 150_000
    /// Whether an open, idle chat (`OperatorSession.chatIsIdle`) is due for a fresh conversation.
    public static func shouldStart(session: OperatorSession, now: Date, contextTokens: Int?, idle: Bool) -> Bool {
        guard idle, !session.paused, session.lifecycle.isOpen else { return false }
        return contextTokens.map { $0 >= contextLimit } == true
    }
}
