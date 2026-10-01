import Foundation

/// PI's driver: an extension AiTerm owns outright in `~/.pi/agent/extensions/`, beside any other
/// tool's. It is AiTerm's when its first line carries the schema marker.
struct PiDriver: HarnessDriver {
    static let path = ".pi/agent/extensions/aiterm-status.ts"
    static let schemaVersion = 3
    private static let markerPrefix = "// AiTerm PI extension schema: "

    let home: URL
    /// The bundled extension, which Install writes and a current file matches exactly.
    let source: String

    var file: UserConfigFile { UserConfigFile(home: home, Self.path) }

    /// A file that is there: foreign without the marker, outdated at another schema, and invalid
    /// when its marker is broken or, given the bundled `expected` source, its body differs.
    static func state(of text: String, expected: String?) -> HarnessIntegrationState {
        guard let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init),
              firstLine.hasPrefix(markerPrefix) else { return .foreign }
        guard let version = Int(firstLine.dropFirst(markerPrefix.count)) else { return .invalidOwned }
        guard version == schemaVersion else { return .outdated }
        if let expected, text != expected { return .invalidOwned }
        return .current
    }

    func probe() -> DriverProbe {
        let file = self.file
        switch file.readText() {
        case .missing: return DriverProbe(.missing)
        case .refused(let reason): return .refused(file, reason)
        case .present(let text):
            let state = Self.state(of: text, expected: source)
            return state == .foreign ? .foreign(file) : DriverProbe(state)
        }
    }

    func install() throws {
        guard source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
                == Self.markerPrefix + String(Self.schemaVersion) else {
            throw HarnessDriverError.invalidSource
        }
        let file = self.file
        switch file.readText() {
        case .refused(let reason): throw file.refusal(reason)
        case .present(let text) where Self.state(of: text, expected: nil) == .foreign:
            throw HarnessDriverError.foreign(path: file.displayPath)
        case .missing, .present: break
        }
        try file.write(Data(source.utf8))
    }

    func test(with client: HarnessTestClient) async -> HarnessTestResult {
        await client.testPi(extensionPath: file.url.path)
    }
}
