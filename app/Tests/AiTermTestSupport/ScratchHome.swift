import Foundation
import Synchronization
import AiTermCore

/// A home with nothing in it, for whatever a test builds that reads one. The developer's own
/// `~/.claude`, `~/.claude.json` and `~/.codex` say nothing about a test: reading them made a
/// sheet's models and completions whatever this machine has installed. Made once per process, and
/// removed when it exits.
enum ScratchHome {
    static let bare: URL = {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-test-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        created.withLock { $0 = home }
        atexit { ScratchHome.remove() }
        return home
    }()

    /// What an agent with no configuration offers, for a creation model a test builds: Claude's
    /// aliases, and Codex's defaults. PI's is a launch of its CLI, so a test gets none; Grok's reads
    /// the bare home's missing `models_cache.json` and gets none either.
    static let catalogue: @Sendable (AgentKind) -> [AgentModel] = { agent in
        agent == .pi ? [] : ModelCatalog.models(for: agent, home: ScratchHome.bare)
    }

    private static let created = Mutex<URL?>(nil)

    private static func remove() {
        guard let home = created.withLock({ $0 }) else { return }
        try? FileManager.default.removeItem(at: home)
    }
}
