import Foundation

extension WorkerGuard {
    /// A full object name: 40 or 64 ASCII hexadecimal digits.
    static func isFullCommit(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && isASCIIHex(text)
    }

    private static func isASCIIHex(_ text: String) -> Bool {
        text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

    /// Whether two remote URLs name the same host and path (`RemoteURL.location`), whatever the scheme,
    /// user, port, a trailing `.git` or slash, or case: `https://host/a/b.git` and `git@host:a/b`. A
    /// local path has no host.
    static func sameLocation(_ a: String, _ b: String) -> Bool {
        func parts(_ url: String) -> (host: String, path: String) {
            let location = RemoteURL.location(of: url)
            return (folded(location.host), folded(location.path))
        }
        return parts(a) == parts(b)
    }

    /// `name` without a leading `refs/heads/`: `refs/heads/main` names the default branch's own ref.
    static func shortBranch(_ name: String) -> String {
        name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }

    /// `name` compared the way a case-insensitive or normalising file system or host would.
    static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }
}
