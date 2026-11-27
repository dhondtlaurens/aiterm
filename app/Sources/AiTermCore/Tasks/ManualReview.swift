import Darwin
import Foundation

public struct ManualReviewError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

/// The small, private handoff between the sheet and the executable in its terminal tab.
public struct ManualReview: Codable, Sendable {
    public let repository: String
    public let branch: String
    public let head: String
    public let target: String?
    public let agent: AgentKind
    public let model: String
    public let effort: String?
    public let context: String?

    public struct Pending: Sendable {
        public let folder: URL
        public var request: URL { folder.appendingPathComponent("request.json") }
        public func command(executable: URL) -> String {
            AgentCommand.shellQuote(executable.path) + " --manual-review " + AgentCommand.shellQuote(request.path)
        }

        /// Only an undelivered request belongs to the launcher. Rename is the single winner
        /// between this cleanup and the tab claiming it.
        public func discard() {
            if rename(request.path, folder.appendingPathComponent("undelivered").path) == 0 {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-manual-reviews") }

    func stage() throws -> Pending {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.sweep()
        let pending = Pending(folder: Self.root.appendingPathComponent(UUID().uuidString))
        try fm.createDirectory(at: pending.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try PrivateFile.write(JSONEncoder().encode(self), to: pending.request) }
        catch { try? fm.removeItem(at: pending.folder); throw error }
        return pending
    }

    /// A helper holds the lock until every child has exited. A stale run left by a killed app
    /// or an ambiguous delivery is reclaimed by a later review.
    private static func sweep() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date.timeIntervalSinceNow < -86400 else { continue }
            let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: folder) }
        }
    }

    public static func withClaim<T: Sendable>(at request: URL, run: @Sendable (ManualReview, URL) async throws -> T) async throws -> T {
        let folder = request.deletingLastPathComponent()
        guard request.lastPathComponent == "request.json", UUID(uuidString: folder.lastPathComponent) != nil,
              CanonicalPath.of(folder.deletingLastPathComponent().path) == CanonicalPath.of(root.path) else {
            throw ManualReviewError("Invalid manual review request.")
        }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ManualReviewError("Review request expired or was already used.") }
        defer { close(fd) }
        let claimed = folder.appendingPathComponent("claimed.json")
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, rename(request.path, claimed.path) == 0 else {
            throw ManualReviewError("Review request expired or was already used.")
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let review = try JSONDecoder().decode(Self.self, from: Data(contentsOf: claimed))
        return try await run(review, folder)
    }
}
