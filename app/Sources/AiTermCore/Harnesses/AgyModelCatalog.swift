import Foundation

/// Antigravity's model list: `agy models`, one model a row, its id and its label tab-separated
/// (`gemini-4-neon-high	Gemini 4 Neon (High)`). The list is the signed-in account's and is
/// fetched online; the CLI's "Fetching available models..." goes to stderr.
///
/// Each id names its effort already, so no model offers reasoning levels and none is sent.
public enum AgyModelCatalog {
    public static func parse(_ output: String) throws -> [AgentModel] {
        try output.split(whereSeparator: \.isNewline).compactMap { line in
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { return nil }
            let fields = row.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty, !fields[0].contains(" ") else {
                throw ModelListError.malformed(.agy, "Malformed Antigravity model row: \(row)")
            }
            return AgentModel(id: fields[0], label: fields[1], detail: nil, efforts: [], defaultEffort: nil)
        }
    }

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
        guard !result.timedOut, result.status == 0 else {
            throw ModelListError.failed(.agy, result.status, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try parse(result.stdout)
    }
}
