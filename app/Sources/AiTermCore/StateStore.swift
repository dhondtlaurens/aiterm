import Foundation
import Synchronization

/// The workspace file, `state.json`, and its backup — the file as it was before the latest save, so
/// a damaged primary can be recovered. A save validates what it writes and refuses to replace a
/// primary it cannot read back; restoring keeps the damaged primary beside the restored one.
///
/// Sendable so the app can save off the main actor; it keeps one cache, behind a lock.
public final class StateStore: Sendable {
    public enum Failure: LocalizedError {
        case missingPrimary, invalidWorkspace

        public var errorDescription: String? {
            switch self {
            case .missingPrimary: return "The workspace file is missing, but a backup exists. Restore it before saving."
            case .invalidWorkspace: return "The workspace contains duplicate identifiers or references to missing projects."
            }
        }
    }

    public let url: URL
    /// The bytes this store last read or wrote at `url`, and the file they were found in. While the
    /// file is still that one, a save neither reads it back nor decodes it to check it: it already
    /// knows what it holds, and those bytes are the backup. A file changed since by anyone else — an
    /// editor, a copy, another AiTerm — no longer matches, and is read and checked as before.
    private let lastKnown = Mutex<KnownFile?>(nil)

    public init(url: URL) { self.url = url }
    public static var defaultURL: URL { AiTermPaths.supportDirectory().appendingPathComponent("state.json") }
    public var backupURL: URL { url.appendingPathExtension("backup") }
    public var hasValidBackup: Bool { (try? decode(Data(contentsOf: backupURL))) != nil }

    public func load() throws -> AppState {
        // Looked at before it is read: a file replaced in between then fails to match, and is read again.
        let identity = FileIdentity(of: url)
        if let data = try dataIfPresent(at: url) {
            let state = try decode(data)
            remember(data, identity)
            return state
        }
        guard try dataIfPresent(at: backupURL) == nil else { throw Failure.missingPrimary }
        return .empty
    }

    public func save(_ state: AppState) throws {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let previous = try previousData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous { try previous.write(to: backupURL, options: .atomic) }
        try data.write(to: url, options: .atomic)
        remember(data, FileIdentity(of: url))
    }

    public func restoreBackup() throws -> AppState {
        let data = try Data(contentsOf: backupURL)
        let state = try decode(data)
        if try dataIfPresent(at: url) != nil {
            let preserved = url.appendingPathExtension("recovered-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: preserved)
        }
        try data.write(to: url, options: .atomic)
        remember(data, FileIdentity(of: url))
        return state
    }

    /// What the primary holds now, which a save keeps as the backup: the bytes this store last saw
    /// there when it is still that file, or else the file read and checked — a primary that cannot
    /// be read back is never replaced, and a missing one beside a backup has to be restored first.
    private func previousData() throws -> Data? {
        if let known = lastKnown.withLock({ $0 }), let identity = FileIdentity(of: url), known.identity == identity {
            return known.data
        }
        let previous = try dataIfPresent(at: url)
        if let previous {
            _ = try decode(previous)
        } else if try dataIfPresent(at: backupURL) != nil {
            throw Failure.missingPrimary
        }
        return previous
    }

    private func remember(_ data: Data, _ identity: FileIdentity?) {
        lastKnown.withLock { $0 = identity.map { KnownFile(data: data, identity: $0) } }
    }

    private func dataIfPresent(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func decode(_ data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AppState.self, from: data)
        try validate(state)
        return state
    }

    private func validate(_ state: AppState) throws {
        let projects = Set(state.projects.map(\.id))
        // One id set across the whole sidebar: a divider must not collide with a project either.
        // Rows an older build cannot draw take a fresh id on every load, so they cannot collide.
        let drawn = state.items.filter(\.isDrawn)
        guard Set(drawn.map(\.id)).count == drawn.count,
              Set(state.tasks.map(\.id)).count == state.tasks.count,
              Set(state.terminals.map(\.id)).count == state.terminals.count,
              state.tasks.allSatisfy({ projects.contains($0.projectId) }),
              state.terminals.allSatisfy({ projects.contains($0.projectId) }) else {
            throw Failure.invalidWorkspace
        }
    }
}

/// The bytes a `StateStore` last read or wrote, and the file it found them in.
private struct KnownFile: Sendable {
    let data: Data
    let identity: FileIdentity
}

/// Which file is at a path, and which version of it: an atomic write is a new inode, an edit in
/// place a new modification time, and either can change the size.
private struct FileIdentity: Equatable, Sendable {
    let inode: UInt64, size: UInt64, modified: Date

    /// Nil when there is no file to describe.
    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.inode = inode; self.size = size; self.modified = modified
    }
}
