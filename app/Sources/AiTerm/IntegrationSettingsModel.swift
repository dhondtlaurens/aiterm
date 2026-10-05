import Foundation
import SwiftUI
import AiTermCore

/// A service's Settings fields as typed, and what they add up to.
protocol ServiceFields: Equatable {
    associatedtype Config: Equatable & Sendable
    /// The connection these fields describe, or `nil` while the URL has no host.
    var config: Config? { get }
    /// Enough to test: a URL with a host and every credential filled in.
    var isConfigured: Bool { get }
    /// Anything typed at all, the untouched `https://` aside. Blank fields save nothing; anything
    /// else must make a valid connection to save.
    var hasInput: Bool { get }
    /// The fields for `config`; for `nil`, as a card with nothing saved opens.
    init(_ config: Config?)
}

/// What the URL field starts on, so the person types only the host.
private let urlPrefix = "https://"

private func typed(_ values: [String]) -> Bool {
    values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct JiraFields: ServiceFields {
    var site: String, email: String, token: String

    init(_ config: JiraConfig?) {
        site = config?.siteURL.absoluteString ?? urlPrefix
        email = config?.email ?? ""
        token = config?.token ?? ""
    }

    var config: JiraConfig? { URL(string: site).flatMap { $0.host == nil ? nil : JiraConfig(siteURL: $0, email: email, token: token) } }
    var isConfigured: Bool { config != nil && !email.isEmpty && !token.isEmpty }
    var hasInput: Bool { typed([site == urlPrefix ? "" : site, email, token]) }
}

struct GitLabFields: ServiceFields {
    var host: String, token: String

    init(_ config: GitLabConfig?) {
        host = config?.hostURL.absoluteString ?? urlPrefix
        token = config?.token ?? ""
    }

    var config: GitLabConfig? { URL(string: host).flatMap { $0.host == nil ? nil : GitLabConfig(hostURL: $0, token: token) } }
    var isConfigured: Bool { config != nil && !token.isEmpty }
    var hasInput: Bool { typed([host == urlPrefix ? "" : host, token]) }
}

/// GitHub is github.com only: the token is the whole connection, so there is no URL to get wrong.
struct GitHubFields: ServiceFields {
    var token: String

    init(_ config: GitHubConfig?) { token = config?.token ?? "" }

    var config: GitHubConfig? { GitHubConfig(token: token.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var isConfigured: Bool { !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasInput: Bool { typed([token]) }
}

/// Whether each saved service's last connection test failed, which the tab Settings opens on reads.
/// Held for the app's run: every opening tests again anyway, so this only has to outlive one
/// presentation of the sheet until the next.
@MainActor
final class ServiceTestRecord {
    static let shared = ServiceTestRecord()
    var jiraFailed = false
    var gitLabFailed = false
    var gitHubFailed = false
    var anyFailed: Bool { jiraFailed || gitLabFailed || gitHubFailed }
}

extension ConnectionTest {
    var failed: Bool { if case .failed = self { true } else { false } }
}

/// One service's card: its fields and the answer of its last connection test. The test runs when
/// Settings opens and again once the fields stop changing; there is no Test button.
@MainActor
final class ServiceConnection<Fields: ServiceFields>: ObservableObject {
    /// An edit clears the card's answer and, once typing pauses for `retestDelay`, tests again.
    @Published var fields: Fields {
        didSet { if fields != oldValue { edited() } }
    }
    @Published private(set) var test: ConnectionTest?
    /// Disconnect was pressed: Save removes the saved credentials unless new ones are typed in.
    @Published private(set) var disconnecting = false
    /// Settings opened on credentials saved earlier — what Disconnect removes.
    let isSaved: Bool
    /// What the card says when the URL has no host.
    let invalidURL: String
    /// Hears every answer a test lands, with the fields it was for.
    var answered: ((Fields.Config, ConnectionTest) -> Void)?
    private let connect: @Sendable (Fields.Config) async throws -> String
    private let retestDelay: Duration
    private var retest: Task<Void, Never>?

    init(fields: Fields, isSaved: Bool, invalidURL: String, retestDelay: Duration,
         connect: @escaping @Sendable (Fields.Config) async throws -> String) {
        self.fields = fields; self.isSaved = isSaved; self.invalidURL = invalidURL
        self.retestDelay = retestDelay; self.connect = connect
    }

    var status: SettingsStatus { IntegrationCardPresentation.status(configured: fields.isConfigured, test: test) }

    /// Offered while the card holds credentials saved earlier and Disconnect has not been pressed.
    var canDisconnect: Bool { isSaved && !disconnecting }

    /// Empties the card and marks the service for removal. Nothing is removed until Save, so
    /// Cancel keeps everything.
    func disconnect() {
        fields = Fields(nil)
        disconnecting = true
    }

    func runTest() {
        guard let config = fields.config else { test = .failed(invalidURL); return }
        test = .running
        Task {
            let outcome: ConnectionTest
            do { outcome = .connected(try await connect(config)) }
            catch { outcome = .failed(error.localizedDescription) }
            // An edit during the test cleared the card; the answer is for fields no longer shown.
            if test == .running, fields.config == config {
                test = outcome
                answered?(config, outcome)
            }
        }
    }

    /// The opening test has already set an answer by the time a retest could wake, so a card is
    /// never tested twice for the same fields. Held weakly: Settings closed meanwhile tests nothing.
    private func edited() {
        test = nil
        retest?.cancel()
        retest = Task { [weak self, retestDelay] in
            try? await Task.sleep(for: retestDelay)
            guard !Task.isCancelled, let self, self.test == nil, self.fields.isConfigured else { return }
            self.runTest()
        }
    }
}

/// Owns the Integrations tab: the Jira, GitLab and GitHub fields as typed, each card's connection test,
/// and the Keychain writes Save makes. The view renders the connections and starts these actions,
/// as `HarnessSettingsModel` does for the Agents tab.
@MainActor
final class IntegrationSettingsModel: ObservableObject {
    let jira: ServiceConnection<JiraFields>
    let gitLab: ServiceConnection<GitLabFields>
    let gitHub: ServiceConnection<GitHubFields>
    private let store: SecretStore
    private let defaults: UserDefaults
    private let record: ServiceTestRecord
    /// What is saved now: only a test of these counts as a saved service's last test.
    private var savedJira: JiraConfig?
    private var savedGitLab: GitLabConfig?
    private var savedGitHub: GitHubConfig?

    /// `store` and `defaults` are where Save writes; the testers are the real clients unless a test
    /// stands in for them.
    init(jira: JiraConfig?, gitLab: GitLabConfig?, gitHub: GitHubConfig? = nil, store: SecretStore = Keychain.shared, defaults: UserDefaults = .standard,
         record: ServiceTestRecord = ServiceTestRecord(), retestDelay: Duration = .seconds(1),
         testJira: @escaping @Sendable (JiraConfig) async throws -> String = { try await JiraClient(config: $0).testConnection() },
         testGitLab: @escaping @Sendable (GitLabConfig) async throws -> String = { try await GitLabClient(config: $0).testConnection() },
         testGitHub: @escaping @Sendable (GitHubConfig) async throws -> String = { try await GitHubClient(config: $0).testConnection() }) {
        self.jira = ServiceConnection(fields: JiraFields(jira), isSaved: jira != nil, invalidURL: "Enter a valid Jira site URL",
                                      retestDelay: retestDelay, connect: testJira)
        self.gitLab = ServiceConnection(fields: GitLabFields(gitLab), isSaved: gitLab != nil, invalidURL: "Enter a valid GitLab host URL",
                                        retestDelay: retestDelay, connect: testGitLab)
        self.gitHub = ServiceConnection(fields: GitHubFields(gitHub), isSaved: gitHub != nil, invalidURL: "Enter a GitHub access token",
                                        retestDelay: retestDelay, connect: testGitHub)
        self.store = store; self.defaults = defaults; self.record = record
        savedJira = jira; savedGitLab = gitLab; savedGitHub = gitHub
        self.jira.answered = { [weak self] config, outcome in
            guard let self, config == self.savedJira else { return }
            self.record.jiraFailed = outcome.failed
        }
        self.gitLab.answered = { [weak self] config, outcome in
            guard let self, config == self.savedGitLab else { return }
            self.record.gitLabFailed = outcome.failed
        }
        self.gitHub.answered = { [weak self] config, outcome in
            guard let self, config == self.savedGitHub else { return }
            self.record.gitHubFailed = outcome.failed
        }
    }

    /// A result is only true for the moment it was taken, so every opening tests each saved service
    /// again rather than showing a remembered answer.
    func testConfigured() {
        if jira.fields.isConfigured { jira.runTest() }
        if gitLab.fields.isConfigured { gitLab.runTest() }
        if gitHub.fields.isConfigured { gitHub.runTest() }
    }

    /// Stores every service with anything typed, Jira first, and removes every service
    /// disconnected and left blank. `nil` when all of it was done; else what stopped it, for the
    /// sheet's footer. Both are optional, so blank fields store nothing.
    func save() -> String? {
        if jira.fields.hasInput {
            guard let config = jira.fields.config else { return jira.invalidURL }
            guard JiraSettings.save(config, store: store, defaults: defaults) else { return "Couldn’t save the API token to the Keychain" }
            savedJira = config
            record.jiraFailed = jira.test?.failed == true
        } else if jira.disconnecting {
            guard JiraSettings.save(nil, store: store, defaults: defaults) else { return "Couldn’t remove the API token from the Keychain" }
            savedJira = nil
            record.jiraFailed = false
        }
        if gitLab.fields.hasInput {
            guard let config = gitLab.fields.config else { return gitLab.invalidURL }
            guard GitLabSettings.save(config, store: store, defaults: defaults) else { return "Couldn’t save the GitLab token to the Keychain" }
            savedGitLab = config
            record.gitLabFailed = gitLab.test?.failed == true
        } else if gitLab.disconnecting {
            guard GitLabSettings.save(nil, store: store, defaults: defaults) else { return "Couldn’t remove the GitLab token from the Keychain" }
            savedGitLab = nil
            record.gitLabFailed = false
        }
        if gitHub.fields.isConfigured {
            guard let config = gitHub.fields.config else { return gitHub.invalidURL }
            guard GitHubSettings.save(config, store: store) else { return "Couldn’t save the GitHub token to the Keychain" }
            savedGitHub = config
            record.gitHubFailed = gitHub.test?.failed == true
        } else if gitHub.disconnecting {
            guard GitHubSettings.save(nil, store: store) else { return "Couldn’t remove the GitHub token from the Keychain" }
            savedGitHub = nil
            record.gitHubFailed = false
        }
        return nil
    }
}
