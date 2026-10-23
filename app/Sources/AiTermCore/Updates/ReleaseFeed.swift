import Foundation

/// The build's public GitHub update source, from its AiTermUpdateFeed Info.plist value.
public enum ReleaseFeed: Equatable, Sendable {
    case gitHub(owner: String, repo: String)

    public init?(_ text: String) {
        guard text.hasPrefix("github:") else { return nil }
        var path = String(text.dropFirst("github:".count))
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        self = .gitHub(owner: String(parts[0]), repo: String(parts[1]))
    }

    public func source(session: URLSession = .shared) -> any ReleaseSource {
        switch self {
        case .gitHub(let owner, let repo): return GitHubReleaseSource(owner: owner, repo: repo, session: session)
        }
    }

    /// Nil under swift run, which has no bundle feed.
    public static func source(for text: String?) throws -> any ReleaseSource {
        guard let text, let feed = ReleaseFeed(text) else { throw UpdateError.noFeed }
        return feed.source()
    }
}
