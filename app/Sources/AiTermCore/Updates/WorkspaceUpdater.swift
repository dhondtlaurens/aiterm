import Foundation

/// Brings `state.json` into this build's format before it is read. The file's top-level `version`
/// says which format it is in (none is `UpdateScripts.baseline`); the scripts after it, up to
/// `current`, run in order. Before the first one, the file is copied beside itself as
/// `state.json.before-update-<version>`, never over a copy already there; after each, the file is
/// written stamped with that script's version, so a launch that stops halfway resumes where it
/// stopped. A file in a newer format is refused: there is no way back.
public struct WorkspaceUpdater: Sendable {
    public enum Plan: Equatable, Sendable {
        /// No file yet, or one in this build's format.
        case upToDate
        /// A file in an older format, and the versions of the scripts that bring it forward.
        case update(from: ReleaseVersion, steps: [ReleaseVersion])
        /// A file a newer AiTerm saved.
        case newer(ReleaseVersion)
    }

    public enum Failure: LocalizedError, Equatable {
        case notAWorkspace
        case unreadableVersion(String)
        case newerWorkspace(ReleaseVersion)
        case scriptFailed(ReleaseVersion, String)

        public var errorDescription: String? {
            switch self {
            case .notAWorkspace: "The workspace file is not a JSON object."
            case .unreadableVersion(let text): "The workspace's version, \(text), is not a version AiTerm knows."
            case .newerWorkspace(let version): "The workspace was saved by AiTerm \(version), newer than this one."
            case .scriptFailed(let version, let reason): "Updating the workspace for AiTerm \(version) failed: \(reason)"
            }
        }
    }

    /// The top-level key that holds the format.
    public static let versionKey = "version"

    public let url: URL
    public let scripts: [UpdateScript]
    public let current: ReleaseVersion

    public init(url: URL, scripts: [UpdateScript] = UpdateScripts.all, current: ReleaseVersion = UpdateScripts.current) {
        self.url = url; self.scripts = scripts; self.current = current
    }

    /// Where the file as it was before an update from `version` is kept.
    public func beforeUpdateURL(from version: ReleaseVersion) -> URL {
        url.appendingPathExtension("before-update-\(version)")
    }

    /// The format a saved workspace is in: its `version`, or the baseline when it has none.
    public static func version(of state: JSONValue) throws -> ReleaseVersion {
        guard case .object = state else { throw Failure.notAWorkspace }
        guard let stored = state[versionKey] else { return UpdateScripts.baseline }
        guard let text = stored.stringValue, let version = ReleaseVersion(text) else {
            throw Failure.unreadableVersion((try? stored.canonicalJSON()) ?? "?")
        }
        return version
    }

    /// The format of the workspace `data` holds.
    public static func version(of data: Data) throws -> ReleaseVersion {
        try version(of: JSONDecoder().decode(JSONValue.self, from: data))
    }

    public func plan() throws -> Plan {
        guard let data = try Self.dataIfPresent(at: url) else { return .upToDate }
        let stored = try Self.version(of: data)
        if stored > current { return .newer(stored) }
        if stored == current { return .upToDate }
        return .update(from: stored, steps: pending(after: stored).map(\.version))
    }

    /// Runs the scripts the file still needs; nothing when it needs none.
    public func run(defaults: UserDefaults, home: URL) throws {
        guard let data = try Self.dataIfPresent(at: url) else { return }
        let state = try JSONDecoder().decode(JSONValue.self, from: data)
        let stored = try Self.version(of: state)
        guard stored <= current else { throw Failure.newerWorkspace(stored) }
        guard stored < current else { return }
        let copy = beforeUpdateURL(from: stored)
        if !FileManager.default.fileExists(atPath: copy.path) {
            try data.write(to: copy, options: .withoutOverwriting)
        }
        var context = UpdateContext(state: state, defaults: defaults,
                                    supportDirectory: url.deletingLastPathComponent(), home: home)
        for script in pending(after: stored) {
            do { try script.run(&context) }
            catch { throw Failure.scriptFailed(script.version, error.localizedDescription) }
            try write(&context.state, stamped: script.version)
        }
        if try Self.version(of: context.state) < current { try write(&context.state, stamped: current) }
    }

    private func pending(after stored: ReleaseVersion) -> [UpdateScript] {
        scripts.filter { $0.version > stored && $0.version <= current }.sorted { $0.version < $1.version }
    }

    private func write(_ state: inout JSONValue, stamped version: ReleaseVersion) throws {
        state[Self.versionKey] = .string(version.description)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private static func dataIfPresent(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }
}
