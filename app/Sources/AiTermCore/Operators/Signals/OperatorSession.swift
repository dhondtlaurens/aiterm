import Foundation

public struct OperatorSession: Codable, Equatable, Sendable {
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
        public init(id: String, task: UUID?, text: String, openedAt: Date, resolvedAt: Date? = nil) {
            self.id = id; self.task = task; self.text = text; self.openedAt = openedAt; self.resolvedAt = resolvedAt
        }
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
    public var paused = false
    public var startingFresh = false
    public var handover: OperatorHandover?
    public var questions: [Question] = []
    public var oracleRounds: [ChallengeRecord] = []
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
    public mutating func prune() {
        let closed = questions.filter { $0.resolvedAt != nil }.sorted { $0.resolvedAt! > $1.resolvedAt! }.prefix(50)
        questions = questions.filter { $0.resolvedAt == nil } + closed
        oracleRounds.removeAll { $0.stage == .acted }
    }
}
