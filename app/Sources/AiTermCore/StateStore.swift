import Foundation
import Synchronization
import Darwin

/// The workspace file, `state.json`, and its backup — the file as it was before the latest save, so
/// a damaged primary can be recovered. A save validates what it writes and refuses to replace a
/// primary it cannot read back; restoring keeps the damaged primary beside the restored one. The
/// backup is a clone of the primary before it is replaced, not a second write of its bytes: on APFS
/// the clone shares the primary's blocks, so a save writes one file.
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
        WorkMeter.note(.stateSave)
        try validate(state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let previous = try previousData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous { try keepBackup(previous) }
        WorkMeter.note(.stateWrite)
        try data.write(to: url, options: .atomic)
        remember(data, FileStamps.stamp(url.path))
    }

    public func restoreBackup() throws -> AppState {
        let data = try Data(contentsOf: backupURL)
        let state = try decode(data)
        if try dataIfPresent(at: url) != nil {
            let preserved = url.appendingPathExtension("recovered-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: preserved)
        }
        try data.write(to: url, options: .atomic)
        remember(data, FileStamps.stamp(url.path))
        return state
    }

    /// `previous` kept as the backup: the bytes this store validated, never merely what the primary
    /// holds now. The primary is cloned beside the backup, and the clone kept — renamed over the
    /// backup, so a backup is never half there — only when it holds exactly `previous`: an edit the
    /// store's stamp cannot see (same length, inode and modification time) is not a validated
    /// snapshot. Otherwise, or when the primary cannot be opened, `previous` is written, as before
    /// the clone. Comparing reads the clone back; writing nothing of its bytes is what the clone
    /// saves. A volume that cannot clone has `copyfile` copy, which is a write and is counted as one.
    private func keepBackup(_ previous: Data) throws {
        let staging = backupURL.appendingPathExtension("staging-" + UUID().uuidString)
        let cloned = Self.clone(url, to: staging)
        // A clone that copied wrote the bytes, whether or not they are kept.
        if cloned == false { WorkMeter.note(.stateWrite) }
        guard cloned != nil, (try? Data(contentsOf: staging)) == previous else {
            unlink(staging.path)
            WorkMeter.note(.stateWrite)
            return try previous.write(to: backupURL, options: .atomic)
        }
        guard rename(staging.path, backupURL.path) == 0 else {
            let error = CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: backupURL.path,
                                                                NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
            unlink(staging.path)
            throw error
        }
    }

    /// `source` cloned to `destination` by `copyfile`: true when it cloned, false when it copied, `nil`
    /// when it failed.
    private static func clone(_ source: URL, to destination: URL) -> Bool? {
        guard let state = copyfile_state_alloc() else { return nil }
        defer { copyfile_state_free(state) }
        guard copyfile(source.path, destination.path, state, copyfile_flags_t(COPYFILE_CLONE)) == 0 else { return nil }
        var cloned = false
        guard copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &cloned) == 0 else { return false }
        return cloned
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
        // A task is in the sidebar or in the archive, never both.
        let taskIds = state.tasks.map(\.id) + state.archive.map(\.id)
        guard Set(drawn.map(\.id)).count == drawn.count,
              Set(taskIds).count == taskIds.count,
              Set(state.terminals.map(\.id)).count == state.terminals.count,
              state.tasks.allSatisfy({ projects.contains($0.projectId) }),
              state.archive.allSatisfy({ projects.contains($0.task.projectId) }),
              state.terminals.allSatisfy({ projects.contains($0.projectId) }) else {
            throw Failure.invalidWorkspace
        }
    }
}

/// The bytes a `StateStore` last read or wrote, and the file it found them in.
private struct KnownFile: Sendable {
    let data: Data
    let identity: FileStamps.Stamp
}
