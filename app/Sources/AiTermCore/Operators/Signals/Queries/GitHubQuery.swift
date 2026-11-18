import Foundation

/// A GitHub trigger's query in GitHub's search syntax. AiTerm takes off its own `threads:` tokens and makes it a
/// pull request search; GitHub validates the rest itself.
public struct GitHubQuery: Equatable, Sendable {
    /// The search text sent to GitHub.
    public var text: String
    public var threads: [ThreadFilter]

    /// A Start query lists open pull requests unless it states otherwise.
    public static func start(_ text: String) throws -> GitHubQuery { try normalised(text, start: true) }
    public static func done(_ text: String) throws -> GitHubQuery { try normalised(text, start: false) }

    private static func normalised(_ text: String, start: Bool) throws -> GitHubQuery {
        var kept: [QueryToken] = [], threads: [ThreadFilter] = []
        for token in try QueryToken.split(text) {
            if token.key == "threads" { threads.append(try ThreadFilter(token)); continue }
            if token.key == "is", !token.negated, token.value.lowercased() == "issue" {
                throw QueryRefusal(token: token.raw, message: "A GitHub trigger lists pull requests; remove is:issue.")
            }
            kept.append(token)
        }
        func states(_ token: QueryToken) -> Bool {
            token.key == "state" || (token.key == "is" && ["open", "closed", "merged"].contains(token.value.lowercased()))
        }
        var words = kept.map(\.raw)
        if start && !kept.contains(where: states) { words.insert("is:open", at: 0) }
        if !kept.contains(where: { $0.key == "is" && !$0.negated && $0.value.lowercased() == "pr" }) { words.insert("is:pr", at: 0) }
        return GitHubQuery(text: words.joined(separator: " "), threads: threads)
    }
}
