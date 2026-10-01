import Foundation

/// The build's update source, from its `AiTermUpdateFeed` Info.plist value: `github:<owner>/<repo>`,
/// or `gitlab:<project URL>` such as `gitlab:https://git.example.net/ai/aiterm`.
public enum ReleaseFeed: Equatable, Sendable {
    case gitHub(owner: String, repo: String)
    case gitLab(host: URL, project: String)

    public init?(_ text: String) {
        if text.hasPrefix("github:") {
            var path = String(text.dropFirst("github:".count))
            if path.hasSuffix(".git") { path.removeLast(4) }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
            self = .gitHub(owner: String(parts[0]), repo: String(parts[1]))
            return
        }
        guard text.hasPrefix("gitlab:"), let url = URL(string: String(text.dropFirst("gitlab:".count))),
              let scheme = url.scheme, let hostName = url.host else { return nil }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.contains("/"), let host = URL(string: "\(scheme)://\(hostName)" + (url.port.map { ":\($0)" } ?? "")) else { return nil }
        self = .gitLab(host: host, project: path)
    }

    /// A GitHub feed is public and takes no token. A GitLab feed's token is the one Settings saved
    /// for reviews, so it is offered only when Settings names the feed's own server: the feed comes
    /// from the build, the token from whatever GitLab the user set up, and a token minted for one
    /// server must never be sent to another.
    public func source(secrets: SecretStore, defaults: UserDefaults = .standard, session: URLSession = .shared) throws -> any ReleaseSource {
        switch self {
        case .gitHub(let owner, let repo):
            return GitHubReleaseSource(owner: owner, repo: repo, session: session)
        case .gitLab(let host, let project):
            guard let settings = GitLabSettings.load(store: secrets, defaults: defaults) else { throw UpdateError.noToken }
            let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw UpdateError.noToken }
            guard settings.hostURL.comparableHost == host.comparableHost, settings.hostURL.comparablePort == host.comparablePort else {
                throw UpdateError.tokenForOtherHost(Self.hostName(settings.hostURL), feed: Self.hostName(host))
            }
            return GitLabReleaseSource(host: host, project: project, token: token, session: session)
        }
    }

    /// `text` is the running bundle's feed value: `nil` under `swift run`, which has no Info.plist.
    public static func source(for text: String?, secrets: SecretStore, defaults: UserDefaults = .standard) throws -> any ReleaseSource {
        guard let text, let feed = ReleaseFeed(text) else { throw UpdateError.noFeed }
        return try feed.source(secrets: secrets, defaults: defaults)
    }

    private static func hostName(_ url: URL) -> String {
        (url.comparableHost ?? url.absoluteString) + (url.comparablePort.map { ":\($0)" } ?? "")
    }
}
