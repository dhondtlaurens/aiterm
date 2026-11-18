import Foundation
import Synchronization

/// The workspace file, `state.json`, and its backup, the file as it was before the latest save, so
/// a damaged primary can be recovered. A save validates what it writes and refuses to replace a
/// primary it cannot read back; restoring keeps the damaged primary beside the restored one. The
/// backup is the validated bytes written beside the primary before it is replaced.
///
/// A file whose Operator records are in the previous release's shape loads without them: each
/// `operatorSession` or `signalTask` that does not decode is dropped (a dropped record's Take Over
/// mark stays on its task), the file is kept beside the primary as `state.json.before-reset-<date>`,
/// and the cleared workspace is saved in its place. Nothing else is ever changed on load.
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
    private let cleared = Mutex(false)

    public init(url: URL) { self.url = url }
    public static var defaultURL: URL { AiTermPaths.supportDirectory().appendingPathComponent("state.json") }
    public var backupURL: URL { url.appendingPathExtension("backup") }
    public var hasValidBackup: Bool { (try? decodeClearingOperatorRecords(Data(contentsOf: backupURL))) != nil }
    /// Whether the latest load or restore dropped Operator records saved by the previous release.
    public var clearedOperatorRecords: Bool { cleared.withLock { $0 } }
    /// What the app says once, after a launch that dropped them.
    public static let clearedOperatorRecordsNote =
        "AiTerm cleared the Operator's saved records from the previous version. Your projects and tasks are unchanged."

    public func load() throws -> AppState {
        // Looked at before it is read: a file replaced in between then fails to match, and is read again.
        let identity = FileStamps.stamp(url.path)
        if let data = try dataIfPresent(at: url) {
            let (state, didClear) = try decodeClearingOperatorRecords(data)
            remember(data, identity)
            if didClear {
                try keepBeforeReset(data)
                // The bytes just read are known, so this save keeps them as the backup without
                // checking them again, and the primary becomes the cleared workspace.
                try save(state)
            }
            cleared.withLock { $0 = didClear }
            return state
        }
        guard try dataIfPresent(at: backupURL) == nil else { throw Failure.missingPrimary }
        cleared.withLock { $0 = false }
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
        if let previous {
            WorkMeter.note(.stateWrite)
            try previous.write(to: backupURL, options: .atomic)
        }
        WorkMeter.note(.stateWrite)
        try data.write(to: url, options: .atomic)
        remember(data, FileStamps.stamp(url.path))
    }

    public func restoreBackup() throws -> AppState {
        let data = try Data(contentsOf: backupURL)
        let (state, didClear) = try decodeClearingOperatorRecords(data)
        if try dataIfPresent(at: url) != nil {
            let preserved = url.appendingPathExtension("recovered-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: preserved)
        }
        try data.write(to: url, options: .atomic)
        remember(data, FileStamps.stamp(url.path))
        cleared.withLock { $0 = didClear }
        return state
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

    /// `data` decoded, or, when it does not decode, decoded again without the Operator records it
    /// holds in an older shape. A file that fails for any other reason throws the first error.
    private func decodeClearingOperatorRecords(_ data: Data) throws -> (AppState, cleared: Bool) {
        do { return (try decode(data), false) }
        catch {
            guard let clearedData = OperatorRecordsReset.clear(data), let state = try? decode(clearedData) else { throw error }
            return (state, true)
        }
    }

    /// Copies the primary's bytes beside it as `state.json.before-reset-<yyyyMMdd-HHmmss>`, never
    /// over a file already there.
    private func keepBeforeReset(_ data: Data) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let copy = url.appendingPathExtension("before-reset-" + formatter.string(from: Date()))
        try data.write(to: copy, options: .withoutOverwriting)
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

/// Drops the Operator records a workspace holds in a shape this build cannot read, as
/// `scripts/reset-operator-state.sh` does: the top-level `operatorSession`, and the `signalTask` of
/// each task and archived task. A dropped `signalTask` holding `"takenOver": true` leaves the task
/// marked taken over. Records that decode stay, and so does everything else.
enum OperatorRecordsReset {
    /// The workspace without those records, or nil when it holds none to drop.
    static func clear(_ data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var changed = false
        if let session = root["operatorSession"], !(session is NSNull), !decodes(OperatorSession.self, session) {
            root["operatorSession"] = nil
            changed = true
        }
        if var tasks = root["tasks"] as? [Any] {
            for index in tasks.indices {
                guard var task = tasks[index] as? [String: Any], clearRecord(&task) else { continue }
                tasks[index] = task
                changed = true
            }
            root["tasks"] = tasks
        }
        if var archive = root["archive"] as? [Any] {
            for index in archive.indices {
                guard var entry = archive[index] as? [String: Any], var task = entry["task"] as? [String: Any],
                      clearRecord(&task) else { continue }
                entry["task"] = task
                archive[index] = entry
                changed = true
            }
            root["archive"] = archive
        }
        guard changed else { return nil }
        return try? JSONSerialization.data(withJSONObject: root)
    }

    /// Drops `task`'s `signalTask` when it does not decode, carrying its Take Over mark. True if dropped.
    private static func clearRecord(_ task: inout [String: Any]) -> Bool {
        guard let record = task["signalTask"], !(record is NSNull), !decodes(SignalTask.self, record) else { return false }
        if let number = (record as? [String: Any])?["takenOver"] as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID(), number.boolValue {
            task["takenOver"] = true
        }
        task["signalTask"] = nil
        return true
    }

    private static func decodes<T: Decodable>(_ type: T.Type, _ value: Any) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(type, from: data)) != nil
    }
}
