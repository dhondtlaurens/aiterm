import Foundation

/// GitHub is github.com only, so the token is the whole connection: nothing goes in defaults.
public enum GitHubSettings {
    public static func load(store: SecretStore = Keychain.shared) -> GitHubConfig? {
        guard let token = store.get("github.token")?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return GitHubConfig(token: token)
    }

    @discardableResult
    public static func save(_ cfg: GitHubConfig?, store: SecretStore = Keychain.shared) -> Bool {
        let saved = store.set("github.token", cfg?.token)
        if saved { HostUserMemo.invalidate(.gitHub) }
        return saved
    }
}
