import Foundation

/// Antigravity's model list: `agy models`, one model at one effort a row, its id and its label
/// tab-separated (`gemini-4-neon-high	Gemini 4 Neon (High)`). The list is the signed-in account's and
/// is fetched online; the CLI's "Fetching available models..." goes to stderr.
///
/// The rows of one model are folded into one entry, its efforts the levels its rows name, so the
/// sheets offer a model and a reasoning level as they do for the other agents; the launch puts the
/// two back together (`Harness.agy`). A row whose label names no effort (`Orchestrator`) is a model
/// with none.
public enum AgyModelCatalog {
    /// The levels in the order they are offered; one the CLI adds later goes after them.
    static let effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"]

    public static func parse(_ output: String) throws -> [AgentModel] {
        var models: [AgentModel] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }
            let fields = row.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty, !fields[0].contains(" ") else {
                throw ModelListError.malformed(.agy, "Malformed Antigravity model row: \(row)")
            }
            let (id, label, effort) = split(id: fields[0], label: fields[1])
            if let index = models.firstIndex(where: { $0.id == id }), let effort {
                guard !models[index].efforts.contains(effort) else { continue }
                models[index].efforts.append(effort)
            } else {
                models.append(AgentModel(id: id, label: label, detail: nil, efforts: effort.map { [$0] } ?? [],
                                         defaultEffort: nil))
            }
        }
        return models.map { model in
            var model = model
            model.efforts.sort { rank($0) < rank($1) }
            model.defaultEffort = model.efforts.contains("medium") ? "medium" : model.efforts.first
            return model
        }
    }

    /// `gemini-4-neon-high` and `Gemini 4 Neon (High)` as the model `gemini-4-neon`, `Gemini 4 Neon`
    /// at `high`: the label's parenthesised effort, when the id ends in it.
    static func split(id: String, label: String) -> (id: String, label: String, effort: String?) {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return (id, label, nil) }
        let effort = label[label.index(after: open)..<label.index(before: label.endIndex)].lowercased()
        let name = label[..<open].trimmingCharacters(in: .whitespaces)
        guard !effort.isEmpty, !effort.contains(" "), !name.isEmpty, id.hasSuffix("-" + effort) else { return (id, label, nil) }
        return (String(id.dropLast(effort.count + 1)), name, effort)
    }

    /// The CLI's own id for `model` at `reasoning`: the two joined, unless the model already names it.
    static func cliModel(_ model: String, reasoning: String?) -> String {
        guard let reasoning, !reasoning.isEmpty, !model.hasSuffix("-" + reasoning) else { return model }
        return model + "-" + reasoning
    }

    private static func rank(_ effort: String) -> Int { effortOrder.firstIndex(of: effort) ?? effortOrder.count }

    /// Where the CLI keeps its settings and the account it signed in with, which is what its list
    /// is made from.
    static func sources(home: URL) -> [String] {
        [".gemini/antigravity-cli/settings.json", ".gemini/google_accounts.json", ".gemini/settings.json"]
            .map { home.appendingPathComponent($0).path }
    }

    /// `discover` with the CLI a probe has already found. The list is fetched, so it is given longer
    /// than PI's offline one.
    static func discover(executable: String, runner: HarnessCommandRunner) throws -> [AgentModel] {
        let result: ProcessOutput
        do {
            result = try runner.run(executable, ["models"], [:], 15)
        } catch {
            throw ModelListError.unavailable(.agy)
        }
        if result.timedOut { throw ModelListError.failed(.agy, result.status, "The model request timed out.") }
        guard result.status == 0 else {
            throw ModelListError.failed(.agy, result.status, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try parse(result.stdout)
    }
}
