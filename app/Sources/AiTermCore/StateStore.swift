import Foundation

public final class StateStore {
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
    public init(url: URL) { self.url = url }
    public static var defaultURL: URL { AiTermPaths.supportDirectory.appendingPathComponent("state.json") }
    public var backupURL: URL { url.appendingPathExtension("backup") }
    public var hasValidBackup: Bool { (try? decode(Data(contentsOf: backupURL))) != nil }

    public func load() throws -> AppState {
        if let data = try dataIfPresent(at: url) { return try decode(data) }
        guard try dataIfPresent(at: backupURL) == nil else { throw Failure.missingPrimary }
        return .empty
    }

    public func save(_ state: AppState) throws {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let previous = try dataIfPresent(at: url)
        if let previous {
            _ = try decode(previous)
        } else if try dataIfPresent(at: backupURL) != nil {
            throw Failure.missingPrimary
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous { try previous.write(to: backupURL, options: .atomic) }
        try data.write(to: url, options: .atomic)
    }

    public func restoreBackup() throws -> AppState {
        let data = try Data(contentsOf: backupURL)
        let state = try decode(data)
        if try dataIfPresent(at: url) != nil {
            let preserved = url.appendingPathExtension("recovered-" + UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: preserved)
        }
        try data.write(to: url, options: .atomic)
        return state
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
