import Foundation

/// Antigravity's native read_file also implements file searches. Version 1.5.18 exposes
/// manage_task even with an explicit tool list. A hook attached to the profile itself denies
/// every operation except a read in this revision. Workspace and user hooks stay disabled.
public enum ManualReviewAgy {
    public static let verifiedVersion = "1.5.18"

    /// The CLI gets its existing sign-in and a fresh home for this run. Its configuration,
    /// plugins, hooks, conversation files and temporary files all resolve inside the request.
    public static func environment(in home: URL, inheriting original: [String: String]) throws -> [String: String] {
        guard let person = original["HOME"], person.hasPrefix("/") else { throw ManualReviewError("Missing Antigravity home.") }
        let fm = FileManager.default
        let file = ".gemini/antigravity-cli/antigravity-oauth-token"
        let credentials: Data
        switch RegularFile.read(URL(fileURLWithPath: person).appendingPathComponent(file).path, limit: 1 << 20) {
        case .bytes(let data): credentials = data
        case .absent: credentials = try keychainSignIn(in: original)
        case nil: throw ManualReviewError("Could not read the Antigravity sign-in.")
        }
        let destination = home.appendingPathComponent(file), temp = home.appendingPathComponent("tmp")
        for directory in [destination.deletingLastPathComponent(), temp] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try PrivateFile.write(credentials, to: destination)
        let needed = ["PATH", "LANG", "TZ", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
                      "SSL_CERT_FILE", "SSL_CERT_DIR"]
        var environment = original.filter { needed.contains($0.key.uppercased()) || $0.key.hasPrefix("LC_") }
        environment["HOME"] = home.path
        environment["TMPDIR"] = temp.path
        environment["AGY_CLI_FORCE_FILE_TOKEN_STORAGE"] = "1"
        return environment
    }

    /// The verified CLI uses go-keyring's Darwin encoding for this one service and account.
    /// Keep the credential off argv and terminal output. Only its temporary file is shared.
    private static func keychainSignIn(in environment: [String: String]) throws -> Data {
        let output = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/security"),
            ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
            environment: environment, timeout: 10, limit: 2 << 20)
        let encoded = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        guard output.status == 0, !output.timedOut, !output.stdoutTruncated, encoded.hasPrefix(prefix),
              let data = Data(base64Encoded: String(encoded.dropFirst(prefix.count))), !data.isEmpty else {
            throw ManualReviewError("Could not access the Antigravity sign-in. Check your login with agy and retry.")
        }
        return data
    }

    public static func install(in workspace: URL, executable: URL) throws -> String {
        let name = "aiterm-review-" + UUID().uuidString.lowercased()
        let directory = workspace.appendingPathComponent(".agents/agents/" + name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let command = AgentCommand.shellQuote(executable.path) + " --manual-review-read " + AgentCommand.shellQuote(workspace.path)
        let hooks: JSONValue = ["aiterm-review": ["PreToolUse": [["matcher": "*", "hooks": [
            ["type": "command", "command": .string(command), "timeout": 10]
        ]]]]]
        try PrivateFile.write(try JSONEncoder().encode(hooks), to: directory.appendingPathComponent("read-policy.json"))
        let definition = """
        ---
        name: \(name)
        description: Review the supplied patch and pinned source files.
        mainAgent: true
        subagent: false
        model: inherit
        inheritMcp: false
        inheritCustomizations: false
        commandExecutionPolicy: "off"
        tools: [read_file]
        hooks: [read-policy.json]
        ---
        # Instructions
        Read changes.patch, paths.txt and relevant files under source with read_file.
        Return findings with caller evidence. Only read files. Never interact with background tasks.
        """
        try PrivateFile.write(Data(definition.utf8), to: directory.appendingPathComponent("agent.md"))
        return name
    }

    /// Absolute paths are resolved as the filesystem resolves them, including symlinks.
    public static func permits(_ input: Data, workspace: URL) -> Bool {
        guard let record = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let call = record["toolCall"] as? [String: Any], call["name"] as? String == "read_file",
              let args = call["args"] as? [String: Any], let path = args["Path"] as? String, !path.isEmpty else { return false }
        let root = CanonicalPath.of(workspace.path)
        let resolved = CanonicalPath.of(path.hasPrefix("/") ? path : workspace.appendingPathComponent(path).path)
        return resolved.hasPrefix(root + "/source/") || resolved == root + "/source"
            || ["changes.patch", "paths.txt", "context.txt"].contains { resolved == root + "/" + $0 }
    }
}
