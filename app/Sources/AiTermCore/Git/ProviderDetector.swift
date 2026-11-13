import Foundation

public struct RemoteInfo: Equatable, Sendable {
    public var host: String?
    public var path: String
    public var provider: Provider
}

public enum ProviderDetector {
    public static func detect(remoteUrl raw: String?, repoPath: String? = nil) -> RemoteInfo {
        guard let url = RemoteURL(raw) else {
            return RemoteInfo(host: nil, path: "", provider: repoPath.map { looksLikeGitLabCheckout($0) ? .gitlab : .git } ?? .none)
        }
        return RemoteInfo(host: url.host, path: url.path, provider: classify(host: url.host, path: url.path, repoPath: repoPath))
    }

    static func classify(host: String?, path: String, repoPath: String?) -> Provider {
        // github.com first: its paths never have subgroups, and a mirror's `.gitlab-ci.yml` does
        // not make it GitLab's. `ssh.github.com` is git over SSH on port 443.
        if let host, host == "github.com" || host == "ssh.github.com" { return .github }
        // Hosts known not to be GitLab, before the heuristics below take them for it: a `git.` name
        // (SourceHut, kernel.org) or a deep path (Azure DevOps: `org/project/_git/repo`).
        if let host, isKnownNotGitLab(host) { return .git }
        if let host, host == "gitlab.com" || host.hasPrefix("git.") || host.hasPrefix("gitlab.") { return .gitlab }
        // The subgroup rule only applies when the remote actually has a host; a
        // host-less (local filesystem) remote never classifies as GitLab by path shape.
        if host != nil, path.split(separator: "/").count > 2 { return .gitlab }
        if let repoPath, looksLikeGitLabCheckout(repoPath) { return .gitlab }
        return .git
    }

    private static let notGitLab: Set<String> = ["dev.azure.com", "ssh.dev.azure.com", "bitbucket.org", "codeberg.org",
                                                 "git.sr.ht", "git.kernel.org", "git.savannah.gnu.org"]

    private static func isKnownNotGitLab(_ host: String) -> Bool {
        notGitLab.contains(host) || host.hasSuffix(".visualstudio.com")
    }

    static func looksLikeGitLabCheckout(_ repoPath: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoPath + "/.gitlab-ci.yml") || fm.fileExists(atPath: repoPath + "/.gitlab")
    }
}
