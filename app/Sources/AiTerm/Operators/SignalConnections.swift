import Foundation
import CryptoKit
import AiTermCore

/// The same readers drive the match preview and deterministic polling. Credentials never enter
/// durable state or status; their hash only invalidates a read after Settings changes.
struct SignalConnections: Sendable {
    var jira: JiraConfig?
    var gitLab: GitLabConfig?
    var gitHub: GitHubConfig?
    var session: URLSession = .shared

    /// The reader a trigger's query runs through as a Start trigger: every item it lists.
    func reader(for trigger: SignalTrigger) throws -> any SignalSourceReader {
        switch trigger.source {
        case .jira:
            guard let jira else { throw ActionUnavailable("Connect Jira in Settings to watch this signal.") }
            return JiraQueryReader(client: JiraClient(config: jira, session: session), jql: trigger.query)
        case .gitLab:
            guard let gitLab else { throw ActionUnavailable("Connect GitLab in Settings to watch this signal.") }
            return GitLabQueryReader(query: try GitLabQuery.start(trigger.query), account: GitLabAccount(config: gitLab, session: session))
        case .gitHub:
            guard let gitHub else { throw ActionUnavailable("Connect GitHub in Settings to watch this signal.") }
            return GitHubQueryReader(query: try GitHubQuery.start(trigger.query), account: GitHubAccount(config: gitHub, session: session))
        case .schedule, .operator: throw ActionUnavailable("A schedule or the Operator reads no host.")
        case .person: throw ActionUnavailable("You decide when it is done: there is no query to read.")
        case .unknown: throw ActionUnavailable("This signal's source is not supported by this version.")
        }
    }
    /// The poller's reads: every runnable signal that starts from items. A schedule is the scheduler's (`SignalScheduler`).
    @MainActor func registrations(for signals: [Signal]) -> [SignalPoller.Registration] {
        signals.filter { $0.isRunnable && $0.start.source.readsItems }.map { signal in
            let host: String, token: String
            switch signal.start.source {
            case .jira: host = "jira:" + (jira?.siteURL.absoluteString ?? "disconnected"); token = jira?.token ?? ""
            case .gitLab: host = "gitlab:" + (gitLab?.hostURL.absoluteString ?? "disconnected"); token = gitLab?.token ?? ""
            case .gitHub: host = "github:github.com"; token = gitHub?.token ?? ""
            case .schedule, .operator, .person, .unknown: host = "unsupported"; token = ""
            }
            let reader: any SignalSourceReader
            do { reader = try self.reader(for: signal.start) }
            catch { reader = UnavailableReader(reason: OperationIssue.reason(of: error)) }
            let query = signal.start.source.rawValue + "\n" + signal.start.query
            return SignalPoller.Registration(id: signal.id, sourceHost: host,
                readKey: Self.hash(token + "\n" + (jira?.email ?? "") + "\n" + query), isJira: signal.start.source == .jira, reader: reader)
        }
    }
    private static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
private struct UnavailableReader: SignalSourceReader {
    var reason: String
    func poll(since: Date?, full: Bool) async throws -> SignalRead { throw ActionUnavailable(reason) }
}
