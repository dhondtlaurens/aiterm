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

    func reader(for source: SignalSource) throws -> any SignalSourceReader {
        switch source {
        case .jira(let conditions):
            guard let jira else { throw ActionUnavailable("Connect Jira in Settings to watch this signal.") }
            return JiraQueryReader(client: JiraClient(config: jira, session: session), conditions: conditions)
        case .gitLab(let conditions):
            guard let gitLab else { throw ActionUnavailable("Connect GitLab in Settings to watch this signal.") }
            let account = GitLabAccount(config: gitLab, session: session)
            if conditions.event == .reviewRequested { return ReviewRequestedReader(account: account, projects: conditions.projects) }
            return MyRequestReader(account: account, conditions: conditions)
        case .gitHub(let conditions):
            guard let gitHub else { throw ActionUnavailable("Connect GitHub in Settings to watch this signal.") }
            let account = GitHubAccount(config: gitHub, session: session)
            if conditions.event == .reviewRequested { return ReviewRequestedReader(account: account, projects: conditions.projects) }
            return MyRequestReader(account: account, conditions: conditions)
        case .unknown: throw ActionUnavailable("This signal's source is not supported by this version.")
        }
    }
    @MainActor func registrations(for signals: [Signal]) -> [SignalPoller.Registration] {
        signals.filter(\.isRunnable).map { signal in
            let isJira: Bool, host: String, token: String, query: String
            switch signal.source {
            case .jira(let value):
                isJira = true; host = "jira:" + (jira?.siteURL.absoluteString ?? "disconnected")
                token = jira?.token ?? ""; query = JQL.compile(value)
            case .gitLab:
                isJira = false; host = "gitlab:" + (gitLab?.hostURL.absoluteString ?? "disconnected")
                token = gitLab?.token ?? ""; query = Self.key(signal.source)
            case .gitHub:
                isJira = false; host = "github:github.com"; token = gitHub?.token ?? ""; query = Self.key(signal.source)
            case .unknown:
                isJira = false; host = "unsupported"; token = ""; query = ""
            }
            let reader: any SignalSourceReader
            do { reader = try self.reader(for: signal.source) }
            catch { reader = UnavailableReader(reason: OperationIssue.reason(of: error)) }
            return SignalPoller.Registration(id: signal.id, sourceHost: host,
                readKey: Self.hash(token + "\n" + (jira?.email ?? "") + "\n" + query), isJira: isJira, reader: reader)
        }
    }
    private static func key(_ source: SignalSource) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(source)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
private struct UnavailableReader: SignalSourceReader {
    var reason: String
    func poll(since: Date?, full: Bool) async throws -> SignalRead { throw ActionUnavailable(reason) }
}
