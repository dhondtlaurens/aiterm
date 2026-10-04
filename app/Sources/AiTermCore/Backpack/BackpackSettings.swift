// app/Sources/AiTermCore/Backpack/BackpackSettings.swift
import Foundation
import Synchronization

/// Backpack Mode's preferences and its crash marker. In `UserDefaults` when given one, as
/// `InterfaceSettings` is; in memory without, for previews and an app built without the live ports.
/// The network's password goes to `secrets` — the Keychain in the app — never to defaults.
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but not marked `Sendable`; the
/// memory copy and every `secrets` call are taken under `lock`. (A `Mutex` cannot hold them: neither
/// `Any` nor a `SecretStore` is `Sendable`.)
public final class BackpackSettings: @unchecked Sendable {
    /// Settings › Backpack's "Turn off below" menu, in percent.
    public static let cutoffChoices = [5, 10, 15, 20, 25, 30]
    public static let defaultCutoff = 10

    private enum Key {
        static let network = "backpack.network"
        static let cutoff = "backpack.batteryCutoff"
        static let engaged = "backpack.engaged"
        static let password = "backpack.password"
    }

    private let defaults: UserDefaults?
    private let secrets: any SecretStore
    private let lock = Mutex(())
    private var memory: [String: Any] = [:]

    public init(defaults: UserDefaults?, secrets: any SecretStore = MemorySecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// The chosen network's password. macOS will not hand an iPhone hotspot's saved password to
    /// another app, so the person types it once. An empty one reads as none.
    public var password: String? {
        get { lock.withLock { _ in secrets.get(Key.password) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { lock.withLock { _ in _ = secrets.set(Key.password, newValue?.isEmpty == false ? newValue : nil) } }
    }

    /// The network to join. An empty name reads as none.
    public var network: String? {
        get { (read(Key.network) as? String).flatMap { $0.isEmpty ? nil : $0 } }
        set { write(newValue, Key.network) }
    }

    /// The battery level, in percent, at or below which the mode turns itself off on battery power.
    /// A value not on the menu reads as the default.
    public var cutoff: Int {
        get { (read(Key.cutoff) as? Int).flatMap { Self.cutoffChoices.contains($0) ? $0 : nil } ?? Self.defaultCutoff }
        set { write(newValue, Key.cutoff) }
    }

    /// Set just before `disablesleep 1` and cleared just after `disablesleep 0`, so a launch after a
    /// crash knows to put sleep back.
    public var engaged: Bool {
        get { read(Key.engaged) as? Bool ?? false }
        set { write(newValue, Key.engaged) }
    }

    private func read(_ key: String) -> Any? {
        if let defaults { return defaults.object(forKey: key) }
        return lock.withLock { _ in memory[key] }
    }

    private func write(_ value: Any?, _ key: String) {
        if let defaults { defaults.set(value, forKey: key); return }
        lock.withLock { _ in memory[key] = value }
    }
}
