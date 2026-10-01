import Foundation

/// AiTerm's half of Grok Build's hooks: one file in `~/.grok/hooks`, which Grok loads globally and
/// always trusts. Command hooks, because Grok refuses `http://` hook URLs ("SSRF protection"). The
/// file is AiTerm's when every handler in it posts to `/hook/grok` with `X-AiTerm-Hook: 1`: JSON has
/// no comments to carry a marker, and an unknown key would be Grok's to reject.
enum GrokHooksFile {
    static let path = ".grok/hooks/aiterm.json"
    static let events = ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "PostToolUseFailure",
                         "Stop", "StopFailure", "StopCancelled"]
    /// Grok's `Notification` matcher is a regular expression over the notification type:
    /// `permission_prompt` while a permission prompt waits, `idle_prompt` once a finished turn
    /// has sat idle. Changing it reads an existing install as out of date until Install.
    static let notificationMatcher = "permission_prompt|idle_prompt"

    static func url(home: URL) -> URL { home.appendingPathComponent(path) }

    /// Prints nothing and always exits 0: Grok reads a `Stop` hook's stdout as a stop decision and
    /// exit 2 as "keep working". `$ITERM_SESSION_ID` stays unbraced — Grok will not run a hook that
    /// names an unset `${VAR}`, and outside iTerm2 it is unset.
    static func postCommand(daemonPort: Int) -> String {
        "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H 'X-AiTerm-Hook: 1' "
            + "-H \"X-AiTerm-iTerm-Session: $ITERM_SESSION_ID\" -H 'Expect:' --data-binary @- "
            + "http://127.0.0.1:\(daemonPort)/hook/grok >/dev/null 2>&1; exit 0"
    }

    static func object(daemonPort: Int) -> [String: Any] {
        let handler: [String: Any] = ["type": "command", "command": postCommand(daemonPort: daemonPort), "timeout": 5]
        var hooks: [String: Any] = [:]
        for event in events {
            var entry: [String: Any] = ["hooks": [handler]]
            if event == "Notification" { entry["matcher"] = notificationMatcher }
            hooks[event] = [entry]
        }
        return ["hooks": hooks]
    }

    static func contents(daemonPort: Int) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object(daemonPort: daemonPort),
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// The state of a hooks file that is there. It is current when it says what Install writes,
    /// however it is formatted: the bytes are only the fast path, so a change in Foundation's
    /// pretty-printing never reads every install as out of date.
    static func state(of data: Data, daemonPort: Int) -> HarnessIntegrationState {
        if data == contents(daemonPort: daemonPort) { return .current }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("/hook/grok") && text.contains("X-AiTerm-Hook: 1") ? .invalidOwned : .foreign
        }
        if (object as NSDictionary) == (self.object(daemonPort: daemonPort) as NSDictionary) { return .current }
        return isOwned(object) ? .outdated : .foreign
    }

    static func isOwned(_ object: [String: Any]) -> Bool {
        guard let hooks = object["hooks"] as? [String: Any] else { return false }
        let commands = hooks.values
            .flatMap { ($0 as? [[String: Any]]) ?? [] }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .map { $0["command"] as? String ?? "" }
        return !commands.isEmpty && commands.allSatisfy { $0.contains("/hook/grok") && $0.contains("X-AiTerm-Hook: 1") }
    }
}
