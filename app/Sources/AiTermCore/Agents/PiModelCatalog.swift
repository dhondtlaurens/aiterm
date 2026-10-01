import Foundation

public enum PiModelCatalogError: Error, Equatable {
    case unavailable
    case failed(Int32, String)
    case malformed(String)
}

public enum PiModelCatalog {
    public static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    public static func parse(_ output: String) throws -> [AgentModel] {
        let lines = output.split(whereSeparator: \Character.isNewline)
        guard !lines.isEmpty else { return [] }
        let header = lines[0].split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard header == ["provider", "model", "context", "max-out", "thinking", "images"] else {
            throw PiModelCatalogError.malformed("Unexpected PI model-list header")
        }
        return try lines.dropFirst().map { line in
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard fields.count == 6,
                  ["yes", "no"].contains(fields[4]),
                  ["yes", "no"].contains(fields[5]) else {
                throw PiModelCatalogError.malformed("Malformed PI model row: \(line)")
            }
            let supportsThinking = fields[4] == "yes"
            let imageText = fields[5] == "yes" ? "images" : "no images"
            return AgentModel(id: "\(fields[0])/\(fields[1])",
                              label: "\(fields[0]) / \(fields[1])",
                              detail: "\(fields[2]) context · \(fields[3]) max · \(imageText)",
                              efforts: supportsThinking ? thinkingLevels : [],
                              defaultEffort: supportsThinking ? "medium" : nil)
        }
    }

    public static func discover(runner: HarnessCommandRunner = .live) throws -> [AgentModel] {
        guard let executable = runner.locate("pi") else { throw PiModelCatalogError.unavailable }
        return try discover(executable: executable, runner: runner)
    }

    /// `discover` with the CLI a probe has already found.
    public static func discover(executable: String, runner: HarnessCommandRunner = .live) throws -> [AgentModel] {
        let result: ProcessOutput
        do {
            result = try runner.run(executable, ["--offline", "--list-models"], ["PI_OFFLINE": "1"], 5)
        } catch {
            throw PiModelCatalogError.unavailable
        }
        guard !result.timedOut, result.status == 0 else {
            throw PiModelCatalogError.failed(result.status, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try parse(result.stdout)
    }
}
