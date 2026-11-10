import Foundation

/// Where a git remote URL points: its host and the path on it, read the one way every caller reads
/// one — the provider a project's remote is on (`ProviderDetector`), and whether a push goes where
/// origin is fetched from (`Repository.sameLocation`).
///
/// A URL with a scheme (`https://`, `ssh://`, `file://`), a scp-like `user@host:path`, or a local
/// path. The user and the port are dropped and the host lowercased; the path loses its leading and
/// trailing slashes and a trailing `.git`, and is percent-decoded. A local path has no host.
public struct RemoteURL: Equatable, Sendable {
    public var host: String?
    public var path: String
    /// A local path that does not start at the root: git reads it from the repository it is
    /// configured in, so it is not the same place as the absolute path with the same words.
    public var isRelative: Bool

    /// `nil` for an empty URL, or one of whitespace.
    public init?(_ raw: String?) {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        var host: String? = nil, path = s, relative = false
        if let range = s.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) {
            var rest = String(s[range.upperBound...])
            if let at = rest.lastIndex(of: "@"), !rest[..<at].contains("/") { rest = String(rest[rest.index(after: at)...]) }
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var hostPort = String(rest[..<slash])
            if let colon = hostPort.lastIndex(of: ":") { hostPort = String(hostPort[..<colon]) }
            host = hostPort.isEmpty ? nil : hostPort.lowercased()
            path = slash < rest.endIndex ? String(rest[rest.index(after: slash)...]) : ""
        } else if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {   // scp-like
            var hostPart = String(s[..<colon])
            if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
            host = hostPart.lowercased()
            path = String(s[s.index(after: colon)...])
        } else {
            relative = !s.hasPrefix("/")
        }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        self.host = host
        self.path = path.removingPercentEncoding ?? path
        isRelative = relative
    }
}
