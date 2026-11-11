import Foundation

/// Where a git remote URL points: its host and the path on it, read for the provider a project's
/// remote is on (`ProviderDetector`); and, beside it, the reading the push's same-location check
/// compares (`location(of:)`), which differs from it at the edges and keeps its own rule.
///
/// A URL with a scheme (`https://`, `ssh://`, `file://`), a scp-like `user@host:path`, or a local
/// path. The user and the port are dropped and the host lowercased; the path loses its leading and
/// trailing slashes and a trailing `.git`, and is percent-decoded. A local path has no host.
public struct RemoteURL: Equatable, Sendable {
    public var host: String?
    public var path: String

    /// `nil` for an empty URL, or one of whitespace.
    public init?(_ raw: String?) {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        var host: String? = nil, path = s
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
        }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        self.host = host
        self.path = path.removingPercentEncoding ?? path
    }
}

extension RemoteURL {
    /// What `Repository.sameLocation` compares two remote URLs by, before case folding: the host and the
    /// path, whatever the scheme, user, port, a trailing `.git` or slash. It reads a URL as that check
    /// always has, which is not quite the provider's reading above: `://` anywhere starts a host, a
    /// `file:` URL has none, a trailing slash goes before a trailing `.git` and not after (`team/.git`
    /// is `team/`), and a local path keeps its leading slashes. Its path is percent-decoded, as the
    /// provider's is; that is the one difference from the rule before 2026-11-10 (`decodesPath`).
    static func location(of url: String) -> (host: String, path: String) {
        var rest = url, host = ""
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
            if url.hasPrefix("file:") { rest = rest.hasPrefix("/") ? rest : "/" + rest }
            else if let slash = rest.firstIndex(of: "/") { host = String(rest[..<slash]); rest = String(rest[slash...]) }
            else { host = rest; rest = "" }
        } else if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains("/") {
            // scp-like `user@host:path`
            host = String(rest[..<colon]); rest = String(rest[rest.index(after: colon)...])
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        while rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        while rest.hasPrefix("/") && !host.isEmpty { rest.removeFirst() }
        return (host, decodesPath ? rest.removingPercentEncoding ?? rest : rest)
    }

    /// Whether the same-location check percent-decodes a path, as the provider's reading does.
    static let decodesPath = true
}
