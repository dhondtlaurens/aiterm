import Foundation

/// Why an agent's model list, a launch of its CLI (`ModelListing.launch`), could not be read.
public enum ModelListError: Error, Equatable, Sendable, LocalizedError {
    case unavailable(AgentKind)
    case failed(AgentKind, Int32, String)
    case malformed(AgentKind, String)

    /// The agent whose list it is.
    public var agent: AgentKind {
        switch self {
        case .unavailable(let agent), .failed(let agent, _, _), .malformed(let agent, _): agent
        }
    }

    /// The failure in a sentence, as Settings' Models check says it.
    public var summary: String {
        if case .unavailable = self { return "\(agent.displayName) couldn’t be launched." }
        return "The \(agent.displayName) model catalogue is unavailable."
    }

    /// What the New Task sheet says in place of the agent's models when it has none to offer: the
    /// summary, with the CLI's own last line of complaint when it gave one.
    public var errorDescription: String? {
        guard case .failed(_, _, let stderr) = self,
              let reason = stderr.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty })
        else { return summary }
        return String(summary.dropLast()) + ": " + reason
    }
}

public enum PiModelCatalog {
    /// PI's table, one row a model. With no provider signed in PI prints a sentence instead — "No
    /// models available. Use /login …" — and exits 0: that is an empty list, not a broken one.
    public static func parse(_ output: String) throws -> [AgentModel] {
        let lines = output.split(whereSeparator: \Character.isNewline)
        guard let first = lines.first, !first.hasPrefix("No models available") else { return [] }
        let header = lines[0].split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard header == ["provider", "model", "context", "max-out", "thinking", "images"] else {
            throw ModelListError.malformed(.pi, "Unexpected PI model-list header")
        }
        return try lines.dropFirst().map { line in
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard fields.count == 6,
                  ["yes", "no"].contains(fields[4]),
                  ["yes", "no"].contains(fields[5]) else {
                throw ModelListError.malformed(.pi, "Malformed PI model row: \(line)")
            }
            let supportsThinking = fields[4] == "yes"
            let imageText = fields[5] == "yes" ? "images" : "no images"
            return AgentModel(id: "\(fields[0])/\(fields[1])",
                              label: "\(fields[0]) / \(fields[1])",
                              detail: "\(fields[2]) context · \(fields[3]) max · \(imageText)",
                              efforts: supportsThinking ? Harness.pi.fallbackEfforts : [],
                              defaultEffort: supportsThinking ? Harness.pi.defaultEffort : nil)
        }
    }

    /// Where PI keeps its sign-ins and custom models, which is what its list is made from.
    static func sources(home: URL) -> [String] {
        [".pi/agent", ".pi/agent/auth.json", ".pi/agent/models.json", ".pi/agent/settings.json"]
            .map { home.appendingPathComponent($0).path }
    }

    /// `discover` with the CLI a probe has already found.
    static func discover(executable: String, runner: HarnessCommandRunner) throws -> [AgentModel] {
        let result: ProcessOutput
        do {
            result = try runner.run(executable, ["--offline", "--list-models"], ["PI_OFFLINE": "1"], 5)
        } catch {
            throw ModelListError.unavailable(.pi)
        }
        guard !result.timedOut, result.status == 0 else {
            throw ModelListError.failed(.pi, result.status, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try parse(result.stdout)
    }
}
