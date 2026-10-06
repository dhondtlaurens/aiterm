import Foundation
import Security

public protocol SecretStore {
    func get(_ key: String) -> String?
    /// `false` when the secret could not be stored, so a caller can say so instead of silently
    /// losing the token.
    @discardableResult func set(_ key: String, _ value: String?) -> Bool
}

public final class MemorySecretStore: SecretStore {
    var values: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { values[key] }
    @discardableResult public func set(_ key: String, _ value: String?) -> Bool { values[key] = value; return true }
}

public final class Keychain: SecretStore {
    let service: String
    public init(service: String = "com.laurensdhondt.aiterm") { self.service = service }
    private func query(_ key: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] }

    public func get(_ key: String) -> String? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Updates in place when the item exists and adds it otherwise, rather than deleting first: a
    /// delete that succeeds followed by an add that fails would throw the secret away.
    @discardableResult
    public func set(_ key: String, _ value: String?) -> Bool {
        guard let value else {
            let status = SecItemDelete(query(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var q = query(key); q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
