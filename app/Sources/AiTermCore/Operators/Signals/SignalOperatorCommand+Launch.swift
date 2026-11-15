import Foundation
import CryptoKit

extension SignalOperatorCommand {
    public struct Authority: Codable, Equatable, Sendable {
        public var id: UUID
        public var generation: Int
        public var tokenHash: String
    }
    /// Exactly one folder, outside the person's repositories and all worker checkouts.
    public static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        AiTermPaths.supportDirectory(home: home).appendingPathComponent("operators/operator", isDirectory: true)
    }
    public static func authority(in folder: URL) throws -> Authority? {
        let path = folder.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(Authority.self, from: Data(contentsOf: path))
    }
    public static func token(for session: OperatorSession, in folder: URL) throws -> String? {
        guard let authority = try authority(in: folder), authority.id == session.id, authority.generation == session.generation,
              let token = OperatorCommand.existingToken(in: folder), authority.tokenHash == hash(token) else { return nil }
        return token
    }
    /// The caller closes and revokes the previous generation before preparing a fresh one.
    public static func prepare(session: OperatorSession, profile: OperatorProfile, projects: [Project], digest: OperatorDigest,
                               hookPort: Int = AiTermPaths.hookPort, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               claudeConfig: ClaudeConfig = ClaudeConfig(), resuming conversation: String? = nil) throws -> OperatorCommand.Prepared {
        let folder = folder(home: home), manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try OperatorCommand.trustRunFolder(folder, home: home, claudeConfig: claudeConfig)
        let token = try token(for: session, in: folder) ?? OperatorCommand.makeToken()
        try OperatorCommand.writePrivate(Data(configuredBrief(instructions: profile.instructions).utf8), to: folder.appendingPathComponent(OperatorCommand.briefFile))
        try OperatorCommand.writePrivate(Data(try OperatorCommand.mcpConfig(hookPort: hookPort, token: token).utf8), to: folder.appendingPathComponent(OperatorCommand.mcpFile))
        let gate = try JSONDecoder().decode(JSONValue.self, from: Data(OperatorCommand.gateSettings(hookPort: hookPort, token: token).utf8))
        var settings = gate.objectValue ?? [:]; settings["idleCompaction"] = false
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try OperatorCommand.writePrivate(encoder.encode(JSONValue.object(settings)), to: folder.appendingPathComponent(OperatorCommand.gateFile))
        // The hash binds the separately atomic files. A daemon reading halfway through a handover
        // never grants the old token the new generation's authority.
        try OperatorCommand.writePrivate(Data(token.utf8), to: folder.appendingPathComponent(OperatorCommand.tokenFile))
        try OperatorCommand.writePrivate(encoder.encode(Authority(id: session.id, generation: session.generation, tokenHash: hash(token))),
                                         to: folder.appendingPathComponent("session.json"))
        if conversation == nil {
            try OperatorCommand.writePrivate(Data(try firstMessage(digest).utf8), to: folder.appendingPathComponent(OperatorCommand.firstMessageFile))
        }
        let words = OperatorCommand.launchWords(model: profile.model, effort: profile.reasoning, runFolder: folder,
                                                projectPaths: projects.map(\.path), resuming: conversation)
        return OperatorCommand.Prepared(folder: folder,
            command: try OperatorCommand.typed(OperatorCommand.command(words: words, firstMessage: conversation == nil), in: folder), token: token)
    }
    private static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
}
