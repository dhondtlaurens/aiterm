import Foundation

/// The reads of a signal's source that are failing, one issue per signal, in memory only. Every failure counts, whatever
/// its reason; a good read clears the signal's issue. A signal's icon shows an issue from its first failure, and the
/// banner is raised once per streak, at its third failure in a row (`attemptsBeforeBanner`). An Operator signal's
/// failure is also saved for the Operator (`OperatorSession.sourceFailures`); this record is the person's.
public struct SignalReadIssues: Equatable, Sendable {
    public struct Issue: Equatable, Sendable {
        public var signal: UUID
        /// The latest failure's reason.
        public var text: String
        /// The first failure of this streak.
        public var since: Date
        /// The latest failure, which the next try is counted from.
        public var last: Date
        /// Failures in a row.
        public var attempts: Int
        /// Whether this streak's banner was raised.
        public var raised: Bool
        public init(signal: UUID, text: String, since: Date, attempts: Int, raised: Bool = false, last: Date? = nil) {
            self.signal = signal; self.text = text; self.since = since; self.attempts = attempts; self.raised = raised
            self.last = last ?? since
        }
    }

    public static let attemptsBeforeBanner = 3
    private var bySignal: [UUID: Issue] = [:]
    public init() {}

    /// Counts a failed read of `signal`'s source. True when this failure raises the streak's banner: the third in a row,
    /// once per streak.
    @discardableResult public mutating func fail(_ signal: UUID, _ text: String, at: Date) -> Bool {
        var issue = bySignal[signal] ?? Issue(signal: signal, text: text, since: at, attempts: 0)
        issue.attempts += 1
        issue.text = text
        issue.last = at
        let raises = !issue.raised && issue.attempts >= Self.attemptsBeforeBanner
        if raises { issue.raised = true }
        bySignal[signal] = issue
        return raises
    }
    /// A good read of `signal`'s source: its issue, cleared, or nil when it had none. A cleared issue that was `raised`
    /// takes its banner down.
    @discardableResult public mutating func succeed(_ signal: UUID) -> Issue? {
        bySignal.removeValue(forKey: signal)
    }
    /// Drops the issues of every signal not in `signals` (removed, or switched off and no longer read), and returns them:
    /// a raised one's banner goes with it.
    @discardableResult public mutating func prune(keeping signals: Set<UUID>) -> [Issue] {
        let gone = bySignal.values.filter { !signals.contains($0.signal) }
        for issue in gone { bySignal[issue.signal] = nil }
        return gone.sorted { ($0.since, $0.signal.uuidString) < ($1.since, $1.signal.uuidString) }
    }
    /// `signal`'s issue, if its reads are failing.
    public func issue(for signal: UUID) -> Issue? { bySignal[signal] }
    /// Every current issue, oldest first.
    public var current: [Issue] {
        bySignal.values.sorted { ($0.since, $0.signal.uuidString) < ($1.since, $1.signal.uuidString) }
    }

    /// What the icon's hover and the banner's title say of a failing source: "“Reviews for me” can’t read GitLab."
    public static func sentence(name: String, source: String) -> String {
        "“" + name + "” can’t read " + source + "."
    }

    /// When the next read is tried, as the banner and the signals sheet say it: "AiTerm tries again at 14:05.", in
    /// 24-hour local time on `calendar`, with the weekday when it is not on `from`'s day.
    public static func retry(at: Date, from: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(at, inSameDayAs: from) ? "HH:mm" : "EEEE HH:mm"
        return "AiTerm tries again at " + formatter.string(from: at) + "."
    }

    /// An error and the retry after it, as one or two sentences: "The server answered 401. AiTerm tries again at 14:05."
    public static func reason(_ error: String, retry: String) -> String {
        let error = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = error.last else { return retry }
        return error + (".!?…".contains(last) ? " " : ". ") + retry
    }

    /// The retry time of `issue`: its latest failure plus `backOff` (`SignalPoller.failureBackOff`).
    public static func retry(after issue: Issue, backOff: TimeInterval, calendar: Calendar = .autoupdatingCurrent) -> String {
        retry(at: issue.last + backOff, from: issue.last, calendar: calendar)
    }
}
