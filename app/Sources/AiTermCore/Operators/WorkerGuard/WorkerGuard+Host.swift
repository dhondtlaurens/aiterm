import Foundation

extension WorkerGuard {
    public struct Fence: Sendable {
        public var defaultBranch: String
        public var protection: BranchProtection
        public init(defaultBranch: String, protection: BranchProtection) { self.defaultBranch = defaultBranch; self.protection = protection }
    }
    /// Credentials stay in this process, and only the connected host is contacted. No cached
    /// branch list can authorize a push after the host changes its default or protection rules.
    public static func liveFence(_ scope: Scope) async throws -> Fence {
        let configurations = await ThreadWork.run {
            let secrets = ReadOnlyKeychain()
            let defaults = UserDefaults(suiteName: "com.laurensdhondt.aiterm") ?? .standard
            return (GitLabSettings.load(store: secrets, defaults: defaults), GitHubSettings.load(store: secrets))
        }
        let remote = ProviderDetector.detect(remoteUrl: scope.remote)
        let host = try CodeHosts.repository(for: remote, gitLab: configurations.0, gitHub: configurations.1)
        async let branch = host.defaultBranch()
        async let protection = host.protection(of: scope.branch)
        return try await Fence(defaultBranch: branch, protection: protection)
    }
}
