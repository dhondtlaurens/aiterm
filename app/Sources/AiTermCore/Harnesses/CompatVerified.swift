import Foundation

/// The CLI versions this AiTerm was last checked with (`compat/verified.json`, bundled into
/// `Resources/compat/`): `scripts/compat-check.sh` writes a CLI's major and minor there only once its
/// live capture passed the contract suites. Each Settings › Agents card says, in a muted line, whether
/// the installed version is among them. Nothing waits on it: Messaging stays the gate for typing.
public struct CompatVerified: Equatable, Sendable {
    /// The major and minor verified, by agent (`2.1`).
    public var lines: [AgentKind: String]

    public init(lines: [AgentKind: String]) { self.lines = lines }

    /// The list in `data`; an entry it cannot read, or an agent AiTerm does not know, is left out.
    public static func decode(_ data: Data) -> CompatVerified {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return CompatVerified(lines: [:]) }
        var lines: [AgentKind: String] = [:]
        for (name, entry) in object {
            guard let agent = AgentKind(rawValue: name), let line = (entry as? [String: Any])?["verified"] as? String,
                  line.wholeMatch(of: /\d+\.\d+/) != nil else { continue }
            lines[agent] = line
        }
        return CompatVerified(lines: lines)
    }

    /// The list this build carries; none when it is missing, as in a build made without it.
    public static func bundled(resourceURL: URL? = Bundle.main.resourceURL) -> CompatVerified {
        guard let url = resourceURL?.appendingPathComponent("compat/verified.json"), let data = try? Data(contentsOf: url) else {
            return CompatVerified(lines: [:])
        }
        return decode(data)
    }

    /// The card's line for `agent` at the `installed` version: covered by the same major and minor,
    /// the rule Messaging goes by (`DeliveryCheck.versionLine`). Nil when the version is unknown.
    public func sentence(for agent: AgentKind, installed: String?) -> String? {
        guard let line = DeliveryCheck.versionLine(installed) else { return nil }
        return lines[agent] == line ? "\(line) verified with this AiTerm" : "\(line) not yet verified with this AiTerm"
    }
}
