import Foundation

/// The service a release, a merge request or a pull request lives on, as copy names it. GitLab is
/// every host that is not github.com: it is the only other one AiTerm reads.
public enum CodeHost: String, Sendable, Equatable {
    case gitLab = "GitLab", gitHub = "GitHub"

    public var name: String { rawValue }

    /// Judged by the web URL a merge or pull request was stored with, so a saved review needs no
    /// field of its own to say where it came from.
    public init(webURL: String) {
        self = URL(string: webURL)?.host?.lowercased() == "github.com" ? .gitHub : .gitLab
    }

    /// How the host writes a request's number: GitLab `!87`, GitHub `#87`.
    public func reference(_ number: Int) -> String { (self == .gitHub ? "#" : "!") + String(number) }
}
