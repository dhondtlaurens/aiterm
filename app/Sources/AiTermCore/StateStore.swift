import Foundation
import Synchronization

/// The workspace file, `state.json`, and its backup, the file as it was before the latest save, so
/// a damaged primary can be recovered. A save validates what it writes and refuses to replace a
/// primary it cannot read back; restoring keeps the damaged primary beside the restored one. The
/// backup is the validated bytes written beside the primary before it is replaced. Nothing is ever
/// changed on load.
///
/// The file carries its format as a top-level `version`, which a save stamps with `format`. A load
/// reads only that format: `WorkspaceUpdater` brings an older file forward first, and a newer one
/// is refused. A build never saves a workspace it did not read in its own format, so no save lowers
/// a stamp.
///
/// Sendable so the app can save off the main actor; it keeps one cache, behind a lock.
public final class StateStore: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case missingPrimary, invalidWorkspace
        /// Saved in an older format that the update scripts have not brought forward.
        case needsUpdate(ReleaseVersion)
        /// Saved by a newer AiTerm, in a format this build cannot read.
        case newerWorkspace(ReleaseVersion)

        public var errorDescription: String? {
            switch self {
            case .missingPrimary: return "The workspace file is missing, but a backup exists. Restore it before saving."
            case .invalidWorkspace: return "The workspace contains duplicate identifiers or references to missing projects."
            case .needsUpdate(let version): return "The workspace is in AiTerm \(version)'s format and has not been updated."
            case .newerWorkspace(let version): return "The workspace was saved by AiTerm \(version), newer than this one."
            }
        }
    }

    public let url: URL
    /// The bytes this store last read or wrote at `url`, and the file they were found in. While the
    /// file is still that one, a save neither reads it back nor decodes it to check it: it already
    /// knows what it holds, and those bytes are the backup. A file changed since by anyone else — an
    /// editor, a copy, another AiTerm — no longer matches, and is read and checked as before.
    private let lastKnown = Mutex<KnownFile?>(nil)

    /// The format this store reads and stamps.
    public let format: ReleaseVersion

    public init(url: URL, format: ReleaseVersion = UpdateScripts.current) { self.url = url; self.format = format }
    public static var defaultURL: URL { AiTermPaths.supportDirectory().appendingPathComponent("state.json") }
    public var backupURL: URL { url.appendingPathExtension("backup") }
    /// Whether the backup can replace the primary: it is in this build's format and reads, or in an
    /// older one the update scripts bring forward.
    public var hasValidBackup: Bool { (try? checkedBackup()) != nil }

    public func load() throws -> AppState {
        // Looked at before it is read: a file replaced in between then fails to match, and is read again.
        let identity = FileStamps.stamp(url.path)
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
        let data = try encoded(state)
        let previous = try previousData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous {
            WorkMeter.note(.stateWrite)
            try previous.write(to: backupURL, options: .atomic)
        }
        WorkMeter.note(.stateWrite)
        try data.write(to: url, options: .atomic)
        remember(data, FileStamps.stamp(url.path))
    }

    /// `state` as a save writes it, stamped with this store's format, unchecked.
    public func encoded(_ state: AppState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SavedWorkspace(version: format, state: state))
    }

    /// Replaces the primary with the backup and reads it.
    public func restoreBackup() throws -> AppState {
        try replaceWithBackup()
        return try load()
    }

    /// Replaces the primary with the backup, keeping the primary beside it as
    /// `state.json.recovered-<uuid>`. A backup in an older format is copied as it is, for the update
    /// scripts to bring forward before it is loaded.
    public func replaceWithBackup() throws {
        let data = try checkedBackup()
        if try dataIfPresent(at: url) != nil {
            let preserved = url.appendingPathExtension("recovered-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: preserved)
        }
        try data.write(to: url, options: .atomic)
    }

    /// The backup's bytes, when it is in this build's format and reads, or in an older one.
    private func checkedBackup() throws -> Data {
        let data = try Data(contentsOf: backupURL)
        let version = try WorkspaceUpdater.version(of: data)
        guard version <= format else { throw Failure.newerWorkspace(version) }
        if version == format { _ = try decode(data) }
        return data
    }

    /// What the primary holds now, which a save keeps as the backup: the bytes this store last saw
    /// there when it is still that file, or else the file read and checked — a primary that cannot
    /// be read back is never replaced, and a missing one beside a backup has to be restored first.
    private func previousData() throws -> Data? {
        if let known = lastKnown.withLock({ $0 }), let identity = FileStamps.stamp(url.path), known.identity == identity {
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

    private func remember(_ data: Data, _ identity: FileStamps.Stamp?) {
        lastKnown.withLock { $0 = identity.map { KnownFile(data: data, identity: $0) } }
    }

    private func dataIfPresent(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    private func decode(_ data: Data) throws -> AppState {
        let version = try WorkspaceUpdater.version(of: data)
        guard version <= format else { throw Failure.newerWorkspace(version) }
        guard version == format else { throw Failure.needsUpdate(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SavedWorkspace.self, from: data).state
        try validate(state)
        return state
    }

    private func validate(_ state: AppState) throws {
        let projects = Set(state.projects.map(\.id))
        // One id set across the whole sidebar: a divider must not collide with a project either.
        // A task is in the sidebar or in the archive, never both.
        let taskIds = state.tasks.map(\.id) + state.archive.map(\.id)
        guard Set(state.items.map(\.id)).count == state.items.count,
              Set(taskIds).count == taskIds.count,
              Set(state.terminals.map(\.id)).count == state.terminals.count,
              state.tasks.allSatisfy({ projects.contains($0.projectId) }),
              state.archive.allSatisfy({ projects.contains($0.task.projectId) }),
              state.terminals.allSatisfy({ projects.contains($0.projectId) }) else {
            throw Failure.invalidWorkspace
        }
    }
}

/// `state.json` as it is saved: the workspace's fields with the format's `version` beside them.
private struct SavedWorkspace: Codable {
    private enum Key: String, CodingKey { case version }
    let version: ReleaseVersion
    let state: AppState

    init(version: ReleaseVersion, state: AppState) { self.version = version; self.state = state }

    init(from decoder: Decoder) throws {
        let text = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .version)
        guard let version = ReleaseVersion(text) else { throw WorkspaceUpdater.Failure.unreadableVersion(text) }
        self.version = version
        state = try AppState(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try state.encode(to: encoder)
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(version.description, forKey: .version)
    }
}

/// The bytes a `StateStore` last read or wrote, and the file it found them in.
private struct KnownFile: Sendable {
    let data: Data
    let identity: FileStamps.Stamp
}
