import Foundation

/// What is currently going wrong between AiTerm and its Operator, one issue per source. Each issue
/// clears only when its own source next succeeds, so a success elsewhere cannot hide it. A failure
/// AiTerm retries by itself needs the person only once it has failed three times in a row; one the
/// person started (they can try again) needs them at once.
public struct OperatorIssues: Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        /// Typing a wake line into the Operator's chat.
        case wake
        /// Sending the answer to an Operator tool call back through the helper.
        case reply
        /// Writing the Operator's activity log.
        case activity
        /// Keeping the Operator's session open, fresh and adopted.
        case session

        /// AiTerm tries again by itself, so one failure is not yet the person's to act on.
        public var retried: Bool { [.wake, .reply, .activity, .session].contains(self) }
        public var label: String {
            switch self {
            case .wake: "Waking the Operator"
            case .reply: "Answering the Operator"
            case .activity: "The Operator's activity log"
            case .session: "The Operator's session"
            }
        }
    }
    public struct Issue: Codable, Equatable, Sendable {
        public var source: Source
        public var text: String
        /// The first failure of this streak.
        public var since: Date
        /// Failures in a row.
        public var attempts: Int
        public var needsYou: Bool { !source.retried || attempts >= OperatorIssues.attemptsBeforeAttention }
        public init(source: Source, text: String, since: Date, attempts: Int) {
            self.source = source; self.text = text; self.since = since; self.attempts = attempts
        }
        private enum Keys: String, CodingKey { case source, text, since, attempts, needsYou }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            source = try c.decode(Source.self, forKey: .source); text = try c.decode(String.self, forKey: .text)
            since = try c.decode(Date.self, forKey: .since); attempts = try c.decode(Int.self, forKey: .attempts)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(source, forKey: .source); try c.encode(text, forKey: .text); try c.encode(since, forKey: .since)
            try c.encode(attempts, forKey: .attempts); try c.encode(needsYou, forKey: .needsYou)
        }
        /// "<source>: <text>", as the row's tooltip and the activity log say it.
        public var sentence: String { source.label + ": " + text }
    }
    /// What to write to the activity log: a streak starting, its reason changing, or its recovery.
    public enum Transition: Equatable, Sendable { case started(Issue), changed(Issue), recovered(Issue) }

    public static let attemptsBeforeAttention = 3
    private var bySource: [Source: Issue] = [:]
    public init() {}

    @discardableResult public mutating func fail(_ source: Source, _ text: String, at: Date) -> Transition? {
        guard var issue = bySource[source] else {
            let issue = Issue(source: source, text: text, since: at, attempts: 1)
            bySource[source] = issue; return .started(issue)
        }
        issue.attempts += 1
        let changed = issue.text != text
        issue.text = text; bySource[source] = issue
        return changed ? .changed(issue) : nil
    }
    @discardableResult public mutating func succeed(_ source: Source, at: Date) -> Transition? {
        bySource.removeValue(forKey: source).map(Transition.recovered)
    }
    /// Every current issue, oldest first.
    public var current: [Issue] { bySource.values.sorted { ($0.since, $0.source.rawValue) < ($1.since, $1.source.rawValue) } }
    /// The oldest issue that needs the person, if any.
    public var attention: Issue? { current.first(where: \.needsYou) }
}
