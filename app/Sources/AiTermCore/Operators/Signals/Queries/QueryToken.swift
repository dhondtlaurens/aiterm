import Foundation

/// A query refused before it runs: the token at fault (empty when something is missing) and one plain sentence.
public struct QueryRefusal: Error, Equatable, Sendable, LocalizedError {
    public var token: String, message: String
    public init(token: String, message: String) { self.token = token; self.message = message }
    public var errorDescription: String? { message }
}

/// One whitespace-separated token of a search-bar query: `key:value`, the value possibly quoted
/// (`label:"needs review"`), a leading `-` negating it. A token with no key is free text.
struct QueryToken: Equatable, Sendable {
    /// As written, with its sign and quotes.
    var raw: String
    var negated: Bool
    /// Lowercased; nil for free text.
    var key: String?
    /// Without its quotes.
    var value: String
    var quoted: Bool

    static func split(_ text: String) throws -> [QueryToken] {
        var tokens: [QueryToken] = [], current = "", quoting = false
        for character in text {
            if character == "\"" { quoting.toggle() }
            if character.isWhitespace && !quoting {
                if !current.isEmpty { tokens.append(QueryToken(current)); current = "" }
            } else {
                current.append(character)
            }
        }
        if quoting { throw QueryRefusal(token: current, message: "Close the quote in \(current).") }
        if !current.isEmpty { tokens.append(QueryToken(current)) }
        return tokens
    }

    private init(_ raw: String) {
        self.raw = raw
        negated = raw.count > 1 && raw.hasPrefix("-")
        let body = negated ? String(raw.dropFirst()) : raw
        if let colon = body.firstIndex(of: ":"), !body[..<colon].isEmpty, !body[..<colon].contains("\"") {
            key = body[..<colon].lowercased()
            var value = String(body[body.index(after: colon)...])
            quoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
            if quoted { value = String(value.dropFirst().dropLast()) }
            self.value = value
        } else {
            key = nil; value = body; quoted = false
        }
    }
}

/// An AiTerm-only `threads:` token: decided from a request's review threads, never sent to the host.
public struct ThreadFilter: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// An unresolved thread whose last author is known and is not the account.
        case waitingOnMe = "waiting-on-me"
        /// No unresolved thread.
        case resolved
    }
    public var kind: Kind, negated: Bool
    public init(kind: Kind, negated: Bool = false) { self.kind = kind; self.negated = negated }

    init(_ token: QueryToken) throws {
        guard let kind = Kind(rawValue: token.value.lowercased()) else {
            throw QueryRefusal(token: token.raw, message: "threads takes waiting-on-me or resolved.")
        }
        self.init(kind: kind, negated: token.negated)
    }

    func holds(on threads: [ReviewThread], user: String) -> Bool {
        let open = threads.filter { !$0.resolved }
        let found: Bool
        switch kind {
        // An unknown author is not evidence that someone else spoke.
        case .waitingOnMe: found = open.contains { $0.lastAuthor.map { $0.caseInsensitiveCompare(user) != .orderedSame } == true }
        case .resolved: found = open.isEmpty
        }
        return found != negated
    }
}
