import Foundation
import Testing
@testable import AiTermCore

struct RemoteURLTests {
    /// The same-location check's rule before 2026-11-10, kept as it was (`Repository+Publish.swift`'s `parts`, less
    /// its case folding), as the reference `RemoteURL.location(of:)` is held to.
    private static func reference(_ url: String) -> (host: String, path: String) {
        var rest = url, host = ""
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
            if url.hasPrefix("file:") { rest = rest.hasPrefix("/") ? rest : "/" + rest }
            else if let slash = rest.firstIndex(of: "/") { host = String(rest[..<slash]); rest = String(rest[slash...]) }
            else { host = rest; rest = "" }
        } else if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains("/") {
            host = String(rest[..<colon]); rest = String(rest[rest.index(after: colon)...])
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        while rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        while rest.hasPrefix("/") && !host.isEmpty { rest.removeFirst() }
        return (host, rest)
    }

    static let urls = [
        "https://github.com/acme/app.git", "git@github.com:acme/app.git", "https://github.com/acme/app",
        "ssh://git@github.com:22/acme/app.git/", "https://GitHub.com/Acme/App.git", "git@gitlab.com:/acme/app.git",
        "/tmp/a/origin", "file:///tmp/a/origin", "/tmp/a/origin/", "tmp/a/origin", "//tmp/a/origin", "file:relative/origin",
        "git@host:team/.git", "git@host:team", "git@host:team/", "host:team.git/", "https://host", "https://host/",
        "https://user:pass@host:8443/group/sub/repo.git", "ssh://[::1]:22/repo.git", "git@[::1]:repo.git",
        "foo/bar://host/x", "https://ho/st@evil.example/acme/app", " https://github.com/acme/app.git ", "",
        "https://github.com/acme/my%20app.git", "git@host:team/a%2Fb", "/srv/repos/caf%C3%A9.git",
    ]

    /// The check reads every URL as it did before phase 2, a percent-encoded path included: decoding it, as provider
    /// detection does, is the maintainer's to approve (`RemoteURL.decodesPath`).
    @Test(arguments: urls) func theSameLocationRuleIsTodays(url: String) {
        let today = Self.reference(url), now = RemoteURL.location(of: url)
        #expect(now.host == today.host)
        #expect(now.path == today.path)
    }
}
